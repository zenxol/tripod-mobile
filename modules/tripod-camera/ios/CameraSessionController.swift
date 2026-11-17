import AVFoundation
import Foundation
import os

/// States reported to JavaScript through the view's `onCameraStateChange` event.
enum CameraState: String {
  case starting
  case running
  case interrupted
  case error
}

/// A failure reported to JavaScript as a promise rejection (`code`, `message`).
struct RecordingError: Error {
  let code: String
  let message: String
}

typealias RecordingCompletion = (Result<[String: Any], RecordingError>) -> Void

private enum CameraSetupError: LocalizedError {
  case notAuthorized
  case noRearCamera
  case cannotAddInput

  var errorDescription: String? {
    switch self {
    case .notAuthorized: return "Camera access has not been granted."
    case .noRearCamera: return "No rear camera was found on this device."
    case .cannotAddInput: return "The rear camera could not be connected to the capture session."
    }
  }
}

/**
 The app's single camera: one AVCaptureSession with a preview and an
 AVCaptureMovieFileOutput for ordinary start/stop recording.

 Quality: the camera format, frame rate and codec come from `CaptureConfiguration`
 (1080p60 when supported, with fallbacks; HEVC, else H.264). The format is set on the
 device itself, so the preview and the recording always use the same capture settings.
 The frame rate is locked, and lowered to 30 fps while the phone is under serious thermal
 pressure.

 Threading: every piece of mutable state is touched only on `queue` (AVCaptureSession's
 `startRunning()` blocks, so it must never run on the main thread). That is what makes the
 `@unchecked Sendable` conformance safe. Callbacks leave this class on `queue` or on a
 background thread; callers hop to the main thread themselves.

 Lifetime: preview views `attach` while on screen and `detach` when removed. The session
 runs while at least one view is attached. If the last view detaches during a recording,
 the recording is finished and saved first, then the session stops.

 Files: a recording is written to `tmp/recording-in-progress/`, checked when it finishes
 (readable, has video, duration > 0), then moved to `Documents/Recordings/`. Leftovers in
 the in-progress folder (for example after a crash) are deleted on launch.

 NOTE: AVCaptureMovieFileOutput is a milestone only. The rolling buffer (Task 4) needs
 AVCaptureVideoDataOutput + AVAssetWriter segments and will replace it.
 */
