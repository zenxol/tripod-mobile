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
  segmentSeconds: number;
  retentionSeconds: number;
  safetyMarginSeconds: number;
  codec: string;
  /** As displayed (portrait). */
  width: number;
  height: number;
  fps: number;
  framesWritten: number;
  /** Frames the camera dropped because the pipeline was late. */
  captureDroppedFrames: number;
  /** Frames dropped because the encoder was not ready. */
  writerDroppedFrames: number;
  /** Frames missing according to the timestamps (gaps longer than 1.5 frame durations). */
  missingFrames: number;
  /** Capture pauses (interruptions or timestamp jumps over 0.5 s). */
  gaps: number;
  /** Consecutive segments whose start did not equal the previous end (should stay 0). */
  discontinuities: number;
  failedSegments: number;
  /** Newest kept segment. */
  lastSegment?: BufferSegment;
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
