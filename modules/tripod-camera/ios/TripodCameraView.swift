import AVFoundation
import ExpoModulesCore
import UIKit

/**
 Live rear-camera preview shown inside React Native.

 Frames go straight from AVCaptureSession to AVCaptureVideoPreviewLayer on the GPU;
 nothing crosses the JavaScript bridge. The session runs only while the view is
 both `active` (prop from JS) and attached to a window, so unmounting the view in JS
 always stops the camera.
 */
final class TripodCameraView: ExpoView {
  let onCameraStateChange = EventDispatcher()

  private let camera = CameraSessionController()
  private let previewLayer = AVCaptureVideoPreviewLayer()
  private var isActive = true

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black

    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.session = camera.session
    layer.addSublayer(previewLayer)

    camera.onStateChange = { [weak self] state, message in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if state == .running {
          self.lockPreviewToPortrait()
        }
        var payload: [String: Any] = ["state": state.rawValue]
        if let message {
          payload["message"] = message
        }
        self.onCameraStateChange(payload)
      }
    }
  }

  deinit {
    camera.stop()
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
    updateSessionState()
  }

  func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    updateSessionState()
  }

  private func updateSessionState() {
    if isActive && window != nil {
      camera.start()
    } else {
      camera.stop()
    }
  }

  /// The app is portrait-only, so the preview is always shown upright in portrait.
  private func lockPreviewToPortrait() {
    guard let connection = previewLayer.connection else { return }
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
  }
}
