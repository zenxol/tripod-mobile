import Foundation

/**
 Pure bookkeeping for the rolling buffer's finished segments: ordering, continuity checks,
 retention and protection. No AVFoundation, no file access, no threads: the recorder calls it
 under its lock and performs the file deletions it returns. That keeps it unit-testable on any
 machine with a Swift compiler (see modules/tripod-camera/tests).
 */

/// A finished, renamed segment file. Times are capture-clock seconds taken from the frames'
/// presentation timestamps, never from wall-clock estimates.
struct BufferSegment: Equatable {
  let index: Int
  let fileName: String
  /// Presentation timestamp of the first frame.
  let startTime: Double
  /// Where the segment ends: the next segment's first frame, or the last frame plus one frame duration.
  let endTime: Double
  let startedAt: Date
  let endedAt: Date
  let frameCount: Int
  let sizeBytes: Int64
  /// Capture stopped before this segment (interruption, timestamp jump), so a gap before it is expected.
  let followsGap: Bool
  /// Frames missing inside this segment according to the timestamps.
  let missingFrames: Int
  /// Longest interval between two consecutive frames in this segment.
  let maxFrameInterval: Double

  var duration: Double { endTime - startTime }
  var measuredFps: Double { duration > 0 ? Double(frameCount) / duration : 0 }
}

/// How a segment's start lines up with the end of the segment before it.
enum SegmentContinuity: Equatable {
  /// Nothing to compare with (first segment, or the neighbour is missing).
  case unknown
  case continuous
  /// A gap after a known capture pause.
  case expectedGap(Double)
  /// A gap nobody announced: frames were lost between segments.
  case unexpectedGap(Double)
  /// The segment starts before the previous one ended.
  case overlap(Double)
}

/// Protects segments from deletion until released. Future replay/export code takes one before
/// reading segment files and releases it when done.
struct SegmentLease: Hashable {
  let id: Int
  let segmentIndexes: [Int]
}

struct SegmentInsertResult {
  let accepted: Bool
  let continuity: SegmentContinuity
  /// Expired, unprotected files that may be deleted now.
  let filesToDelete: [String]
}

struct SegmentStore {
  /// Footage kept: retention plus safety margin.
  let keepSeconds: Double
  /// Allowed difference between one segment's end and the next one's start.
  let continuityTolerance: Double

  /// Finished segments in the buffer, ascending index (= capture order).
  private(set) var segments: [BufferSegment] = []
  /// Expired from the buffer but still protected by a lease; deleted when released.
  private(set) var retired: [BufferSegment] = []
  private var pinCounts: [Int: Int] = [:]
  private var leases: [Int: [Int]] = [:]
  private var nextLeaseID = 1

  private(set) var expectedGaps = 0
  private(set) var unexpectedGaps = 0
  private(set) var overlaps = 0
  /// Index order and timestamp order disagree (should never happen).
  private(set) var orderingErrors = 0
  private(set) var duplicates = 0
  private(set) var expiredCount = 0

  init(keepSeconds: Double, continuityTolerance: Double = 0.001) {
    self.keepSeconds = keepSeconds
    self.continuityTolerance = continuityTolerance
  }

  var bufferedSeconds: Double { segments.reduce(0) { $0 + $1.duration } }
  var storageBytes: Int64 { segments.reduce(0) { $0 + $1.sizeBytes } }
  var retiredBytes: Int64 { retired.reduce(0) { $0 + $1.sizeBytes } }
  var protectedSegmentCount: Int { pinCounts.count }
  var activeLeaseCount: Int { leases.count }

  /// Every file the store still needs. Anything else in the folder (other than files still being
  /// written) is an orphan.
  var retainedFileNames: Set<String> { Set((segments + retired).map(\.fileName)) }

  func isProtected(_ index: Int) -> Bool { (pinCounts[index] ?? 0) > 0 }

  // MARK: - Adding segments

