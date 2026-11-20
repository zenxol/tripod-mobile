import AVFoundation
import Foundation
import os

/// What the recorder needs from the camera, captured when the buffer starts.
struct BufferConfiguration {
  /// Writer settings to try in order (tuned, then AVFoundation's recommendation, then minimal).
  let videoSettingsCandidates: [[String: Any]]
  /// Display rotation stored in the file as metadata; pixels are never rotated.
  let transform: CGAffineTransform
  let codec: String
  /// Size as displayed (portrait), for diagnostics.
  let displayWidth: Int
  let displayHeight: Int
  let fps: Double
  /// The capture session's clock: sample timestamps are in this clock's time base.
  let clock: CMClock
  /// Used for the free-space check before starting.
  let estimatedBytesPerSecond: Double
}

enum BufferState: String {
  case idle
  case starting
  case buffering
  /// Capture is interrupted (background, call, ...); the open segment was finished and kept.
  case paused
  case stopping
  case error
}

extension BufferSegment {
  func dictionary() -> [String: Any] {
    [
      "index": index,
      "fileName": fileName,
      "uri": RollingBufferRecorder.directory.appendingPathComponent(fileName).absoluteString,
      "startTime": startTime,
      "endTime": endTime,
      "durationSeconds": RollingBufferRecorder.round(duration, places: 3),
      "startedAt": RollingBufferRecorder.isoFormatter.string(from: startedAt),
      "endedAt": RollingBufferRecorder.isoFormatter.string(from: endedAt),
      "frameCount": frameCount,
      "fps": RollingBufferRecorder.round(measuredFps, places: 2),
      "missingFrames": missingFrames,
      "maxFrameIntervalMs": RollingBufferRecorder.round(maxFrameInterval * 1000, places: 1),
      "sizeBytes": Double(sizeBytes),
      "followsGap": followsGap,
    ]
  }
}

/**
 Continuous capture into short compressed segments: the base of the 120-second replay buffer.

 Pipeline: AVCaptureVideoDataOutput delivers each camera frame (as captured, no conversion)
 on `videoQueue`; it is appended immediately to the open segment's AVAssetWriter, which
 encodes it in hardware (HEVC, else H.264). No frames are kept in memory beyond what the
 encoder holds for a moment. The capture session is never stopped or reconfigured to rotate.

 Rotation: the segment closes at the first frame whose presentation timestamp is at least
 `segmentSeconds` after the segment's first frame. That frame becomes the first frame of the
 next segment, and the old segment ends exactly at its timestamp. The next writer is created
 and started on `prepQueue` in advance, so switching costs almost nothing on the capture queue.

 Measurement: all timing comes from sample presentation timestamps. Frames missing inside the
 stream (intervals > 1.5 frame durations), camera drops (with their reason), encoder drops,
 out-of-order frames, gaps and overlaps between segments, and failed segments are counted,
 logged and reported in the status.

 Files: `tmp/rolling-buffer/writing_NNNNNN.mov` while open, renamed to `segment_NNNNNN.mov`
 only after `finishWriting` succeeds. `SegmentStore` decides what expires; only finalized,
 unprotected segments are ever deleted. Indexes keep increasing for the whole app session, so
 a protected file from an earlier run can never collide with a new one.

 Threads: `videoQueue` owns the writers and frame state; `storeQueue` renames, measures and
 deletes files; `prepQueue` builds writers; `eventQueue` delivers status events in order. The
 shared model is guarded by `lock`.
 */
