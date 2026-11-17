import AVFoundation
import ExpoModulesCore

public final class TripodCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("TripodCamera")

    /// "granted" | "denied" | "undetermined"
    AsyncFunction("getPermissionStatusAsync") { () -> String in
      return Self.permissionStatus()
    }

    /// Shows the system prompt the first time; afterwards iOS returns the stored answer
    /// without prompting (the user must change it in Settings).
    AsyncFunction("requestPermissionAsync") { (promise: Promise) in
      AVCaptureDevice.requestAccess(for: .video) { _ in
        promise.resolve(Self.permissionStatus())
      }
    }

    View(TripodCameraView.self) {
      Events("onCameraStateChange")

      Prop("active", true) { (view: TripodCameraView, active: Bool) in
        view.setActive(active)
      }
    }
  }

  private static func permissionStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return "granted"
    case .notDetermined:
      return "undetermined"
    case .denied, .restricted:
      return "denied"
    @unknown default:
      return "denied"
    }
  }
}
