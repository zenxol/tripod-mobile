import type { ComponentType } from 'react';
import type { ViewProps } from 'react-native';
import { type EventSubscription, NativeModule, requireNativeView, requireOptionalNativeModule } from 'expo';

export type CameraPermissionStatus = 'granted' | 'denied' | 'undetermined';

export type CameraState = 'starting' | 'running' | 'interrupted' | 'error';

/** What the camera is actually doing (read back from the device, not what was requested). */
export type CaptureSettings = {
  /** Camera format size, sensor orientation (e.g. 1920×1080; recordings are rotated to portrait). */
  width: number;
  height: number;
  /** Frame rate currently locked on the device. */
  fps: number;
  /** Frame rate chosen at setup; `fps` is lower while the phone is too hot. */
  targetFps: number;
  /** Recording codec: 'hevc', 'h264', or 'default' if neither could be selected. */
  codec: string;
  /** Explains any fallback (e.g. 60 fps unsupported) or thermal frame-rate reduction. */
  note?: string;
};

export type CameraStateChangeEvent = {
  state: CameraState;
  /** Human-readable reason, present for `interrupted` and `error`. */
  message?: string;
  /** Present once the camera has been configured. */
  settings?: CaptureSettings;
};

export type TripodCameraViewProps = ViewProps & {
  /** Runs the capture session while true (default). Unmounting the view also stops it. */
  active?: boolean;
  onCameraStateChange?: (event: { nativeEvent: CameraStateChangeEvent }) => void;
};

/** Why a recording ended: Stop Recording, the camera screen closed, or iOS ended it (interruption, low storage). */
export type RecordingEndedBy = 'user' | 'cameraClosed' | 'system';

export type RecordingStarted = {
  fileName: string;
  /** ISO 8601, when the file actually started being written. */
  startedAt: string;
};

export type RecordingInfo = {
  /** file:// URI in the app's Documents/Recordings folder. */
  uri: string;
  fileName: string;
  durationSeconds: number;
  /** As displayed (portrait), read from the saved file. */
  width: number;
  height: number;
  /** Average frame rate of the saved file. */
  frameRate: number;
  /** Codec read from the saved file: 'hevc', 'h264' or another FourCC. */
  codec: string;
  sizeBytes: number;
  startedAt: string;
  endedBy: RecordingEndedBy;
  /** Set when iOS ended the recording but the file is still complete (e.g. interruption). */
  note?: string;
};

export type RecordingFinishedEvent =
  | ({ ok: true } & RecordingInfo)
  | { ok: false; code: string; message: string; endedBy: RecordingEndedBy };

/**
 * idle: not running · starting · buffering: writing segments · paused: capture interrupted
 * (resumes by itself) · stopping: finishing the last segment · error: stopped itself (see message).
 */
export type BufferState = 'idle' | 'starting' | 'buffering' | 'paused' | 'stopping' | 'error';

/** One finished segment file in the rolling buffer. */
export type BufferSegment = {
  index: number;
  fileName: string;
  /** file:// URI in the app's tmp/rolling-buffer folder. */
  uri: string;
  /** Capture-clock timestamps (seconds) of the first frame and of the segment's end. */
  startTime: number;
  endTime: number;
  durationSeconds: number;
  /** ISO 8601 wall-clock times. */
  startedAt: string;
  endedAt: string;
  frameCount: number;
  /** frameCount / durationSeconds, from real timestamps. */
  fps: number;
  /** Frames missing inside this segment according to the timestamps. */
  missingFrames: number;
  /** Longest interval between two consecutive frames in this segment. */
  maxFrameIntervalMs: number;
  sizeBytes: number;
  /** Capture stopped before this segment (interruption or timestamp gap). */
  followsGap: boolean;
};

export type BufferStatus = {
  state: BufferState;
  message?: string;
  /** Finished segments currently kept. */
  segmentCount: number;
  /** Total duration of the kept segments. */
  bufferedSeconds: number;
  /** Disk space used by the kept segments. */
  storageBytes: number;
  /** Everything in the buffer folder, including files being written and protected expired segments. */
  diskBytes: number;
  fileCount: number;
  /** The app's physical memory footprint, sampled with each segment. */
  memoryBytes: number;
  segmentSeconds: number;
  retentionSeconds: number;
  safetyMarginSeconds: number;
  codec: string;
  /** As displayed (portrait). */
  width: number;
  height: number;
  /** Frame rate the camera is locked to. */
  fps: number;
  /** Frame rate measured from the newest segment's timestamps. */
  measuredFps: number;
  framesWritten: number;
  /** Frames the camera dropped (any reason). */
  captureDroppedFrames: number;
  /** ...of which: the pipeline was late. */
  droppedLateFrames: number;
  /** ...of which: the camera ran out of frame buffers. */
  droppedOutOfBuffersFrames: number;
  /** Frames dropped because the encoder was not ready. */
  writerDroppedFrames: number;
  /** Frames missing according to the timestamps (intervals longer than 1.5 frame durations). */
  missingFrames: number;
  /** Frames rejected because their timestamp went backwards. */
  outOfOrderFrames: number;
  /** Capture pauses (interruptions or timestamp jumps over 0.5 s). */
  gaps: number;
  /** Consecutive segments with time missing between them that no pause explains (should stay 0). */
  segmentGaps: number;
  /** Consecutive segments that overlap in time (should stay 0). */
  segmentOverlaps: number;
  /** Segment index order disagreeing with timestamp order (should stay 0). */
  orderingErrors: number;
  failedSegments: number;
  /** Segments deleted by retention since the buffer started. */
  expiredSegments: number;
  /** Unknown finalized files found in the buffer folder and deleted. */
  orphansRemoved: number;
  /** Segments currently protected from deletion. */
  protectedSegments: number;
  /** Expired segments kept only because they are protected. */
  retiredSegments: number;
  /** Newest kept segment. */
  lastSegment?: BufferSegment;
};

