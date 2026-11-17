import AVFoundation
import ExpoModulesCore

public final class TripodCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("TripodCamera")

    /// Sent every time a recording ends: Stop Recording, camera closed, interruption,
    /// low storage or failure. Payload has `ok: true` + metadata, or `ok: false` + code/message.
    Events("onRecordingFinished")

    OnCreate {
      CameraSessionController.shared.setRecordingFinishedHandler { [weak self] event in
        self?.sendEvent("onRecordingFinished", event.mapValues { $0 as Any? })
      }
    }

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

    /// Resolves with { fileName, startedAt } once the file is being written.
    AsyncFunction("startRecording") { (promise: Promise) in
      CameraSessionController.shared.startRecording { result in
        Self.settle(promise, result)
      }
    }

    /// Resolves with the saved recording's metadata (uri, fileName, durationSeconds, ...).
    AsyncFunction("stopRecording") { (promise: Promise) in
      CameraSessionController.shared.stopRecording { result in
        Self.settle(promise, result)
      }
    }

    View(TripodCameraView.self) {
      Events("onCameraStateChange")

      Prop("active", true) { (view: TripodCameraView, active: Bool) in
        view.setActive(active)
      }
    }
  }

  private static func settle(_ promise: Promise, _ result: Result<[String: Any], RecordingError>) {
    switch result {
    case .success(let value):
      promise.resolve(value)
    case .failure(let error):
      promise.reject(error.code, error.message)
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
