import AVFoundation
import ExpoModulesCore
import UIKit

/**
 Live rear-camera preview shown inside React Native.

 Frames go straight from the shared AVCaptureSession to AVCaptureVideoPreviewLayer on the
 GPU; nothing crosses the JavaScript bridge. The view attaches to the session only while it
 is both `active` (prop from JS) and in a window, so unmounting it in JS releases the camera
 (any recording in progress is finished and saved first, by the controller).
 */
final class TripodCameraView: ExpoView {
  let onCameraStateChange = EventDispatcher()

  private let camera = CameraSessionController.shared
  private let clientID = UUID()
  private let previewLayer = AVCaptureVideoPreviewLayer()
  private var isActive = true
  private var isAttached = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black

    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.session = camera.session
    layer.addSublayer(previewLayer)
  }

  deinit {
    camera.detach(clientID)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Resize without the implicit Core Animation fade.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    previewLayer.frame = bounds
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAttachment()
  }

  func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    updateAttachment()
  }

  private func updateAttachment() {
    let shouldAttach = isActive && window != nil
    guard shouldAttach != isAttached else { return }
    isAttached = shouldAttach

    // Keep the phone from auto-locking while the camera is on screen; auto-lock would
    // interrupt the session and end a recording.
    UIApplication.shared.isIdleTimerDisabled = shouldAttach

    if shouldAttach {
      camera.attach(clientID) { [weak self] payload in
        DispatchQueue.main.async { [weak self] in
          self?.handleCameraEvent(payload)
        }
      }
    } else {
      camera.detach(clientID)
    }
  }

  /// `payload` is `{ state, message?, settings? }` from CameraSessionController.
  private func handleCameraEvent(_ payload: [String: Any]) {
    if payload["state"] as? String == CameraState.running.rawValue, let connection = previewLayer.connection {
      // Same rotation as the recording connection, so preview and file always match.
      CaptureConfiguration.applyRotation(to: connection)
    }
    onCameraStateChange(payload)
  }
}
