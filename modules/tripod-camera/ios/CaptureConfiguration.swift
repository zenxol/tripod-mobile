import AVFoundation
import CoreMedia

/**
 Capture quality policy: which camera format, frame rate and codec to use, and why.

 Kept separate from CameraSessionController so later tasks can change the policy in one
 place (for example the ultra-wide lens or landscape recording) without touching session,
 recording or interruption handling.
 */
enum CaptureConfiguration {
  /// Camera used for preview and recording. Future: ultra-wide (`.builtInUltraWideCamera`) for more court.
  static let deviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
  static let devicePosition: AVCaptureDevice.Position = .back

  /// Rotation applied to the preview and the recording (90 = portrait). Future: landscape support.
  static let rotationAngle: CGFloat = 90

  /// Tried in order; the first one the camera supports wins.
  static let targets: [CaptureTarget] = [
    CaptureTarget(width: 1920, height: 1080, fps: 60),
    CaptureTarget(width: 1920, height: 1080, fps: 30),
    CaptureTarget(width: 1280, height: 720, fps: 60),
    CaptureTarget(width: 1280, height: 720, fps: 30),
  ]

  /// Frame rate used while the phone reports serious/critical thermal pressure.
  static let reducedFps: Double = 30

  /// Applies `rotationAngle` to a preview or recording connection, so both always match.
  static func applyRotation(to connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(rotationAngle) {
        connection.videoRotationAngle = rotationAngle
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait // matches rotationAngle 90 on iOS 16
    }
  }

  /// Keeps a frame-delivering connection (the replay buffer's video data output) in the sensor's
  /// native landscape orientation, so the camera never rotates pixels. The display rotation is
  /// stored in each file instead (`displayTransform`).
  static func applySensorOrientation(to connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      if connection.isVideoRotationAngleSupported(0) {
        connection.videoRotationAngle = 0
      }
    } else if connection.isVideoOrientationSupported {
      connection.videoOrientation = .landscapeRight // the back camera's native orientation
    }
  }

  /// `rotationAngle` as a track transform: players show sensor-oriented frames upright, exactly
  /// like the preview and the movie-file recordings.
  static var displayTransform: CGAffineTransform {
    CGAffineTransform(rotationAngle: rotationAngle * .pi / 180)
  }

  /// Keyframe spacing for replay-buffer segments: short enough for precise seeking and trimming
  /// in the later replay and save features.
  static let bufferKeyFrameIntervalSeconds: Double = 1

  /// Picks the best supported format for the first target the device supports.
  static func selectFormat(for device: AVCaptureDevice) -> FormatSelection? {
    for (index, target) in targets.enumerated() {
      let candidates = device.formats.filter { format in
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width == target.width, dimensions.height == target.height else { return false }
        // 8-bit SDR 4:2:0 only: these are the native camera formats, they need no conversion,
        // and they avoid 10-bit HDR files that look washed out on many players.
        let pixelFormat = CMFormatDescriptionGetMediaSubType(description)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else { return false }
        return format.videoSupportedFrameRateRanges.contains {
          $0.minFrameRate <= target.fps && target.fps <= $0.maxFrameRate
        }
      }

      // Prefer full-quality sensor readout (not binned), then the widest field of view
      // (more court), then the format whose top speed is closest to the target (high-speed
      // formats trade quality for frame rate), then video range (the standard for video).
      let best = candidates.min { a, b in
        if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
        if a.videoFieldOfView != b.videoFieldOfView { return a.videoFieldOfView > b.videoFieldOfView }
        let aMax = maxFrameRate(a), bMax = maxFrameRate(b)
        if aMax != bMax { return aMax < bMax }
        return isVideoRange(a) && !isVideoRange(b)
      }

      if let best {
        let first = targets[0]
        let note = index == 0
          ? nil
          : "\(first.label) is not supported by this camera; using \(target.label)."
        return FormatSelection(format: best, target: target, fallbackNote: note)
      }
    }
    return nil
  }

  /// Preferred recording codec: hardware HEVC when available, else H.264.
  static func preferredCodec(from available: [AVVideoCodecType]) -> AVVideoCodecType? {
    if available.contains(.hevc) { return .hevc }
    if available.contains(.h264) { return .h264 }
    return nil
  }

  static func codecName(_ codec: AVVideoCodecType?) -> String {
    guard let codec else { return "default" }
    if codec == .hevc { return "hevc" }
    if codec == .h264 { return "h264" }
    return codec.rawValue
  }

  /// Codec name from a file's video format description ("hevc", "h264", or the raw FourCC).
  static func codecName(fourCC: FourCharCode) -> String {
    switch fourCC {
    case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return "hevc"
    case kCMVideoCodecType_H264: return "h264"
    default:
      let bytes = [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xFF) }
      return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
  }

  static func maxFrameRate(_ format: AVCaptureDevice.Format) -> Double {
    format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
  }

  static func supports(_ format: AVCaptureDevice.Format, fps: Double) -> Bool {
    format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
  }

  private static func isVideoRange(_ format: AVCaptureDevice.Format) -> Bool {
    CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
}

struct CaptureTarget {
  let width: Int32
  let height: Int32
  let fps: Double

  var label: String { "\(height)p\(Int(fps))" }
}

struct FormatSelection {
  let format: AVCaptureDevice.Format
  let target: CaptureTarget
  let fallbackNote: String?
}

/// What the camera is actually doing, reported to JS with the `running` state and logged.
struct CaptureSettings {
  var width: Int
  var height: Int
  /// Frame rate currently locked on the device.
  var fps: Double
  /// Frame rate chosen at setup (fps can be temporarily lower under thermal pressure).
  var targetFps: Double
  var codec: String
  var note: String?

  var summary: String {
    "\(width)x\(height) @ \(Int(fps.rounded())) fps, \(codec)" + (note.map { " (\($0))" } ?? "")
  }

  func dictionary() -> [String: Any] {
    var result: [String: Any] = [
      "width": width,
      "height": height,
      "fps": fps,
      "targetFps": targetFps,
      "codec": codec,
    ]
    if let note {
      result["note"] = note
    }
    return result
  }
}