final class RollingBufferRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  static let segmentSeconds: Double = 5
  static let retentionSeconds: Double = 120
  static let safetyMarginSeconds: Double = 10
  /// Stop buffering (with an error) rather than fill the phone.
  static let minFreeBytesWhileBuffering: Int64 = 300 * 1024 * 1024
  /// A jump in frame timestamps longer than this is treated as a capture gap, not dropped frames.
  static let gapThresholdSeconds: Double = 0.5
  /// Stop gives up waiting for a segment that never finishes (so the UI can't hang).
  static let stopTimeoutSeconds: Double = 10
  /// A summary line is logged every this many segments (30 s).
  static let summaryEverySegments = 6
  /// A replay cut waits at most this long for a frame after the press before closing the
  /// segment at its last frame (only if capture stalls).
  static let cutTimeoutSeconds: Double = 0.5

  static var directory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("rolling-buffer", isDirectory: true)
  }

  static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let log = Logger(subsystem: "com.zenxol.tripod", category: "buffer")

  /// The video data output's delegate queue.
  let videoQueue = DispatchQueue(label: "com.zenxol.tripod.buffer.video", qos: .userInitiated)
  private let prepQueue = DispatchQueue(label: "com.zenxol.tripod.buffer.prepare", qos: .userInitiated)
  private let storeQueue = DispatchQueue(label: "com.zenxol.tripod.buffer.store", qos: .utility)
  private let eventQueue = DispatchQueue(label: "com.zenxol.tripod.buffer.events", qos: .utility)
  private let pendingFinishes = DispatchGroup()

  // videoQueue only.
  private var config: BufferConfiguration?
  private var isAccepting = false
  private var generation = 0
  /// Never reset while the app runs (file names stay unique across buffer runs).
  private var nextIndex = 1
  private var current: OpenSegment?
  private var prepared: PreparedWriter?
  private var isPreparing = false
  private var lastPTS: CMTime?
  private var nominalFrameDuration = CMTime(value: 1, timescale: 60)
  private var nextSegmentFollowsGap = false
  /// Replay requests waiting for the open segment to be cut after their endpoint.
  private var cutWaiters: [CutWaiter] = []
  private var nextWaiterID = 0

  private struct CutWaiter {
    let id: Int
    let endpoint: CMTime
    let resume: () -> Void
  }

  // Shared; guarded by `lock`.
  private let lock = NSLock()
  private var model = Model()
  /// The capture session's clock (sample timestamps' time base), set when the buffer first starts.
  private var captureClock: CMClock?
  private var statusHandler: (([String: Any]) -> Void)?
  private var failureHandler: ((RecordingError) -> Void)?

  private struct Model {
    var generation = 0
    var state: BufferState = .idle
    var message: String?
    var store = SegmentStore(
      keepSeconds: RollingBufferRecorder.retentionSeconds + RollingBufferRecorder.safetyMarginSeconds)
    var framesWritten = 0
    var captureDroppedFrames = 0
    var droppedLate = 0
    var droppedOutOfBuffers = 0
    var droppedOther = 0
    var writerDroppedFrames = 0
    var missingFrames = 0
    var outOfOrderFrames = 0
    var gaps = 0
    var failedSegments = 0
    var orphansRemoved = 0
    var diskBytes: Int64 = 0
    var fileCount = 0
    var memoryBytes: Int64 = 0
    var segmentsSinceSummary = 0
    var codec = "none"
    var width = 0
    var height = 0
    var fps: Double = 0
  }

  private final class PreparedWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let index: Int
    let generation: Int
    let tempURL: URL
    let finalURL: URL

    init(writer: AVAssetWriter, input: AVAssetWriterInput, index: Int, generation: Int, tempURL: URL, finalURL: URL) {
      self.writer = writer
      self.input = input
      self.index = index
      self.generation = generation
      self.tempURL = tempURL
      self.finalURL = finalURL
    }
  }

  private final class OpenSegment {
    let writer: PreparedWriter
    let startTime: CMTime
    let startedAt: Date
    let followsGap: Bool
    var lastTime: CMTime
    var frameCount = 0
    var missingFrames = 0
    var maxFrameInterval: Double = 0

    init(writer: PreparedWriter, startTime: CMTime, startedAt: Date, followsGap: Bool) {
      self.writer = writer
      self.startTime = startTime
      self.startedAt = startedAt
      self.followsGap = followsGap
      self.lastTime = startTime
    }
  }

  // MARK: - Public API (any thread)

  /// Receives the status dictionary on every state change and finished segment, in order.
  func setStatusHandler(_ handler: (([String: Any]) -> Void)?) {
    lock.lock()
    statusHandler = handler
    lock.unlock()
  }

  /// Called (on a background queue) after the buffer stopped itself because of an error.
  func setFailureHandler(_ handler: ((RecordingError) -> Void)?) {
    lock.lock()
    failureHandler = handler
    lock.unlock()
  }

  func currentStatus() -> [String: Any] {
    Self.statusDictionary(withModel { $0 })
  }

  func currentSegments() -> [[String: Any]] {
    withModel { $0.store.segments }.map { $0.dictionary() }
  }

  /// Protects the finalized segments overlapping [start, end) (capture-clock seconds, as in the
  /// segment metadata) from deletion until `releaseSegments` is called. For future replay/export.
  func protectSegments(from start: Double, to end: Double) -> SegmentLease? {
    let lease = withModel { $0.store.protect(from: start, to: end) }
    if let lease {
      Self.log.info("Protected segments \(lease.segmentIndexes.description, privacy: .public) (lease \(lease.id))")
      emitStatus()
    }
    return lease
  }

  /// Ends a protection. Segments that expired meanwhile are deleted now.
  func releaseSegments(_ lease: SegmentLease) {
    let files = withModel { $0.store.release(lease) }
    storeQueue.async { [self] in
      Self.deleteFiles(files)
      Self.log.info("Released lease \(lease.id); deleted \(files.count) expired segment(s)")
      refreshDiskUsage()
      emitStatus()
    }
  }

  // MARK: - Replay reservation

  /// What a replay export needs: the trimmed footage plan and the protection that keeps its
  /// files alive. The caller must `releaseSegments(lease)` when done.
  struct ReplayReservation {
    let plan: ReplayPlan
    let lease: SegmentLease
    /// Wall-clock times of the replay's first and last instant.
    let startedAt: Date
    let endedAt: Date
  }

  /// "Now" on the frames' own timeline (the capture session clock). Read at the moment of a
  /// Save Replay press. Nil before the buffer has ever started.
  func captureNow() -> CMTime? {
    guard let clock = withLock({ captureClock }) else { return nil }
    return CMClockGetTime(clock)
  }

  /// Makes all footage up to `endpoint` final without pausing capture, then selects and
  /// protects the replay window [endpoint - seconds, endpoint). Completes on a background queue.
  ///
  /// The open segment is cut at the first frame after `endpoint` (normally within one frame
  /// time); that frame starts the next segment, so the timeline stays continuous. If the buffer
  /// is not live (stopped, paused, error), the window ends at the last recorded frame instead.
  func reserveReplay(
    endpoint: CMTime, seconds: Double, completion: @escaping (Result<ReplayReservation, ReplayError>) -> Void
  ) {
    videoQueue.async { [self] in
      let isLive = isAccepting && current != nil
      let reserve: () -> Void = { [self] in
        // Wait for the cut segment (and any other finishing segment) to be finalized.
        waitForPendingFinishes { [self] _ in
          completion(makeReservation(endpoint: endpoint.seconds, seconds: seconds, isLive: isLive))
        }
      }
      guard isLive, let segment = current, segment.startTime < endpoint else {
        reserve()
        return
      }
      let id = nextWaiterID
      nextWaiterID += 1
      cutWaiters.append(CutWaiter(id: id, endpoint: endpoint, resume: reserve))
      // Safety net if capture stalls right after the press: close the segment at its last frame.
      videoQueue.asyncAfter(deadline: .now() + Self.cutTimeoutSeconds) { [self] in
        guard cutWaiters.contains(where: { $0.id == id }) else { return }
        Self.log.notice("Replay cut: no frame within \(Self.cutTimeoutSeconds) s of the press; closing the segment at its last frame")
        if let open = current {
          finish(open, endTime: open.lastTime + nominalFrameDuration, keepAlive: false)
          current = nil
        }
        resumeCutWaiters(before: nil)
      }
    }
  }

  /// Resumes the replay requests whose endpoint is before `pts` (all of them if nil).
  /// videoQueue only; call after the segment containing those endpoints was finished.
  private func resumeCutWaiters(before pts: CMTime?) {
    guard !cutWaiters.isEmpty else { return }
    var ready: [CutWaiter] = []
    var waiting: [CutWaiter] = []
    for waiter in cutWaiters {
      if let pts, waiter.endpoint >= pts {
        waiting.append(waiter)
      } else {
        ready.append(waiter)
      }
    }
    cutWaiters = waiting
    ready.forEach { $0.resume() }
  }

  /// storeQueue. Selects the window from finalized segments and protects it atomically (under
  /// the lock, so retention can't delete anything in between).
  private func makeReservation(endpoint: Double, seconds: Double, isLive: Bool) -> Result<ReplayReservation, ReplayError> {
    withModel { (model: inout Model) -> Result<ReplayReservation, ReplayError> in
      let segments = model.store.segments
      guard let last = segments.last else {
        return .failure(ReplayError(code: "ERR_NO_FOOTAGE", message: "Nothing has been buffered yet."))
      }
      let end = isLive ? endpoint : min(endpoint, last.endTime)
      guard let plan = ReplayPlanner.plan(segments: segments, endpoint: end, requestedSeconds: seconds) else {
        return .failure(ReplayError(
          code: "ERR_NO_FOOTAGE", message: "No buffered footage in the last \(Int(seconds)) seconds."))
      }
      guard let lease = model.store.protect(indexes: plan.segmentIndexes) else {
        return .failure(ReplayError(code: "ERR_NO_FOOTAGE", message: "The buffered footage is no longer available."))
      }
      let byIndex = Dictionary(uniqueKeysWithValues: segments.map { ($0.index, $0) })
      let first = plan.pieces[0]
      let lastPiece = plan.pieces[plan.pieces.count - 1]
      let startedAt = byIndex[first.segmentIndex].map { $0.startedAt.addingTimeInterval(first.fileOffset) } ?? Date()
      let endedAt = byIndex[lastPiece.segmentIndex].map {
        $0.startedAt.addingTimeInterval(lastPiece.fileOffset + lastPiece.duration)
      } ?? Date()
      return .success(ReplayReservation(plan: plan, lease: lease, startedAt: startedAt, endedAt: endedAt))
    }
  }

  /// Starts a new buffer run and accepts frames. Completes on `videoQueue`.
  func start(_ config: BufferConfiguration, completion: @escaping (Result<[String: Any], RecordingError>) -> Void) {
    videoQueue.async { [self] in
      guard !isAccepting else {
        return completion(.failure(RecordingError(
          code: "ERR_BUFFER_ACTIVE", message: "The replay buffer is already running.")))
      }
      generation += 1
      let runGeneration = generation

      // Previous run's segments expire; protected ones stay until released.
      let expiredFiles = withModel { (model: inout Model) -> [String] in
        let files = model.store.reset()
        var fresh = Model()
        fresh.store = model.store
        fresh.orphansRemoved = model.orphansRemoved
        fresh.generation = runGeneration
        fresh.state = .starting
        fresh.codec = config.codec
        fresh.width = config.displayWidth
        fresh.height = config.displayHeight
        fresh.fps = config.fps
        model = fresh
        return files
      }
      Self.deleteFiles(expiredFiles)

      let keepSeconds = Self.retentionSeconds + Self.safetyMarginSeconds + Self.segmentSeconds
      let neededBytes = Int64(config.estimatedBytesPerSecond * keepSeconds) + Self.minFreeBytesWhileBuffering
      if let free = Self.availableBytes(), free < neededBytes {
        return failStart(RecordingError(
          code: "ERR_LOW_STORAGE",
          message: "Not enough free storage for the replay buffer (\(free / 1_048_576) MB free, about \(neededBytes / 1_048_576) MB needed)."),
          completion)
      }

      do {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
      } catch {
        return failStart(RecordingError(
          code: "ERR_FILE", message: "Could not prepare the buffer folder: \(error.localizedDescription)"), completion)
      }
      // Nothing is being written now: anything not protected is a leftover.
      let retained = withModel { $0.store.retainedFileNames }
      Self.removeFiles(notIn: retained)

      self.config = config
      withLock { captureClock = config.clock }
      nominalFrameDuration = Self.frameDuration(fps: config.fps)
      lastPTS = nil
      current = nil
      isPreparing = false
      nextSegmentFollowsGap = false

      // The first writer is ready before frames are accepted, so the first segment starts on
      // the very first frame.
      do {
        prepared = try Self.makeWriter(index: nextIndex, generation: runGeneration, config: config)
        nextIndex += 1
      } catch {
        return failStart(Self.recordingError(error), completion)
      }

      isAccepting = true
      Self.log.info("Buffer started: \(config.codec, privacy: .public) \(config.displayWidth)x\(config.displayHeight) @ \(config.fps) fps, \(Self.segmentSeconds) s segments, keeping \(Self.retentionSeconds + Self.safetyMarginSeconds) s")
      storeQueue.async { [self] in
        refreshDiskUsage()
        emitStatus()
      }
      completion(.success(currentStatus()))
    }
  }

  /// Finishes the open segment, waits (up to `stopTimeoutSeconds`) for every pending file, then
  /// completes with the final status. Finished segments stay on disk until the next start (or
  /// app launch). Safe to call repeatedly or while not running.
  func stop(_ completion: @escaping ([String: Any]) -> Void) {
    videoQueue.async { [self] in
      if isAccepting {
        setState(.stopping, nil)
        stopAccepting(keepAlive: true)
      }
      waitForPendingFinishes { [self] timedOut in
        withModel {
          if $0.state != .error {
            $0.state = .idle
            $0.message = timedOut ? "A segment did not finish writing in time; it was skipped." : nil
          }
        }
        if timedOut {
          Self.log.error("Buffer stop: a segment did not finish within \(Self.stopTimeoutSeconds) s")
        }
        refreshDiskUsage()
        logSummary(reason: "stopped")
        emitStatus()
        completion(currentStatus())
      }
    }
  }

  /// Capture is interrupted (or the app is closing): finish the open segment so it is kept.
  /// Buffering resumes by itself with a new segment when frames arrive again.
  func pause(_ reason: String) {
    videoQueue.async { [self] in
      guard isAccepting else { return }
      if let segment = current {
        finish(segment, endTime: segment.lastTime + nominalFrameDuration, keepAlive: true)
        current = nil
      }
      // Replay requests get the footage up to the pause.
      resumeCutWaiters(before: nil)
      if lastPTS != nil {
        withModel { $0.gaps += 1 }
      }
      // The next frame starts a new segment without being counted as another gap.
      lastPTS = nil
      nextSegmentFollowsGap = true
      Self.log.notice("Buffer paused: \(reason, privacy: .public)")
      setState(.paused, reason)
    }
  }

  /// The device frame rate changed (thermal throttling); used to detect missing frames.
  func setNominalFps(_ fps: Double) {
    videoQueue.async { [self] in
      nominalFrameDuration = Self.frameDuration(fps: fps)
      withModel { $0.fps = fps }
    }
  }

  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (videoQueue)

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard isAccepting else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isValid, pts.isNumeric else { return }

    if let last = lastPTS {
      // Never write out of order (AVAssetWriter would fail the whole segment).
      guard pts > last else {
        withModel { $0.outOfOrderFrames += 1 }
        return
      }
      let delta = (pts - last).seconds
      if delta > Self.gapThresholdSeconds {
        // Capture stopped and resumed without an interruption notice: close the segment at
        // its last frame and start a new one, instead of stretching one frame across the gap.
        if let segment = current {
          finish(segment, endTime: segment.lastTime + nominalFrameDuration, keepAlive: false)
          current = nil
        }
        resumeCutWaiters(before: pts)
        nextSegmentFollowsGap = true
        withModel { $0.gaps += 1 }
        Self.log.notice("Buffer: \(delta) s gap in frame timestamps")
      } else {
        current?.maxFrameInterval = max(current?.maxFrameInterval ?? 0, delta)
        let nominal = nominalFrameDuration.seconds
        if nominal > 0, delta > nominal * 1.5 {
          let missing = max(Int((delta / nominal).rounded()) - 1, 1)
          current?.missingFrames += missing
          withModel { $0.missingFrames += missing }
        }
      }
    }
    lastPTS = pts

    // Rotate on actual timestamps: this frame starts the next segment, and the old one ends
    // exactly where it begins. The session keeps running; no frame is skipped. A Save Replay
    // press forces the same rotation at the first frame after its endpoint ("cut"), so the
    // footage up to the press is finalized without waiting for the 5-second boundary.
    let cutDue = cutWaiters.contains { $0.endpoint < pts }
    if let segment = current, cutDue || (pts - segment.startTime).seconds >= Self.segmentSeconds {
      finish(segment, endTime: pts, keepAlive: false)
      current = nil
    }
    if cutDue {
      resumeCutWaiters(before: pts)
    }
    if current == nil {
      guard openSegment(at: pts) else { return }
    }
    guard let segment = current else { return }

    let writer = segment.writer.writer
    guard writer.status == .writing else {
      // Appending to a failed writer raises an exception; stop cleanly instead.
      let reason = writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
      fail(RecordingError(code: "ERR_BUFFER_WRITE", message: "The video encoder stopped: \(reason)"))
      return
    }
    let input = segment.writer.input
    guard input.isReadyForMoreMediaData else {
      withModel { $0.writerDroppedFrames += 1 }
      return
    }
    if input.append(sampleBuffer) {
      segment.frameCount += 1
      segment.lastTime = pts
      withModel { $0.framesWritten += 1 }
    } else {
      let reason = writer.error?.localizedDescription ?? "unknown error"
      fail(RecordingError(code: "ERR_BUFFER_WRITE", message: "Writing a buffer segment failed: \(reason)"))
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard isAccepting else { return }
    let reason = CMGetAttachment(
      sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
    withModel {
      $0.captureDroppedFrames += 1
      if reason == (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) {
        $0.droppedLate += 1
      } else if reason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) {
        $0.droppedOutOfBuffers += 1
      } else {
        $0.droppedOther += 1
      }
    }
  }

  // MARK: - Segments (videoQueue)

  private func openSegment(at pts: CMTime) -> Bool {
    guard let config else { return false }
    var candidate = prepared
    prepared = nil
    if let waiting = candidate, waiting.writer.status != .writing {
      // The prepared writer failed while waiting (e.g. media services reset).
      Self.log.error("Buffer: prepared writer \(waiting.index) is no longer usable; creating a new one")
      Self.discard(waiting)
      candidate = nil
    }
    if candidate == nil {
      Self.log.notice("Buffer: next writer was not ready; creating it on the capture queue")
      do {
        candidate = try Self.makeWriter(index: nextIndex, generation: generation, config: config)
        nextIndex += 1
      } catch {
        fail(Self.recordingError(error))
        return false
      }
    }
    guard let writer = candidate else { return false }

    writer.writer.startSession(atSourceTime: pts)
    current = OpenSegment(
      writer: writer,
      startTime: pts,
      startedAt: Self.wallClock(for: pts, clock: config.clock),
      followsGap: nextSegmentFollowsGap)
    nextSegmentFollowsGap = false
    if withModel({ $0.state }) != .buffering {
      setState(.buffering, nil)
    }
    prepareNextWriter()
    return true
  }

  /// Builds and starts the next writer off the capture queue.
  private func prepareNextWriter() {
    guard isAccepting, prepared == nil, !isPreparing, let config else { return }
    isPreparing = true
    let index = nextIndex
    nextIndex += 1
    let runGeneration = generation
    prepQueue.async { [self] in
      let result = Result { try Self.makeWriter(index: index, generation: runGeneration, config: config) }
      videoQueue.async { [self] in
        isPreparing = false
        switch result {
        case .success(let writer):
          if runGeneration == generation, isAccepting, prepared == nil {
            prepared = writer
          } else {
            Self.discard(writer)
          }
        case .failure(let error):
          if runGeneration == generation, isAccepting {
            fail(Self.recordingError(error))
          }
        }
      }
    }
  }

  /// Closes a segment. `endTime` is where the next segment starts (or the last frame's end).
  /// `keepAlive` asks iOS for time to finish the file when the app may be leaving the foreground.
  private func finish(_ segment: OpenSegment, endTime: CMTime, keepAlive: Bool) {
    let prepared = segment.writer
    let writer = prepared.writer
    guard segment.frameCount > 0, let config else {
      Self.discard(prepared)
      return
    }
    guard writer.status == .writing else {
      // endSession/finishWriting on a failed writer raise exceptions: count it and clean up.
      let reason = writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
      Self.log.error("Buffer segment \(prepared.index) failed before finishing: \(reason, privacy: .public)")
      Self.discard(prepared)
      withModel { $0.failedSegments += 1 }
      emitStatus()
      return
    }
    writer.endSession(atSourceTime: endTime)
    prepared.input.markAsFinished()

    let record = PendingSegment(
      index: prepared.index,
      generation: prepared.generation,
      tempURL: prepared.tempURL,
      finalURL: prepared.finalURL,
      startTime: segment.startTime,
      endTime: endTime,
      startedAt: segment.startedAt,
      endedAt: Self.wallClock(for: endTime, clock: config.clock),
      frameCount: segment.frameCount,
      followsGap: segment.followsGap,
      missingFrames: segment.missingFrames,
      maxFrameInterval: segment.maxFrameInterval)

    pendingFinishes.enter()
    let finished = DispatchSemaphore(value: 0)
    if keepAlive {
      ProcessInfo.processInfo.performExpiringActivity(withReason: "Finishing a replay buffer segment") { expired in
        if !expired {
          _ = finished.wait(timeout: .now() + Self.stopTimeoutSeconds)
        }
      }
    }
    writer.finishWriting { [self] in
      let succeeded = writer.status == .completed
      let reason = writer.error?.localizedDescription
      storeQueue.async { [self] in
        complete(record, succeeded: succeeded, reason: reason)
        finished.signal()
        pendingFinishes.leave()
      }
    }
  }

  private func stopAccepting(keepAlive: Bool) {
    isAccepting = false
    if let segment = current {
      finish(segment, endTime: segment.lastTime + nominalFrameDuration, keepAlive: keepAlive)
    }
    current = nil
    resumeCutWaiters(before: nil)
    if let writer = prepared {
      Self.discard(writer)
    }
    prepared = nil
    lastPTS = nil
  }

  private func fail(_ error: RecordingError) {
    guard isAccepting else { return }
    Self.log.error("Buffer failed: \(error.code, privacy: .public) \(error.message, privacy: .public)")
    stopAccepting(keepAlive: true)
    setState(.error, error.message)
    let handler = withLock { failureHandler }
    waitForPendingFinishes { _ in
      handler?(error)
    }
  }

  private func failStart(
    _ error: RecordingError, _ completion: (Result<[String: Any], RecordingError>) -> Void
  ) {
    Self.log.error("Buffer could not start: \(error.code, privacy: .public) \(error.message, privacy: .public)")
    setState(.error, error.message)
    completion(.failure(error))
  }

  /// Runs `then` on `storeQueue` once every segment being finished is done, or after the timeout.
  private func waitForPendingFinishes(_ then: @escaping (Bool) -> Void) {
    let group = pendingFinishes
    // Wait off storeQueue: the finish completions themselves run there.
    DispatchQueue.global(qos: .utility).async { [self] in
      let timedOut = group.wait(timeout: .now() + Self.stopTimeoutSeconds) == .timedOut
      storeQueue.async {
        then(timedOut)
      }
    }
  }

  // MARK: - Files (storeQueue)

  private struct PendingSegment {
    let index: Int
    let generation: Int
    let tempURL: URL
    let finalURL: URL
    let startTime: CMTime
    let endTime: CMTime
    let startedAt: Date
    let endedAt: Date
    let frameCount: Int
    let followsGap: Bool
    let missingFrames: Int
    let maxFrameInterval: Double
  }

  private func complete(_ record: PendingSegment, succeeded: Bool, reason: String?) {
    let fileManager = FileManager.default
    guard record.generation == withModel({ $0.generation }) else {
      // A segment from a previous run finished late; that buffer is gone.
      try? fileManager.removeItem(at: record.tempURL)
      return
    }
    guard succeeded else {
      try? fileManager.removeItem(at: record.tempURL)
      withModel { $0.failedSegments += 1 }
      Self.log.error("Buffer segment \(record.index) failed: \(reason ?? "unknown error", privacy: .public)")
      emitStatus()
      return
    }
    do {
      try? fileManager.removeItem(at: record.finalURL)
      try fileManager.moveItem(at: record.tempURL, to: record.finalURL)
    } catch {
      try? fileManager.removeItem(at: record.tempURL)
      withModel { $0.failedSegments += 1 }
      Self.log.error("Buffer segment \(record.index) could not be renamed: \(error.localizedDescription, privacy: .public)")
      emitStatus()
      return
    }

    let attributes = try? fileManager.attributesOfItem(atPath: record.finalURL.path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let segment = BufferSegment(
      index: record.index,
      fileName: record.finalURL.lastPathComponent,
      startTime: record.startTime.seconds,
      endTime: record.endTime.seconds,
      startedAt: record.startedAt,
      endedAt: record.endedAt,
      frameCount: record.frameCount,
      sizeBytes: size,
      followsGap: record.followsGap,
      missingFrames: record.missingFrames,
      maxFrameInterval: record.maxFrameInterval)

    let (result, summaryDue) = withModel { (model: inout Model) -> (SegmentInsertResult, Bool) in
      let result = model.store.insert(segment)
      model.segmentsSinceSummary += 1
      let due = model.segmentsSinceSummary >= Self.summaryEverySegments
      if due {
        model.segmentsSinceSummary = 0
      }
      return (result, due)
    }
    guard result.accepted else {
      Self.log.error("Buffer segment \(segment.index) was reported twice; ignored")
      return
    }
    // Only finalized, expired, unprotected segments reach this list.
    Self.deleteFiles(result.filesToDelete)

    Self.log.info("Segment \(segment.index): \(segment.duration) s, \(segment.frameCount) frames, \(segment.measuredFps) fps, \(segment.missingFrames) missing, max interval \(segment.maxFrameInterval * 1000) ms, \(segment.sizeBytes) bytes; expired \(result.filesToDelete.count)")
    switch result.continuity {
    case .unexpectedGap(let seconds):
      Self.log.error("Segment \(segment.index) starts \(seconds * 1000) ms after the previous segment ended (unexpected gap)")
    case .overlap(let seconds):
      Self.log.error("Segment \(segment.index) overlaps the previous segment by \(seconds * 1000) ms")
    case .expectedGap(let seconds):
      Self.log.notice("Segment \(segment.index) resumes after a \(seconds) s capture pause")
    case .continuous, .unknown:
      break
    }

    refreshDiskUsage()
    if summaryDue {
      logSummary(reason: "periodic")
    }
    emitStatus()
  }

  /// Measures the folder, removes orphaned finalized files, and samples app memory.
  /// storeQueue only (the only queue that renames or deletes segment files).
  private func refreshDiskUsage() {
    let fileManager = FileManager.default
    let retained = withModel { $0.store.retainedFileNames }
    let urls = (try? fileManager.contentsOfDirectory(
      at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    var bytes: Int64 = 0
    var count = 0
    var removed = 0
    for url in urls {
      let name = url.lastPathComponent
      // A finalized file the store doesn't know: leftover from an earlier run or a failed
      // rename. Files still being written (writing_*) are never touched here.
      if name.hasPrefix("segment_"), !retained.contains(name) {
        try? fileManager.removeItem(at: url)
        removed += 1
        continue
      }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      bytes += Int64(size)
      count += 1
    }
    if removed > 0 {
      Self.log.notice("Removed \(removed) orphaned segment file(s)")
    }
    let memory = Self.memoryFootprintBytes()
    withModel {
      $0.diskBytes = bytes
      $0.fileCount = count
      $0.orphansRemoved += removed
      if let memory {
        $0.memoryBytes = memory
      }
    }
  }

  private func logSummary(reason: String) {
    let m = withModel { $0 }
    let last = m.store.segments.last
    Self.log.notice("""
      Buffer summary (\(reason, privacy: .public)): \(m.state.rawValue, privacy: .public), \
      \(m.store.segments.count) segments, \(m.store.bufferedSeconds) s buffered, \
      disk \(m.diskBytes / 1_048_576) MB in \(m.fileCount) files, RAM \(m.memoryBytes / 1_048_576) MB, \
      last fps \(last?.measuredFps ?? 0), frames \(m.framesWritten), \
      dropped camera \(m.captureDroppedFrames) (late \(m.droppedLate), buffers \(m.droppedOutOfBuffers)), \
      dropped encoder \(m.writerDroppedFrames), missing \(m.missingFrames), out of order \(m.outOfOrderFrames), \
      pauses \(m.gaps), segment gaps \(m.store.unexpectedGaps), overlaps \(m.store.overlaps), \
      failed \(m.failedSegments), protected \(m.store.protectedSegmentCount)
      """)
  }

  // MARK: - Status

  private func setState(_ state: BufferState, _ message: String?) {
    withModel {
      $0.state = state
      $0.message = message
    }
    emitStatus()
  }

  /// Snapshots and delivers on one serial queue, so events can't overtake each other and the
  /// last event always carries the newest state.
  private func emitStatus() {
    eventQueue.async { [self] in
      let (handler, snapshot) = withLock { (statusHandler, model) }
      handler?(Self.statusDictionary(snapshot))
    }
  }

  private static func statusDictionary(_ model: Model) -> [String: Any] {
    let store = model.store
    var result: [String: Any] = [
      "state": model.state.rawValue,
      "segmentCount": store.segments.count,
      "bufferedSeconds": round(store.bufferedSeconds, places: 2),
      "storageBytes": Double(store.storageBytes),
      "diskBytes": Double(model.diskBytes),
      "fileCount": model.fileCount,
      "memoryBytes": Double(model.memoryBytes),
      "segmentSeconds": segmentSeconds,
      "retentionSeconds": retentionSeconds,
      "safetyMarginSeconds": safetyMarginSeconds,
      "codec": model.codec,
      "width": model.width,
      "height": model.height,
      "fps": model.fps,
      "measuredFps": round(store.segments.last?.measuredFps ?? 0, places: 2),
      "framesWritten": model.framesWritten,
      "captureDroppedFrames": model.captureDroppedFrames,
      "droppedLateFrames": model.droppedLate,
      "droppedOutOfBuffersFrames": model.droppedOutOfBuffers,
      "writerDroppedFrames": model.writerDroppedFrames,
      "missingFrames": model.missingFrames,
      "outOfOrderFrames": model.outOfOrderFrames,
      "gaps": model.gaps,
      "segmentGaps": store.unexpectedGaps,
      "segmentOverlaps": store.overlaps,
      "orderingErrors": store.orderingErrors,
      "failedSegments": model.failedSegments,
      "expiredSegments": store.expiredCount,
      "orphansRemoved": model.orphansRemoved,
      "protectedSegments": store.protectedSegmentCount,
      "retiredSegments": store.retired.count,
    ]
    if let message = model.message {
      result["message"] = message
    }
    if let last = store.segments.last {
      result["lastSegment"] = last.dictionary()
    }
    return result
  }

  private func withModel<T>(_ body: (inout Model) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&model)
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  // MARK: - Helpers

  /// Creates a writer for one segment and starts it (the expensive part), ready for `startSession`.
  private static func makeWriter(index: Int, generation: Int, config: BufferConfiguration) throws -> PreparedWriter {
    if let free = availableBytes(), free < minFreeBytesWhileBuffering {
      throw RecordingError(
        code: "ERR_LOW_STORAGE",
        message: "The replay buffer stopped because storage is almost full (\(free / 1_048_576) MB free).")
    }
    let name = String(format: "%06d", index)
    let tempURL = directory.appendingPathComponent("writing_\(name).mov")
    let finalURL = directory.appendingPathComponent("segment_\(name).mov")
    try? FileManager.default.removeItem(at: tempURL)

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
    } catch {
      throw RecordingError(code: "ERR_BUFFER_WRITER", message: "Could not create a segment file: \(error.localizedDescription)")
    }
    guard let settings = config.videoSettingsCandidates.first(where: {
      writer.canApply(outputSettings: $0, forMediaType: .video)
    }) else {
      throw RecordingError(code: "ERR_BUFFER_WRITER", message: "No supported video encoder settings were found.")
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    input.transform = config.transform
    guard writer.canAdd(input) else {
      throw RecordingError(code: "ERR_BUFFER_WRITER", message: "The video encoder could not be attached to the segment file.")
    }
    writer.add(input)
    guard writer.startWriting() else {
      let reason = writer.error?.localizedDescription ?? "unknown error"
      try? FileManager.default.removeItem(at: tempURL)
      throw RecordingError(code: "ERR_BUFFER_WRITER", message: "Could not start the video encoder: \(reason)")
    }
    return PreparedWriter(
      writer: writer, input: input, index: index, generation: generation, tempURL: tempURL, finalURL: finalURL)
  }

  private static func discard(_ prepared: PreparedWriter) {
    if prepared.writer.status == .writing {
      prepared.writer.cancelWriting()
    }
    try? FileManager.default.removeItem(at: prepared.tempURL)
  }

  private static func deleteFiles(_ names: [String]) {
    for name in names {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// Deletes everything in the buffer folder except `keep`. Only call while nothing is being written.
  private static func removeFiles(notIn keep: Set<String>) {
    let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for url in urls where !keep.contains(url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Converts a capture timestamp to wall-clock time.
  private static func wallClock(for time: CMTime, clock: CMClock) -> Date {
    let now = CMClockGetTime(clock)
    let offset = (time - now).seconds
    return Date(timeIntervalSinceNow: offset.isFinite ? offset : 0)
  }

  private static func frameDuration(fps: Double) -> CMTime {
    let rate = fps.isFinite && fps >= 1 ? fps : 30
    return CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
  }

  private static func recordingError(_ error: Error) -> RecordingError {
    (error as? RecordingError) ?? RecordingError(code: "ERR_BUFFER_WRITER", message: error.localizedDescription)
  }

  private static func availableBytes() -> Int64? {
    let values = try? FileManager.default.temporaryDirectory
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  /// The app's physical memory footprint (what iOS uses for memory limits), or nil if unavailable.
  private static func memoryFootprintBytes() -> Int64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
  }

  static func round(_ value: Double, places: Int) -> Double {
    let factor = pow(10, Double(places))
    return (value * factor).rounded() / factor
  }
}
