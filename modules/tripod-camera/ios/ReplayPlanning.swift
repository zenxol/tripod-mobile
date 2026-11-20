import Foundation

/**
 Pure logic for Save Replay: which footage to export, file naming, the save/cleanup sequence
 and one-at-a-time job ordering. No AVFoundation, so it is unit-tested on any machine with a
 Swift compiler (see modules/tripod-camera/tests). The AVFoundation side is ReplayExporter.swift.
 */

/// A failure reported to JavaScript as a promise rejection (`code`, `message`).
struct ReplayError: Error, Equatable {
  let code: String
  let message: String
}

enum ReplayDurations {
  /// Replay lengths offered in the UI, seconds.
  static let allowed: [Double] = [10, 15, 20, 30, 60, 120]
  static let defaultSeconds: Double = 20
}

/// One contiguous piece of one segment file.
struct ReplayPiece: Equatable {
  let segmentIndex: Int
  let fileName: String
  /// Where the piece starts inside the segment file (seconds after the file's first frame).
  let fileOffset: Double
  let duration: Double
  /// Capture-clock time of the piece's start.
  let captureStart: Double

  var captureEnd: Double { captureStart + duration }
}

/// The footage for one replay, in capture order.
struct ReplayPlan: Equatable {
  let requestedSeconds: Double
  /// Capture-clock time of the button press (the replay's last instant).
  let endpoint: Double
  let pieces: [ReplayPiece]

  /// Footage actually available inside the window.
  var duration: Double { pieces.reduce(0) { $0 + $1.duration } }
  var captureStart: Double { pieces.first?.captureStart ?? endpoint }
  var captureEnd: Double { pieces.last?.captureEnd ?? endpoint }
  var segmentIndexes: [Int] { pieces.map(\.segmentIndex) }
  /// Less footage than requested (buffer younger than the window, pauses, failed segments).
  var isShort: Bool { duration < requestedSeconds - ReplayPlanner.tolerance }
  /// Time inside the window with no footage between pieces (capture pauses, failed segments).
  var missingInside: Double {
    zip(pieces, pieces.dropFirst()).reduce(0) { total, pair in
      let gap = pair.1.captureStart - pair.0.captureEnd
      return gap > ReplayPlanner.tolerance ? total + gap : total
    }
  }
}

enum ReplayPlanner {
  static let tolerance = 0.001
  /// Pieces shorter than this (rounding slivers) are skipped.
  static let minimumPieceSeconds = 0.001

  /// Selects the footage in [endpoint - requestedSeconds, endpoint) from finalized segments,
  /// trimming the first and last segment using their real timestamps. Returns nil when nothing
  /// in the window has been recorded.
  static func plan(segments: [BufferSegment], endpoint: Double, requestedSeconds: Double) -> ReplayPlan? {
    guard requestedSeconds > 0, endpoint.isFinite else { return nil }
    let windowStart = endpoint - requestedSeconds
    var pieces: [ReplayPiece] = []
    for segment in segments.sorted(by: { $0.index < $1.index })
    where segment.endTime > windowStart && segment.startTime < endpoint {
      let from = max(segment.startTime, windowStart)
      let to = min(segment.endTime, endpoint)
      guard to - from >= minimumPieceSeconds else { continue }
      pieces.append(ReplayPiece(
        segmentIndex: segment.index,
        fileName: segment.fileName,
        fileOffset: from - segment.startTime,
        duration: to - from,
        captureStart: from))
    }
    guard !pieces.isEmpty else { return nil }
    return ReplayPlan(requestedSeconds: requestedSeconds, endpoint: endpoint, pieces: pieces)
  }
}

