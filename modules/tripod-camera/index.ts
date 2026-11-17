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

type TripodCameraEvents = {
  onRecordingFinished: (event: RecordingFinishedEvent) => void;
};

declare class TripodCameraNativeModule extends NativeModule<TripodCameraEvents> {
  getPermissionStatusAsync(): Promise<CameraPermissionStatus>;
  requestPermissionAsync(): Promise<CameraPermissionStatus>;
  startRecording(): Promise<RecordingStarted>;
  stopRecording(): Promise<RecordingInfo>;
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
 * Fires every time a recording ends, including endings JS did not request
 * (interruption, low storage, camera closed). Use it as the source of truth for UI state.
 */
export function addRecordingFinishedListener(
  listener: (event: RecordingFinishedEvent) => void,
): EventSubscription | null {
  return CameraModule ? CameraModule.addListener('onRecordingFinished', listener) : null;
}
