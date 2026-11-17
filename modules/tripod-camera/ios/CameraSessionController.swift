import AVFoundation

/// States reported to JavaScript through the view's `onCameraStateChange` event.
enum CameraState: String {
  case starting
  case running
  case interrupted
  case stopped
  case error
}

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
 Owns one AVCaptureSession and does all of its work on a private serial queue.

 `startRunning()` blocks until the camera is up, so it must never run on the main thread.
 Every piece of mutable state below is touched only on `queue`, which is what makes the
 `@unchecked Sendable` conformance safe.

 This is the place where recording (AVCaptureVideoDataOutput + AVAssetWriter) will be
 added in a later task; for now it only feeds the preview layer.
 */
final class CameraSessionController: @unchecked Sendable {
  /// Shared with the preview layer. AVCaptureVideoPreviewLayer is safe to attach from the main thread.
  let session = AVCaptureSession()

  /// Called on the session queue. Must be set once, before the first `start()`.
  var onStateChange: ((CameraState, String?) -> Void)?

  private let queue = DispatchQueue(label: "com.zenxol.tripod.camera.session")
  private var isConfigured = false
  private var wantsRunning = false
  private var observers: [NSObjectProtocol] = []

  init() {
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
      self.queue.async { self.emit(.interrupted, message) }
    })

    observers.append(center.addObserver(
      forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard self.wantsRunning, self.session.isRunning else { return }
        self.emit(.running, nil)
      }
    })
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  /// Starts the preview. Safe to call repeatedly; does nothing if already running.
  func start() {
    queue.async { [self] in
      wantsRunning = true
      startIfNeeded()
    }
  }

  /// Stops the camera. Safe to call repeatedly, and from `deinit` of the owning view
  /// (the closure keeps this controller alive until the session has stopped).
  func stop() {
    queue.async { [self] in
      wantsRunning = false
      guard session.isRunning else { return }
      session.stopRunning()
      emit(.stopped, nil)
    }
  }

  // MARK: - Session queue only

  private func startIfNeeded() {
    guard wantsRunning, !session.isRunning else { return }

    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      emit(.error, CameraSetupError.notAuthorized.localizedDescription)
      return
    }

    if !isConfigured {
      do {
        try configureSession()
        isConfigured = true
      } catch {
        emit(.error, error.localizedDescription)
        return
      }
    }

    emit(.starting, nil)
    session.startRunning() // blocking; this is why we are on `queue`
    if session.isRunning {
      emit(.running, nil)
    } else {
      // A runtimeErrorNotification with the specific reason usually follows.
      emit(.error, "The camera could not be started.")
    }
  }

  private func configureSession() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    if session.canSetSessionPreset(.high) {
      session.sessionPreset = .high
    }

    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
      throw CameraSetupError.noRearCamera
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw CameraSetupError.cannotAddInput
    }
    session.addInput(input)
  }

  private func handleRuntimeError(_ error: AVError?) {
    emit(.error, error?.localizedDescription ?? "The camera stopped because of an unknown error.")
    // After a media services reset the session must be restarted; other errors are left
    // to the user (leave and reopen the camera) to avoid a restart loop.
    if error?.code == .mediaServicesWereReset {
      startIfNeeded()
    }
  }

  private func emit(_ state: CameraState, _ message: String?) {
    onStateChange?(state, message)
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