  /// Adds a finalized segment (in any completion order), checks it against its neighbours, then
  /// expires the oldest segments beyond `keepSeconds`.
  mutating func insert(_ segment: BufferSegment) -> SegmentInsertResult {
    guard !segments.contains(where: { $0.index == segment.index }),
          !retired.contains(where: { $0.index == segment.index })
    else {
      duplicates += 1
      return SegmentInsertResult(accepted: false, continuity: .unknown, filesToDelete: [])
    }

    let position = segments.firstIndex(where: { $0.index > segment.index }) ?? segments.endIndex
    let previous = position > 0 ? segments[position - 1] : nil
    let next = position < segments.endIndex ? segments[position] : nil

    // Index order is capture order, so timestamps must increase with it.
    if let previous, previous.startTime >= segment.startTime { orderingErrors += 1 }
    if let next, segment.startTime >= next.startTime { orderingErrors += 1 }

    var continuity = SegmentContinuity.unknown
    if let previous, previous.index == segment.index - 1 {
      continuity = Self.continuity(from: previous, to: segment, tolerance: continuityTolerance)
      record(continuity)
    }
    if let next, next.index == segment.index + 1 {
      // `next` finished first; its check against this segment could not run until now.
      record(Self.continuity(from: segment, to: next, tolerance: continuityTolerance))
    }

    segments.insert(segment, at: position)
    return SegmentInsertResult(accepted: true, continuity: continuity, filesToDelete: expire())
  }

  static func continuity(from previous: BufferSegment, to next: BufferSegment, tolerance: Double) -> SegmentContinuity {
    let delta = next.startTime - previous.endTime
    if abs(delta) <= tolerance { return .continuous }
    if delta < 0 { return .overlap(-delta) }
    return next.followsGap ? .expectedGap(delta) : .unexpectedGap(delta)
  }

  private mutating func record(_ continuity: SegmentContinuity) {
    switch continuity {
    case .expectedGap: expectedGaps += 1
    case .unexpectedGap: unexpectedGaps += 1
    case .overlap: overlaps += 1
    case .continuous, .unknown: break
    }
  }

  /// Drops the oldest segments while the rest still cover `keepSeconds`. The newest segment is
  /// never expired. Protected segments move to `retired` instead of being deleted.
  private mutating func expire() -> [String] {
    var total = bufferedSeconds
    var deletable: [String] = []
    while segments.count > 1, total - segments[0].duration >= keepSeconds {
      let oldest = segments.removeFirst()
      total -= oldest.duration
      expiredCount += 1
      if isProtected(oldest.index) {
        retired.append(oldest)
      } else {
        deletable.append(oldest.fileName)
      }
    }
    return deletable
  }

  // MARK: - Protection

  /// Protects every buffered segment overlapping [start, end) (capture-clock seconds).
  /// Returns nil when no segment overlaps.
  mutating func protect(from start: Double, to end: Double) -> SegmentLease? {
    let indexes = segments.filter { $0.endTime > start && $0.startTime < end }.map(\.index)
    return protect(indexes: indexes)
  }

  /// Protects specific buffered segments. Unknown indexes are ignored; returns nil if none match.
  mutating func protect(indexes: [Int]) -> SegmentLease? {
    let known = Set(segments.map(\.index))
    let chosen = Array(Set(indexes).intersection(known)).sorted()
    guard !chosen.isEmpty else { return nil }
    let lease = SegmentLease(id: nextLeaseID, segmentIndexes: chosen)
    nextLeaseID += 1
    leases[lease.id] = chosen
    for index in chosen {
      pinCounts[index, default: 0] += 1
    }
    return lease
  }

  /// Ends a lease. Returns retired files that are no longer protected and may be deleted now.
  /// Releasing the same lease twice does nothing.
  mutating func release(_ lease: SegmentLease) -> [String] {
    guard let indexes = leases.removeValue(forKey: lease.id) else { return [] }
    for index in indexes {
      let remaining = (pinCounts[index] ?? 1) - 1
      pinCounts[index] = remaining > 0 ? remaining : nil
    }
    // Read-only passes first, then one assignment: mutating `retired` while the closure reads
    // `self` (isProtected) would be an overlapping access.
    let free = retired.filter { !isProtected($0.index) }
    let stillProtected = retired.filter { isProtected($0.index) }
    retired = stillProtected
    return free.map(\.fileName)
  }

  // MARK: - New buffer run

  /// Starts a new buffer: every buffered segment expires. Protected ones stay (retired) until
  /// released; leases stay valid. Returns the files that may be deleted now.
  mutating func reset() -> [String] {
    var deletable: [String] = []
    for segment in segments {
      if isProtected(segment.index) {
        retired.append(segment)
      } else {
        deletable.append(segment.fileName)
      }
    }
    segments = []
    expectedGaps = 0
    unexpectedGaps = 0
    overlaps = 0
    orderingErrors = 0
    duplicates = 0
    expiredCount = 0
    return deletable
  }
}