final class CameraSessionController: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
  static let shared = CameraSessionController()

  /// Shared with the preview layers. Attaching a preview layer from the main thread is safe.
  let session = AVCaptureSession()

  /// Visible in Console.app (subsystem com.zenxol.tripod, category camera).
  private static let log = Logger(subsystem: "com.zenxol.tripod", category: "camera")

  /// Refuse to start a recording below this much free space.
  private static let minFreeBytesToStart: Int64 = 500 * 1024 * 1024
  /// AVFoundation ends a recording (keeping the file) when free space drops below this.
  private static let minFreeBytesWhileRecording: Int64 = 200 * 1024 * 1024

  private let queue = DispatchQueue(label: "com.zenxol.tripod.camera.session")
  private let movieOutput = AVCaptureMovieFileOutput()
  private var isConfigured = false
  private var isMovieOutputReady = false
  private var clients: [UUID: ([String: Any]) -> Void] = [:]
  private var observers: [NSObjectProtocol] = []
  private var active: ActiveRecording?
  private var recordingFinishedHandler: (([String: Any]) -> Void)?

  // Capture settings (session queue only).
  private var videoDevice: AVCaptureDevice?
  private var formatSelection: FormatSelection?
  private var codecName = "default"
  private var setupNote: String?
  private var isThermallyThrottled = false
  private var pressureObservation: NSKeyValueObservation?

  private struct ActiveRecording {
    let fileName: String
    let tempURL: URL
    let finalURL: URL
    var startedAt = Date()
    var didStart = false
    var stopRequested = false
    /// "user" (Stop Recording), "cameraClosed" (preview removed) or nil = ended by the system.
    var endReason: String?
    var startCompletion: RecordingCompletion?
    var stopCompletions: [RecordingCompletion] = []
  }

  private override init() {
    super.init()
    let center = NotificationCenter.default

    observers.append(center.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
    ) { [weak self] note in
      guard let self else { return }
      let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
      self.queue.async { self.handleRuntimeError(error) }
    })

    observers.append(center.addObserver(
      forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
    ) { [weak self] note in
      guard let self else { return }
      let rawReason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
      let reason = rawReason.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
      let message = CameraSessionController.describe(reason)
      self.queue.async {
        Self.log.notice("Camera interrupted: \(message, privacy: .public)")
        self.emit(.interrupted, message)
      }
    })

    observers.append(center.addObserver(
      forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard !self.clients.isEmpty, self.session.isRunning else { return }
        Self.log.notice("Camera interruption ended")
        self.enforceCaptureSettings()
        self.emit(.running, nil)
      }
    })

    queue.async {
      try? FileManager.default.removeItem(at: Self.inProgressDirectory)
    }
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - Preview clients

  /// Registers a preview view and starts the session if needed. `onEvent` receives
  /// `{ state, message?, settings? }` payloads on the session queue.
  func attach(_ id: UUID, onEvent: @escaping ([String: Any]) -> Void) {
    queue.async { [self] in
      clients[id] = onEvent
      if session.isRunning {
        // Already running for another client: tell the new one the current state.
        if session.isInterrupted {
          onEvent(payload(.interrupted, "The camera is paused."))
        } else {
          onEvent(payload(.running, nil))
        }
      } else {
        startIfNeeded()
      }
    }
  }

  /// Unregisters a preview view. The session stops when no views remain (after saving any recording).
  func detach(_ id: UUID) {
    queue.async { [self] in
      clients[id] = nil
      stopIfUnused()
    }
  }

  // MARK: - Recording API

  /// Receives a payload every time a recording ends, for any reason. Called on the session queue.
  func setRecordingFinishedHandler(_ handler: (([String: Any]) -> Void)?) {
    queue.async { [self] in
      recordingFinishedHandler = handler
    }
  }

  /// Completes once AVFoundation has actually started writing the file.
  func startRecording(_ completion: @escaping RecordingCompletion) {
    queue.async { [self] in
      guard active == nil else {
        return completion(.failure(RecordingError(
          code: "ERR_ALREADY_RECORDING", message: "A recording is already in progress.")))
      }
      guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        return completion(.failure(RecordingError(
          code: "ERR_PERMISSION_DENIED", message: CameraSetupError.notAuthorized.localizedDescription)))
      }
      guard isMovieOutputReady else {
        return completion(.failure(RecordingError(
          code: "ERR_RECORDING_UNAVAILABLE", message: "Recording is not available on this camera.")))
      }
      guard session.isRunning, !session.isInterrupted else {
        return completion(.failure(RecordingError(
          code: "ERR_CAMERA_NOT_RUNNING", message: "The camera is not running.")))
      }
      if let free = Self.availableBytes(), free < Self.minFreeBytesToStart {
        return completion(.failure(RecordingError(
          code: "ERR_LOW_STORAGE",
          message: "Not enough free storage to record (\(free / 1_048_576) MB free, 500 MB needed).")))
      }

      let fileName = Self.makeFileName()
      let tempURL = Self.inProgressDirectory.appendingPathComponent(fileName)
      let finalURL = Self.recordingsDirectory.appendingPathComponent(fileName)
      do {
        try FileManager.default.createDirectory(at: Self.inProgressDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
      } catch {
        return completion(.failure(RecordingError(
          code: "ERR_FILE", message: "Could not create the recordings folder: \(error.localizedDescription)")))
      }

      let settingsSummary = makeSettings()?.summary ?? "unknown settings"
      Self.log.info("Recording \(fileName, privacy: .public) with \(settingsSummary, privacy: .public)")
      active = ActiveRecording(
        fileName: fileName, tempURL: tempURL, finalURL: finalURL, startCompletion: completion)
      movieOutput.startRecording(to: tempURL, recordingDelegate: self)
    }
  }

  /// Completes with the saved recording's metadata once the file is finished and checked.
  func stopRecording(_ completion: @escaping RecordingCompletion) {
    queue.async { [self] in
      guard var recording = active else {
        return completion(.failure(RecordingError(
          code: "ERR_NOT_RECORDING", message: "No recording is in progress.")))
      }
      // Repeated presses join the same pending stop.
      recording.stopCompletions.append(completion)
      if !recording.stopRequested {
        recording.stopRequested = true
        recording.endReason = "user"
        movieOutput.stopRecording()
      }
      active = recording
    }
  }

  // MARK: - AVCaptureFileOutputRecordingDelegate (called on an AVFoundation thread)

  func fileOutput(
    _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
  ) {
    queue.async { [self] in
      guard var recording = active, recording.tempURL == fileURL else { return }
      recording.didStart = true
      recording.startedAt = Date()
      let completion = recording.startCompletion
      recording.startCompletion = nil
      active = recording
      completion?(.success([
        "fileName": recording.fileName,
        "startedAt": Self.isoString(recording.startedAt),
      ]))
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    // An error does not always mean the file is bad: interruptions, low disk space and
    // the session stopping all end the recording but keep a valid file.
    var fileIsUsable = error == nil
    var note: String?
    if let nsError = error as NSError? {
      if (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true {
        fileIsUsable = true
        note = nsError.localizedDescription
      }
    }
    let errorMessage = error?.localizedDescription
    queue.async { [self] in
      finishRecording(at: outputFileURL, fileIsUsable: fileIsUsable, note: note, errorMessage: errorMessage)
    }
  }

  // MARK: - Session queue only

  private func startIfNeeded() {
    guard !clients.isEmpty, !session.isRunning else { return }

    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      emit(.error, CameraSetupError.notAuthorized.localizedDescription)
      return
    }

    if !isConfigured {
      do {
        try configureSession()
        isConfigured = true
      } catch {
        Self.log.error("Camera setup failed: \(error.localizedDescription, privacy: .public)")
        emit(.error, error.localizedDescription)
        return
      }
    }

    emit(.starting, nil)
    session.startRunning() // blocking; this is why we are on `queue`
    if session.isRunning {
      enforceCaptureSettings()
      Self.log.info("Camera running: \(self.makeSettings()?.summary ?? "unknown", privacy: .public)")
      emit(.running, nil)
    } else {
      // A runtimeErrorNotification with the specific reason usually follows.
      emit(.error, "The camera could not be started.")
    }
  }

  private func stopIfUnused() {
    guard clients.isEmpty else { return }
    if var recording = active {
      // Finish and save the file first; finishRecording() calls back here to stop the session.
      if !recording.stopRequested {
        recording.stopRequested = true
        recording.endReason = "cameraClosed"
        active = recording
        movieOutput.stopRecording()
      }
      return
    }
    if session.isRunning {
      session.stopRunning()
      Self.log.info("Camera stopped")
    }
  }

  private func configureSession() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    guard let device = AVCaptureDevice.default(
      CaptureConfiguration.deviceType, for: .video, position: CaptureConfiguration.devicePosition)
    else {
      throw CameraSetupError.noRearCamera
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw CameraSetupError.cannotAddInput
    }
    session.addInput(input)
    videoDevice = device

    // Recording is optional: if the output can't be added, the preview still works and
    // startRecording() reports ERR_RECORDING_UNAVAILABLE.
    if session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
      movieOutput.minFreeDiskSpaceLimit = Self.minFreeBytesWhileRecording
      isMovieOutputReady = true
    } else {
      Self.log.error("Movie file output could not be added; recording disabled")
    }

    // The format is set after the input is added (adding an input resets frame durations).
    // Setting activeFormat switches the session preset to .inputPriority, so the preview
    // and the recording both use exactly this format.
    if let selection = CaptureConfiguration.selectFormat(for: device) {
      do {
        try device.lockForConfiguration()
        device.activeFormat = selection.format
        Self.setFrameDuration(selection.target.fps, on: device)
        device.unlockForConfiguration()
        formatSelection = selection
        setupNote = selection.fallbackNote
      } catch {
        setupNote = "Could not select \(selection.target.label) (\(error.localizedDescription)); using the default camera format."
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
      }
    } else {
      setupNote = "No supported 1080p or 720p format; using the default camera format."
      if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
    }

    // Codec and connection settings depend on the active format, so they come last.
    if isMovieOutputReady, let connection = movieOutput.connection(with: .video) {
      let codec = CaptureConfiguration.preferredCodec(from: movieOutput.availableVideoCodecTypes)
      if let codec {
        movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
      }
      codecName = CaptureConfiguration.codecName(codec)
      // Stabilization crops and delays the recording relative to the preview; on a tripod it
      // adds nothing, and turning it off keeps the recorded framing identical to the preview.
      if connection.isVideoStabilizationSupported {
        connection.preferredVideoStabilizationMode = .off
      }
      CaptureConfiguration.applyRotation(to: connection)
    }

    pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
      let level = device.systemPressureState.level
      self?.queue.async { self?.handleSystemPressure(level) }
    }

    if let note = setupNote {
      Self.log.notice("Capture fallback: \(note, privacy: .public)")
    }
  }

  /// Re-applies the selected format and frame rate if anything reset them (session start,
  /// interruption end, media services reset). Cheap when nothing changed.
  private func enforceCaptureSettings() {
    guard let device = videoDevice, let selection = formatSelection else { return }
    let wantedFps = isThermallyThrottled
      ? min(CaptureConfiguration.reducedFps, selection.target.fps)
      : selection.target.fps
    let formatChanged = device.activeFormat != selection.format
    let fpsChanged = abs(Self.currentFps(device) - wantedFps) > 0.5
    guard formatChanged || fpsChanged else { return }

    Self.log.notice("Re-applying capture settings (format changed: \(formatChanged), fps changed: \(fpsChanged))")
    do {
      try device.lockForConfiguration()
      if formatChanged {
        device.activeFormat = selection.format
      }
      Self.setFrameDuration(wantedFps, on: device)
      device.unlockForConfiguration()
    } catch {
      Self.log.error("Could not re-apply capture settings: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func handleSystemPressure(_ level: AVCaptureDevice.SystemPressureState.Level) {
    guard let device = videoDevice, let selection = formatSelection else { return }
    let shouldThrottle = level == .serious || level == .critical
    guard shouldThrottle != isThermallyThrottled else { return }

    let fps = shouldThrottle
      ? min(CaptureConfiguration.reducedFps, selection.target.fps)
      : selection.target.fps
    do {
      try device.lockForConfiguration()
      Self.setFrameDuration(fps, on: device)
      device.unlockForConfiguration()
    } catch {
      Self.log.error("Could not change frame rate for thermal pressure: \(error.localizedDescription, privacy: .public)")
      return
    }
    isThermallyThrottled = shouldThrottle
    Self.log.notice("System pressure \(level.rawValue, privacy: .public): frame rate now \(fps) fps")
    if session.isRunning && !session.isInterrupted {
      emit(.running, nil)
    }
  }

  private func finishRecording(at url: URL, fileIsUsable: Bool, note: String?, errorMessage: String?) {
    guard let recording = active, recording.tempURL == url else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    active = nil
    // The camera may have been closed while this file was finishing.
    defer { stopIfUnused() }

    let endedBy = recording.endReason ?? "system"
    guard fileIsUsable else {
      try? FileManager.default.removeItem(at: url)
      deliver(recording, endedBy: endedBy, result: .failure(RecordingError(
        code: "ERR_RECORDING_FAILED", message: errorMessage ?? "The recording failed.")))
      return
    }

    // Check the file before calling it saved, then move it into Documents.
    Task {
      let inspected = await Self.inspectRecording(at: url)
      self.queue.async {
        switch inspected {
        case .failure(let error):
          try? FileManager.default.removeItem(at: url)
          self.deliver(recording, endedBy: endedBy, result: .failure(error))
        case .success(var info):
          do {
            try FileManager.default.moveItem(at: url, to: recording.finalURL)
          } catch {
            try? FileManager.default.removeItem(at: url)
            self.deliver(recording, endedBy: endedBy, result: .failure(RecordingError(
              code: "ERR_SAVE_FAILED", message: "The recording could not be saved: \(error.localizedDescription)")))
            return
          }
          info["uri"] = recording.finalURL.absoluteString
          info["fileName"] = recording.fileName
          info["startedAt"] = Self.isoString(recording.startedAt)
          info["endedBy"] = endedBy
          if let note {
            info["note"] = note
          }
          self.deliver(recording, endedBy: endedBy, result: .success(info))
        }
      }
    }
  }

  private func deliver(_ recording: ActiveRecording, endedBy: String, result: Result<[String: Any], RecordingError>) {
    if let startCompletion = recording.startCompletion {
      // AVFoundation never confirmed the start.
      switch result {
      case .failure(let error): startCompletion(.failure(error))
      case .success: startCompletion(.failure(RecordingError(
        code: "ERR_RECORDING_FAILED", message: "The recording stopped before it started.")))
      }
    }
    recording.stopCompletions.forEach { $0(result) }

    var event: [String: Any]
    switch result {
    case .success(let info):
      event = info
      event["ok"] = true
      let summary = "\(info["width"] ?? "?")x\(info["height"] ?? "?") \(info["frameRate"] ?? "?") fps \(info["codec"] ?? "?"), \(info["durationSeconds"] ?? "?") s"
      Self.log.info("Saved \(recording.fileName, privacy: .public): \(summary, privacy: .public), ended by \(endedBy, privacy: .public)")
    case .failure(let error):
      event = ["ok": false, "code": error.code, "message": error.message, "endedBy": endedBy]
      Self.log.error("Recording \(recording.fileName, privacy: .public) failed: \(error.code, privacy: .public) \(error.message, privacy: .public)")
    }
    recordingFinishedHandler?(event)
  }

  private func handleRuntimeError(_ error: AVError?) {
    let message = error?.localizedDescription ?? "The camera stopped because of an unknown error."
    Self.log.error("Camera runtime error: \(message, privacy: .public)")
    emit(.error, message)
    // After a media services reset the session must be restarted (startIfNeeded re-applies
    // the capture settings); other errors are left to the user (leave and reopen the camera)
    // to avoid a restart loop.
    if error?.code == .mediaServicesWereReset {
      startIfNeeded()
    }
  }

  private func emit(_ state: CameraState, _ message: String?) {
    let event = payload(state, message)
    clients.values.forEach { $0(event) }
  }

  private func payload(_ state: CameraState, _ message: String?) -> [String: Any] {
    var result: [String: Any] = ["state": state.rawValue]
    if let message {
      result["message"] = message
    }
    if let settings = makeSettings() {
      result["settings"] = settings.dictionary()
    }
    return result
  }

  /// Reads what the device is actually doing right now.
  private func makeSettings() -> CaptureSettings? {
    guard let device = videoDevice else { return nil }
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let fps = Self.currentFps(device)
    let notes = [
      setupNote,
      isThermallyThrottled ? "Reduced to \(Int(CaptureConfiguration.reducedFps)) fps because the phone is hot." : nil,
    ].compactMap { $0 }
    return CaptureSettings(
      width: Int(dimensions.width),
      height: Int(dimensions.height),
      fps: fps,
      targetFps: formatSelection?.target.fps ?? fps,
      codec: codecName,
      note: notes.isEmpty ? nil : notes.joined(separator: " "))
  }

  // MARK: - Helpers

  static var recordingsDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Recordings", isDirectory: true)
  }

  private static var inProgressDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("recording-in-progress", isDirectory: true)
  }

  /// Locks the frame rate (min = max frame duration). Caller must hold the device lock.
  private static func setFrameDuration(_ fps: Double, on device: AVCaptureDevice) {
    guard CaptureConfiguration.supports(device.activeFormat, fps: fps) else { return }
    let duration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
    device.activeVideoMinFrameDuration = duration
    device.activeVideoMaxFrameDuration = duration
  }

  private static func currentFps(_ device: AVCaptureDevice) -> Double {
    let seconds = device.activeVideoMinFrameDuration.seconds
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return (1 / seconds * 100).rounded() / 100
  }

  /// recording_YYYYMMDD_HHMMSS_<6 hex>.mov: wall-clock time plus a random suffix, never overwrites.
  private static func makeFileName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let suffix = String(format: "%06x", Int.random(in: 0..<0x100_0000))
    return "recording_\(formatter.string(from: Date()))_\(suffix).mov"
  }

  private static func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func availableBytes() -> Int64? {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  /// Opens the finished file and reads its metadata. Fails if it is unreadable or has no video.
  private static func inspectRecording(at url: URL) async -> Result<[String: Any], RecordingError> {
    do {
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration)
      guard let track = try await asset.loadTracks(withMediaType: .video).first, duration.seconds > 0 else {
        return .failure(RecordingError(code: "ERR_VERIFY_FAILED", message: "The recorded file contains no video."))
      }
      let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
      let formatDescriptions = try await track.load(.formatDescriptions)
      let codec = formatDescriptions.first.map {
        CaptureConfiguration.codecName(fourCC: CMFormatDescriptionGetMediaSubType($0))
      } ?? "unknown"
      let displaySize = naturalSize.applying(transform)
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      let sizeBytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
      return .success([
        "durationSeconds": duration.seconds,
        "width": Int(abs(displaySize.width).rounded()),
        "height": Int(abs(displaySize.height).rounded()),
        "frameRate": (Double(frameRate) * 100).rounded() / 100,
        "codec": codec,
        "sizeBytes": sizeBytes,
      ])
    } catch {
      return .failure(RecordingError(
        code: "ERR_VERIFY_FAILED", message: "The recorded file could not be read: \(error.localizedDescription)"))
    }
  }

  private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
    guard let reason else { return "The camera was interrupted." }
    switch reason {
    case .videoDeviceNotAvailableInBackground:
      return "The camera is paused while the app is in the background."
    case .videoDeviceInUseByAnotherClient:
      return "The camera is being used by another app."
    case .videoDeviceNotAvailableWithMultipleForegroundApps:
      return "The camera is unavailable while multiple apps are on screen."
    case .videoDeviceNotAvailableDueToSystemPressure:
      return "The camera was paused because the phone is too hot."
    case .audioDeviceInUseByAnotherClient:
      return "The camera was interrupted by another app using audio."
    @unknown default:
      return "The camera was interrupted."
    }
  }
}
