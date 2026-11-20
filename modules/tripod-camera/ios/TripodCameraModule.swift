import AVFoundation
import ExpoModulesCore

public final class TripodCameraModule: Module {
  public func definition() -> ModuleDefinition {
    Name("TripodCamera")

    /// Sent every time a recording ends: Stop Recording, camera closed, interruption,
    /// low storage or failure. Payload has `ok: true` + metadata, or `ok: false` + code/message.
    /// `onBufferStatus`: replay buffer diagnostics, sent on every state change and finished segment.
    Events("onRecordingFinished", "onBufferStatus")

    OnCreate {
      CameraSessionController.shared.setRecordingFinishedHandler { [weak self] event in
        self?.sendEvent("onRecordingFinished", event.mapValues { $0 as Any? })
      }
      CameraSessionController.shared.buffer.setStatusHandler { [weak self] status in
        self?.sendEvent("onBufferStatus", status.mapValues { $0 as Any? })
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

    /// Starts the rolling replay buffer; resolves with its status. Rejects while recording.
    AsyncFunction("startBuffer") { (promise: Promise) in
      CameraSessionController.shared.startBuffer { result in
        Self.settle(promise, result)
      }
    }

    /// Stops the buffer after its last segment is written; resolves with the final status.
    AsyncFunction("stopBuffer") { (promise: Promise) in
      CameraSessionController.shared.stopBuffer { result in
        Self.settle(promise, result)
      }
    }

    AsyncFunction("getBufferStatus") { (promise: Promise) in
      promise.resolve(CameraSessionController.shared.buffer.currentStatus())
    }

    /// Finished segments currently kept, oldest first.
    AsyncFunction("getBufferSegments") { (promise: Promise) in
      promise.resolve(CameraSessionController.shared.buffer.currentSegments())
    }

    /// Saves the previous `seconds` (10, 15, 20, 30, 60 or 120) of the replay buffer as an MP4 in
    /// Documents/Replays, without interrupting capture. Resolves with { uri, durationSeconds, ... }.
    AsyncFunction("saveReplay") { (seconds: Double, promise: Promise) in
      ReplaySaver.shared.save(seconds: seconds) { result in
        switch result {
        case .success(let info):
          promise.resolve(info)
        case .failure(let error):
          promise.reject(error.code, error.message)
        }
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