enum ReplayFileNaming {
  /// `replay_YYYYMMDD_HHMMSS_<6 hex>.<ext>` from the press time, retrying the random suffix until
  /// `isTaken` says the name is free. Nil only if 50 attempts all collide.
  static func makeFileName(
    date: Date,
    fileExtension: String,
    isTaken: (String) -> Bool,
    randomSuffix: () -> Int = { Int.random(in: 0..<0x100_0000) }
  ) -> String? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let stamp = formatter.string(from: date)
    for _ in 0..<50 {
      let hex = String(randomSuffix() & 0xFF_FFFF, radix: 16)
      let suffix = String(repeating: "0", count: max(0, 6 - hex.count)) + hex
      let name = "replay_\(stamp)_\(suffix).\(fileExtension)"
      if !isTaken(name) {
        return name
      }
    }
    return nil
  }
}

enum ReplaySaveRunner {
  struct Output: Equatable {
    let url: URL
    let durationSeconds: Double
  }

  /// Export → verify → move into place, never leaving a partial file behind.
  /// - `export` writes the clip to `tempURL`.
  /// - `verify` opens it and returns its duration (throws if unreadable).
  /// - `release` (the segment protection) is called exactly once, whatever happens.
  /// The final file appears only after a successful verify, via a rename.
  static func run(
    plan: ReplayPlan,
    tempURL: URL,
    finalURL: URL,
    export: (ReplayPlan, URL) async throws -> Void,
    verify: (URL) async throws -> Double,
    release: () -> Void
  ) async -> Result<Output, ReplayError> {
    defer { release() }
    let fileManager = FileManager.default
    func discardTemp() {
      try? fileManager.removeItem(at: tempURL)
    }

    do {
      try fileManager.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      return .failure(ReplayError(code: "ERR_FILE", message: "Could not create the replay folders: \(error.localizedDescription)"))
    }
    discardTemp()

    do {
      try await export(plan, tempURL)
    } catch {
      discardTemp()
      return .failure(ReplayError(code: "ERR_EXPORT_FAILED", message: "The replay could not be exported: \(describe(error))"))
    }
    guard fileManager.fileExists(atPath: tempURL.path) else {
      return .failure(ReplayError(code: "ERR_EXPORT_FAILED", message: "The export finished without producing a file."))
    }

    let duration: Double
    do {
      duration = try await verify(tempURL)
    } catch {
      discardTemp()
      return .failure(ReplayError(code: "ERR_VERIFY_FAILED", message: "The exported replay could not be read: \(describe(error))"))
    }
    guard duration > 0 else {
      discardTemp()
      return .failure(ReplayError(code: "ERR_VERIFY_FAILED", message: "The exported replay is empty."))
    }

    guard !fileManager.fileExists(atPath: finalURL.path) else {
      discardTemp()
      return .failure(ReplayError(code: "ERR_FILE", message: "A replay with this name already exists."))
    }
    do {
      try fileManager.moveItem(at: tempURL, to: finalURL)
    } catch {
      discardTemp()
      return .failure(ReplayError(code: "ERR_FILE", message: "The replay could not be saved: \(error.localizedDescription)"))
    }
    return .success(Output(url: finalURL, durationSeconds: duration))
  }

  private static func describe(_ error: Error) -> String {
    (error as? ReplayError)?.message ?? error.localizedDescription
  }
}

/// Runs async jobs strictly one at a time, in the order they were added. Used so repeated
/// Save Replay presses export one after another instead of competing for the disk and encoder.
final class SerialJobQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var jobs: [@Sendable () async -> Void] = []
  private var isRunning = false

  /// Jobs waiting or running.
  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return jobs.count + (isRunning ? 1 : 0)
  }

  func enqueue(_ job: @escaping @Sendable () async -> Void) {
    lock.lock()
    jobs.append(job)
    let shouldStart = !isRunning
    if shouldStart {
      isRunning = true
    }
    lock.unlock()
    if shouldStart {
      runNext()
    }
  }

  private func runNext() {
    lock.lock()
    guard !jobs.isEmpty else {
      isRunning = false
      lock.unlock()
      return
    }
    let job = jobs.removeFirst()
    lock.unlock()
    Task.detached(priority: .utility) { [self] in
      await job()
      runNext()
    }
  }
}
