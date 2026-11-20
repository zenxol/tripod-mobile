import AVFoundation
import Foundation
import os

/**
 Save Replay: exports the previous X seconds of the rolling buffer as one MP4, while the camera
 and the buffer keep running.

 1. Endpoint: the capture-session clock is read the moment the request arrives (`captureNow`),
    on the same timeline as the frames' presentation timestamps.
 2. The recorder cuts the open segment at the first frame after the endpoint and finalizes it
    (`reserveReplay`); capture continues in a new segment with no gap.
 3. The window [endpoint - X, endpoint) is selected from finalized segments by their real
    timestamps (`ReplayPlanner`) and protected from retention (`SegmentLease`).
 4. Exports run one at a time (`SerialJobQueue`): an AVMutableComposition of the trimmed
    pieces, exported with the passthrough preset (no re-encoding), to
    `tmp/replay-export/<name>.mp4`, verified, then moved to `Documents/Replays/<name>.mp4`
    (`ReplaySaveRunner`). The protection is released afterwards in every case.
 */
final class ReplaySaver: @unchecked Sendable {
  static let shared = ReplaySaver(buffer: CameraSessionController.shared.buffer)

  /// Permanent clips (visible in the Files app under On My iPhone → Tripod → Replays).
  static var replaysDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Replays", isDirectory: true)
  }

  /// Exports in progress. Emptied on launch, so a crash never leaves a partial clip in Replays.
  static var workDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("replay-export", isDirectory: true)
  }

  private static let log = Logger(subsystem: "com.zenxol.tripod", category: "replay")
  private static let isoFormatter = ISO8601DateFormatter()

  private let buffer: RollingBufferRecorder
  private let jobs = SerialJobQueue()

  init(buffer: RollingBufferRecorder) {
    self.buffer = buffer
  }

  /// Saves the previous `seconds` of footage. Completes (on a background thread) with the
  /// saved clip's metadata, or a ReplayError.
  func save(seconds: Double, completion: @escaping (Result<[String: Any], ReplayError>) -> Void) {
    // The endpoint first, before any queue hop.
    let endpoint = buffer.captureNow()
    let pressedAt = Date()

    guard ReplayDurations.allowed.contains(seconds) else {
      return completion(.failure(ReplayError(
        code: "ERR_INVALID_DURATION",
        message: "Replay length must be one of \(ReplayDurations.allowed.map { Int($0) }) seconds.")))
    }
    guard let endpoint else {
      return completion(.failure(ReplayError(
        code: "ERR_BUFFER_NOT_STARTED", message: "Start the replay buffer before saving a replay.")))
    }

    buffer.reserveReplay(endpoint: endpoint, seconds: seconds) { [self] result in
      switch result {
      case .failure(let error):
        Self.log.error("Replay not saved: \(error.code, privacy: .public) \(error.message, privacy: .public)")
        completion(.failure(error))
      case .success(let reservation):
        let plan = reservation.plan
        let ahead = jobs.pendingCount
        Self.log.info("Replay \(Int(seconds)) s requested: \(plan.duration) s available in \(plan.pieces.count) segment piece(s), \(ahead) export(s) ahead")
        jobs.enqueue { [self] in
          completion(await export(reservation, pressedAt: pressedAt))
        }
      }
    }
  }

  // MARK: - Export job (one at a time)

  private func export(
    _ reservation: RollingBufferRecorder.ReplayReservation, pressedAt: Date
  ) async -> Result<[String: Any], ReplayError> {
    let plan = reservation.plan
    let fileManager = FileManager.default
    let started = Date()

    guard let fileName = ReplayFileNaming.makeFileName(date: pressedAt, fileExtension: "mp4", isTaken: { name in
      fileManager.fileExists(atPath: Self.replaysDirectory.appendingPathComponent(name).path)
        || fileManager.fileExists(atPath: Self.workDirectory.appendingPathComponent(name).path)
    }) else {
      buffer.releaseSegments(reservation.lease)
      return .failure(ReplayError(code: "ERR_FILE", message: "Could not find a free file name for the replay."))
    }
    let tempURL = Self.workDirectory.appendingPathComponent(fileName)
    let finalURL = Self.replaysDirectory.appendingPathComponent(fileName)

    var details: ClipDetails?
    var skippedPieces = 0
    let result = await ReplaySaveRunner.run(
      plan: plan,
      tempURL: tempURL,
      finalURL: finalURL,
      export: { plan, url in
        skippedPieces = try await Self.exportComposition(plan, from: RollingBufferRecorder.directory, to: url)
      },
      verify: { url in
        let inspected = try await Self.inspect(url)
        details = inspected
        return inspected.durationSeconds
      },
      release: { [buffer] in
        buffer.releaseSegments(reservation.lease)
      })

    let exportSeconds = Date().timeIntervalSince(started)
    switch result {
    case .failure(let error):
      Self.log.error("Replay export failed after \(exportSeconds) s: \(error.code, privacy: .public) \(error.message, privacy: .public)")
      return .failure(error)
    case .success(let output):
      var notes: [String] = []
      if plan.isShort {
        notes.append("Only \(Self.oneDecimal(plan.duration)) s of the requested \(Int(plan.requestedSeconds)) s was buffered.")
      }
      if plan.missingInside > 0.05 {
        notes.append("Includes a \(Self.oneDecimal(plan.missingInside)) s gap where capture was paused.")
      }
      if skippedPieces > 0 {
        notes.append("\(skippedPieces) buffer segment(s) were missing and skipped.")
      }
      var info: [String: Any] = [
        "uri": output.url.absoluteString,
        "fileName": fileName,
        "durationSeconds": RollingBufferRecorder.round(output.durationSeconds, places: 3),
        "requestedSeconds": plan.requestedSeconds,
        "plannedSeconds": RollingBufferRecorder.round(plan.duration, places: 3),
        "sizeBytes": Double(details?.sizeBytes ?? 0),
        "width": details?.width ?? 0,
        "height": details?.height ?? 0,
        "codec": details?.codec ?? "unknown",
        "pressedAt": Self.isoFormatter.string(from: pressedAt),
        "startedAt": Self.isoFormatter.string(from: reservation.startedAt),
        "endedAt": Self.isoFormatter.string(from: reservation.endedAt),
        "segmentCount": plan.pieces.count,
        "exportSeconds": RollingBufferRecorder.round(exportSeconds, places: 2),
      ]
      if !notes.isEmpty {
        info["note"] = notes.joined(separator: " ")
      }
      Self.log.info("Saved \(fileName, privacy: .public): \(output.durationSeconds) s (planned \(plan.duration) s), export took \(exportSeconds) s")
      return .success(info)
    }
  }

  // MARK: - AVFoundation

  /// Builds a composition of the plan's pieces (back to back) and exports it without
  /// re-encoding. Returns how many pieces had to be skipped because their file was missing.
  private static func exportComposition(_ plan: ReplayPlan, from directory: URL, to url: URL) async throws -> Int {
    let composition = AVMutableComposition()
    guard let track = composition.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw ReplayError(code: "ERR_EXPORT_FAILED", message: "Could not create the replay video track.")
    }

    var cursor = CMTime.zero
    var transform: CGAffineTransform?
    var skipped = 0
    for piece in plan.pieces {
      let fileURL = directory.appendingPathComponent(piece.fileName)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        log.error("Replay: segment file \(piece.fileName, privacy: .public) is missing; skipped")
        skipped += 1
        continue
      }
      let asset = AVURLAsset(url: fileURL)
      guard let source = try await asset.loadTracks(withMediaType: .video).first else {
        log.error("Replay: segment \(piece.fileName, privacy: .public) has no video track; skipped")
        skipped += 1
        continue
      }
      let (range, sourceTransform) = try await source.load(.timeRange, .preferredTransform)
      // The segment file's timeline starts at its first frame (the writer session start), so
      // the piece's offset into the file is its offset from the segment's first timestamp.
      let start = max(range.start + time(piece.fileOffset), range.start)
      let end = min(start + time(piece.duration), range.end)
      guard end > start else { continue }
      try track.insertTimeRange(CMTimeRange(start: start, end: end), of: source, at: cursor)
      cursor = cursor + (end - start)
      if transform == nil {
        transform = sourceTransform
      }
    }
    guard cursor > .zero else {
      throw ReplayError(code: "ERR_NO_FOOTAGE", message: "The buffered footage for this replay is missing.")
    }
    // Portrait, like the buffer segments and recordings.
    track.preferredTransform = transform ?? .identity

    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
      throw ReplayError(code: "ERR_EXPORT_FAILED", message: "The replay exporter could not be created.")
    }
    session.shouldOptimizeForNetworkUse = true
    if #available(iOS 18.0, *) {
      try await session.export(to: url, as: .mp4)
    } else {
      session.outputURL = url
      session.outputFileType = .mp4
      await session.export()
      guard session.status == .completed else {
        throw session.error ?? ReplayError(code: "ERR_EXPORT_FAILED", message: "The export did not complete.")
      }
    }
    return skipped
  }

  private struct ClipDetails {
    let durationSeconds: Double
    let width: Int
    let height: Int
    let codec: String
    let sizeBytes: Int64
  }

  /// Opens the exported file; throws if it can't be read or has no video.
  private static func inspect(_ url: URL) async throws -> ClipDetails {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw ReplayError(code: "ERR_VERIFY_FAILED", message: "The exported replay has no video.")
    }
    let (naturalSize, transform, formatDescriptions) = try await track.load(
      .naturalSize, .preferredTransform, .formatDescriptions)
    let displaySize = naturalSize.applying(transform)
    let codec = formatDescriptions.first.map {
      CaptureConfiguration.codecName(fourCC: CMFormatDescriptionGetMediaSubType($0))
    } ?? "unknown"
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    return ClipDetails(
      durationSeconds: duration.seconds,
      width: Int(abs(displaySize.width).rounded()),
      height: Int(abs(displaySize.height).rounded()),
      codec: codec,
      sizeBytes: size)
  }

  private static func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  private static func oneDecimal(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}
