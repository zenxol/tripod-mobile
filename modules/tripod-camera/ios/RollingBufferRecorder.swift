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

/// A finished, playable segment file in the rolling buffer.
struct BufferSegment {
  let index: Int
  let url: URL
  /// Capture-clock timestamps (seconds) of the first frame and of the segment's end.
  let startTime: CMTime
  let endTime: CMTime
  let startedAt: Date
  let endedAt: Date
  let frameCount: Int
  let sizeBytes: Int64
  /// True when capture stopped (interruption, gap) before this segment, so it does not continue the previous one.
  let followsGap: Bool

  var duration: Double { (endTime - startTime).seconds }

  func dictionary() -> [String: Any] {
    [
      "index": index,
      "fileName": url.lastPathComponent,
      "uri": url.absoluteString,
      "startTime": startTime.seconds,
      "endTime": endTime.seconds,
      "durationSeconds": RollingBufferRecorder.round(duration, places: 3),
      "startedAt": RollingBufferRecorder.isoFormatter.string(from: startedAt),
      "endedAt": RollingBufferRecorder.isoFormatter.string(from: endedAt),
      "frameCount": frameCount,
      "fps": RollingBufferRecorder.round(duration > 0 ? Double(frameCount) / duration : 0, places: 2),
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
 encoder holds for a moment.

 Rotation without gaps: the segment closes at the first frame whose timestamp is at least
 `segmentSeconds` after the segment's first frame. That frame becomes the first frame of the
 next segment, and the old segment ends exactly at its timestamp, so the timeline continues
 with no lost frames. The next writer is created and started on `prepQueue` in advance, so
 switching costs almost nothing on the capture queue.

 Files: `tmp/rolling-buffer/writing_NNNNNN.mov` while open, renamed to `segment_NNNNNN.mov`
 only after `finishWriting` succeeds. Segments beyond `retentionSeconds + safetyMarginSeconds`
 of footage are deleted, oldest first. The folder is emptied on every start and on launch.

 Threads: `videoQueue` owns the writers and frame state; `storeQueue` renames, measures and
 deletes files; `prepQueue` builds writers. The status model is shared under `lock`.
 */
final class RollingBufferRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  static let segmentSeconds: Double = 5
  static let retentionSeconds: Double = 120
  static let safetyMarginSeconds: Double = 10
  /// Stop buffering (with an error) rather than fill the phone.
  static let minFreeBytesWhileBuffering: Int64 = 300 * 1024 * 1024
  /// A jump in frame timestamps longer than this is treated as a capture gap, not dropped frames.
  static let gapThresholdSeconds: Double = 0.5

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
  private let pendingFinishes = DispatchGroup()

  // videoQueue only.
  private var config: BufferConfiguration?
  private var isAccepting = false
  private var generation = 0
  private var nextIndex = 1
  private var current: OpenSegment?
  private var prepared: PreparedWriter?
  private var isPreparing = false
  private var lastPTS: CMTime?
  private var nominalFrameDuration = CMTime(value: 1, timescale: 60)
  private var nextSegmentFollowsGap = false

  // Shared; guarded by `lock`.
  private let lock = NSLock()
  private var model = Model()
  private var statusHandler: (([String: Any]) -> Void)?
  private var failureHandler: ((RecordingError) -> Void)?

  private struct Model {
    var generation = 0
    var state: BufferState = .idle
    var message: String?
    var segments: [BufferSegment] = []
    var storageBytes: Int64 = 0
    var framesWritten = 0
    var captureDroppedFrames = 0
    var writerDroppedFrames = 0
    var missingFrames = 0
    var gaps = 0
    var discontinuities = 0
    var failedSegments = 0
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

    init(writer: PreparedWriter, startTime: CMTime, startedAt: Date, followsGap: Bool) {
      self.writer = writer
      self.startTime = startTime
      self.startedAt = startedAt
      self.followsGap = followsGap
      self.lastTime = startTime
    }
  }

  // MARK: - Public API (any thread)

  /// Receives the status dictionary on every state change and finished segment.
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
    withModel { $0.segments }.map { $0.dictionary() }
  }

  /// Clears the previous buffer and starts accepting frames. Completes on `videoQueue`.
  func start(_ config: BufferConfiguration, completion: @escaping (Result<[String: Any], RecordingError>) -> Void) {
    videoQueue.async { [self] in
      guard !isAccepting else {
        return completion(.failure(RecordingError(
          code: "ERR_BUFFER_ACTIVE", message: "The rolling buffer is already running.")))
      }
      generation += 1
      let runGeneration = generation
      withModel {
        $0 = Model()
        $0.generation = runGeneration
        $0.state = .starting
        $0.codec = config.codec
        $0.width = config.displayWidth
        $0.height = config.displayHeight
        $0.fps = config.fps
      }

      let keepSeconds = Self.retentionSeconds + Self.safetyMarginSeconds + Self.segmentSeconds
      let neededBytes = Int64(config.estimatedBytesPerSecond * keepSeconds) + Self.minFreeBytesWhileBuffering
      if let free = Self.availableBytes(), free < neededBytes {
        return failStart(RecordingError(
          code: "ERR_LOW_STORAGE",
          message: "Not enough free storage for the replay buffer (\(free / 1_048_576) MB free, about \(neededBytes / 1_048_576) MB needed)."),
          completion)
      }

      do {
        try Self.resetDirectory()
      } catch {
        return failStart(RecordingError(
          code: "ERR_FILE", message: "Could not prepare the buffer folder: \(error.localizedDescription)"), completion)
      }

      self.config = config
      nominalFrameDuration = Self.frameDuration(fps: config.fps)
      nextIndex = 1
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
      Self.log.info("Buffer started: \(config.codec, privacy: .public) \(config.displayWidth)x\(config.displayHeight) @ \(config.fps) fps, \(Self.segmentSeconds) s segments")
      emitStatus()
      completion(.success(currentStatus()))
    }
  }

  /// Finishes the open segment, waits for every pending file, then completes with the final status.
  /// Finished segments stay on disk until the next start (or app launch). Safe to call repeatedly.
  func stop(_ completion: @escaping ([String: Any]) -> Void) {
    videoQueue.async { [self] in
      if isAccepting {
        setState(.stopping, nil)
        stopAccepting(keepAlive: true)
      }
      pendingFinishes.notify(queue: storeQueue) { [self] in
        withModel {
          if $0.state != .error {
            $0.state = .idle
            $0.message = nil
          }
        }
        Self.log.info("Buffer stopped")
        emitStatus()
        completion(currentStatus())
      }
    }
  }

  /// Capture is interrupted: finish the open segment so it is kept. Buffering resumes by itself
  /// with a new segment when frames arrive again.
  func pause(_ reason: String) {
    videoQueue.async { [self] in
      guard isAccepting else { return }
      if let segment = current {
        finish(segment, endTime: segment.lastTime + nominalFrameDuration, keepAlive: true)
        current = nil
      }
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
      guard pts > last else { return }
      let delta = (pts - last).seconds
      if delta > Self.gapThresholdSeconds {
        // Capture stopped and resumed without an interruption notice: close the segment at
        // its last frame and start a new one, instead of stretching one frame across the gap.
        if let segment = current {
          finish(segment, endTime: segment.lastTime + nominalFrameDuration, keepAlive: false)
          current = nil
        }
        nextSegmentFollowsGap = true
        withModel { $0.gaps += 1 }
        Self.log.notice("Buffer: \(delta) s gap in frame timestamps")
      } else {
        let nominal = nominalFrameDuration.seconds
        if nominal > 0, delta > nominal * 1.5 {
          let missing = max(Int((delta / nominal).rounded()) - 1, 1)
          withModel { $0.missingFrames += missing }
        }
      }
    }
    lastPTS = pts

    // Rotate on actual timestamps: this frame starts the next segment, and the old one ends
    // exactly where it begins.
    if let segment = current, (pts - segment.startTime).seconds >= Self.segmentSeconds {
      finish(segment, endTime: pts, keepAlive: false)
      current = nil
    }
    if current == nil {
      guard openSegment(at: pts) else { return }
    }
    guard let segment = current else { return }

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
      let reason = segment.writer.writer.error?.localizedDescription ?? "unknown error"
      fail(RecordingError(code: "ERR_BUFFER_WRITE", message: "Writing a buffer segment failed: \(reason)"))
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard isAccepting else { return }
    withModel { $0.captureDroppedFrames += 1 }
  }

  // MARK: - Segments (videoQueue)

  private func openSegment(at pts: CMTime) -> Bool {
    guard let config else { return false }
    var writer = prepared
    prepared = nil
    if writer == nil {
      Self.log.notice("Buffer: next writer was not ready; creating it on the capture queue")
      do {
        writer = try Self.makeWriter(index: nextIndex, generation: generation, config: config)
        nextIndex += 1
      } catch {
        fail(Self.recordingError(error))
        return false
      }
    }
    guard let writer else { return false }

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
    guard segment.frameCount > 0, let config else {
      Self.discard(prepared)
      return
    }
    prepared.writer.endSession(atSourceTime: endTime)
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
      followsGap: segment.followsGap)

    pendingFinishes.enter()
    let finished = DispatchSemaphore(value: 0)
    if keepAlive {
      ProcessInfo.processInfo.performExpiringActivity(withReason: "Finishing a replay buffer segment") { expired in
        if !expired {
          _ = finished.wait(timeout: .now() + 10)
        }
      }
    }
    let writer = prepared.writer
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
    pendingFinishes.notify(queue: storeQueue) {
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
      url: record.finalURL,
      startTime: record.startTime,
      endTime: record.endTime,
      startedAt: record.startedAt,
      endedAt: record.endedAt,
      frameCount: record.frameCount,
      sizeBytes: size,
      followsGap: record.followsGap)

    let keepSeconds = Self.retentionSeconds + Self.safetyMarginSeconds
    let (expired, discontinuous) = withModel { (model: inout Model) -> ([BufferSegment], Bool) in
      let position = model.segments.firstIndex(where: { $0.index > segment.index }) ?? model.segments.endIndex
      // Continuity check on real timestamps: a segment that does not follow a known gap must
      // start exactly where the previous one ended.
      var isDiscontinuous = false
      if position > 0, !segment.followsGap {
        let previous = model.segments[position - 1]
        if previous.index == segment.index - 1, abs((segment.startTime - previous.endTime).seconds) > 0.001 {
          isDiscontinuous = true
          model.discontinuities += 1
        }
      }
      model.segments.insert(segment, at: position)
      model.storageBytes += segment.sizeBytes

      // Keep about the newest `keepSeconds` of footage: drop the oldest segment while the
      // rest still covers it.
      var total = model.segments.reduce(0.0) { $0 + $1.duration }
      var removed: [BufferSegment] = []
      while model.segments.count > 1, total - model.segments[0].duration >= keepSeconds {
        let oldest = model.segments.removeFirst()
        total -= oldest.duration
        model.storageBytes -= oldest.sizeBytes
        removed.append(oldest)
      }
      return (removed, isDiscontinuous)
    }
    for old in expired {
      try? fileManager.removeItem(at: old.url)
    }

    let fps = segment.duration > 0 ? Double(segment.frameCount) / segment.duration : 0
    Self.log.debug("Segment \(segment.index): \(segment.duration) s, \(segment.frameCount) frames (\(fps) fps), \(segment.sizeBytes) bytes; deleted \(expired.count) old")
    if discontinuous {
      Self.log.error("Segment \(segment.index) does not start where the previous segment ended")
    }
    emitStatus()
  }