/** Replay lengths accepted by saveReplay(), seconds. */
export const REPLAY_DURATIONS = [10, 15, 20, 30, 60, 120] as const;
export type ReplayDuration = (typeof REPLAY_DURATIONS)[number];
export const DEFAULT_REPLAY_DURATION: ReplayDuration = 20;

export type ReplayInfo = {
  /** file:// URI in the app's Documents/Replays folder (Files app: On My iPhone → Tripod → Replays). */
  uri: string;
  fileName: string;
  /** Duration of the saved file. */
  durationSeconds: number;
  requestedSeconds: number;
  /** Footage selected from the buffer (shorter than requested if the buffer was younger). */
  plannedSeconds: number;
  sizeBytes: number;
  width: number;
  height: number;
  codec: string;
  /** ISO 8601: the press, and the wall-clock span the replay covers. */
  pressedAt: string;
  startedAt: string;
  endedAt: string;
  /** Buffer segments the replay was assembled from. */
  segmentCount: number;
  /** How long the export took. */
  exportSeconds: number;
  /** Less footage than requested, capture pauses inside the window, or skipped segments. */
  note?: string;
};

type TripodCameraEvents = {
  onRecordingFinished: (event: RecordingFinishedEvent) => void;
  onBufferStatus: (status: BufferStatus) => void;
};

declare class TripodCameraNativeModule extends NativeModule<TripodCameraEvents> {
  getPermissionStatusAsync(): Promise<CameraPermissionStatus>;
  requestPermissionAsync(): Promise<CameraPermissionStatus>;
  startRecording(): Promise<RecordingStarted>;
  stopRecording(): Promise<RecordingInfo>;
  startBuffer(): Promise<BufferStatus>;
  stopBuffer(): Promise<BufferStatus>;
  getBufferStatus(): Promise<BufferStatus>;
  getBufferSegments(): Promise<BufferSegment[]>;
  saveReplay(seconds: number): Promise<ReplayInfo>;
}

// Optional: the module is absent in Expo Go, on web and on Android, where the app
// should show a message instead of crashing at import time.
const CameraModule = requireOptionalNativeModule<TripodCameraNativeModule>('TripodCamera');

/** False when running without the custom native build (e.g. Expo Go). */
export const isCameraModuleAvailable = CameraModule != null;

export const TripodCameraView: ComponentType<TripodCameraViewProps> | null = CameraModule
  ? requireNativeView<TripodCameraViewProps>('TripodCamera')
  : null;

function unavailable(): Error {
  return new Error('The Tripod camera module is not available in this build.');
}

export async function getCameraPermissionStatusAsync(): Promise<CameraPermissionStatus> {
  if (!CameraModule) return 'denied';
  return CameraModule.getPermissionStatusAsync();
}

export async function requestCameraPermissionAsync(): Promise<CameraPermissionStatus> {
  if (!CameraModule) return 'denied';
  return CameraModule.requestPermissionAsync();
}

/** Resolves once the native recorder is actually writing. Rejects (e.g. ERR_ALREADY_RECORDING, ERR_CAMERA_NOT_RUNNING). */
export async function startRecording(): Promise<RecordingStarted> {
  if (!CameraModule) throw unavailable();
  return CameraModule.startRecording();
}

/** Resolves with the saved, verified recording. Rejects with ERR_NOT_RECORDING if nothing is recording. */
export async function stopRecording(): Promise<RecordingInfo> {
  if (!CameraModule) throw unavailable();
  return CameraModule.stopRecording();
}

/**
 * Starts the rolling replay buffer (the camera must be running). Rejects with
 * ERR_RECORDING_ACTIVE while a recording is in progress, ERR_LOW_STORAGE, etc.
 */
export async function startBuffer(): Promise<BufferStatus> {
  if (!CameraModule) throw unavailable();
  return CameraModule.startBuffer();
}

/** Stops the buffer once its last segment is written. Safe to call when it is not running. */
export async function stopBuffer(): Promise<BufferStatus> {
  if (!CameraModule) throw unavailable();
  return CameraModule.stopBuffer();
}

export async function getBufferStatus(): Promise<BufferStatus> {
  if (!CameraModule) throw unavailable();
  return CameraModule.getBufferStatus();
}

/** Finished segments currently kept, oldest first. */
export async function getBufferSegments(): Promise<BufferSegment[]> {
  if (!CameraModule) throw unavailable();
  return CameraModule.getBufferSegments();
}

/**
 * Saves the previous `seconds` of buffered footage as one MP4, up to the moment of the call,
 * while the camera keeps recording. Calls queue and export one at a time. Rejects with
 * ERR_BUFFER_NOT_STARTED, ERR_NO_FOOTAGE, ERR_EXPORT_FAILED, ERR_VERIFY_FAILED, ...
 */
export async function saveReplay(seconds: ReplayDuration): Promise<ReplayInfo> {
  if (!CameraModule) throw unavailable();
  return CameraModule.saveReplay(seconds);
}

/** Buffer diagnostics on every state change and every finished segment (about every 5 s). */
export function addBufferStatusListener(listener: (status: BufferStatus) => void): EventSubscription | null {
  return CameraModule ? CameraModule.addListener('onBufferStatus', listener) : null;
}

/**
 * Fires every time a recording ends, including endings JS did not request
 * (interruption, low storage, camera closed). Use it as the source of truth for UI state.
 */
export function addRecordingFinishedListener(
  listener: (event: RecordingFinishedEvent) => void,
): EventSubscription | null {
  return CameraModule ? CameraModule.addListener('onRecordingFinished', listener) : null;
}