  // MARK: - Status

  private func setState(_ state: BufferState, _ message: String?) {
    withModel {
      $0.state = state
      $0.message = message
    }
    emitStatus()
  }

  private func emitStatus() {
    let (handler, model) = withLock { (statusHandler, self.model) }
    handler?(Self.statusDictionary(model))
  }

  private static func statusDictionary(_ model: Model) -> [String: Any] {
    var result: [String: Any] = [
      "state": model.state.rawValue,
      "segmentCount": model.segments.count,
      "bufferedSeconds": round(model.segments.reduce(0.0) { $0 + $1.duration }, places: 2),
      "storageBytes": Double(model.storageBytes),
      "segmentSeconds": segmentSeconds,
      "retentionSeconds": retentionSeconds,
      "safetyMarginSeconds": safetyMarginSeconds,
      "codec": model.codec,
      "width": model.width,
      "height": model.height,
      "fps": model.fps,
      "framesWritten": model.framesWritten,
      "captureDroppedFrames": model.captureDroppedFrames,
      "writerDroppedFrames": model.writerDroppedFrames,
      "missingFrames": model.missingFrames,
      "gaps": model.gaps,
      "discontinuities": model.discontinuities,
      "failedSegments": model.failedSegments,
    ]
    if let message = model.message {
      result["message"] = message
    }
    if let last = model.segments.last {
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

  private static func resetDirectory() throws {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: directory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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

  static func round(_ value: Double, places: Int) -> Double {
    let factor = pow(10, Double(places))
    return (value * factor).rounded() / factor
  }
}
