import type { ComponentType } from 'react';
import type { ViewProps } from 'react-native';
import { requireNativeView, requireOptionalNativeModule } from 'expo';

export type CameraPermissionStatus = 'granted' | 'denied' | 'undetermined';

export type CameraState = 'starting' | 'running' | 'interrupted' | 'stopped' | 'error';

export type CameraStateChangeEvent = {
  state: CameraState;
  /** Human-readable reason, present for `interrupted` and `error`. */
  message?: string;
};

export type TripodCameraViewProps = ViewProps & {
  /** Runs the capture session while true (default). Unmounting the view also stops it. */
  active?: boolean;
  onCameraStateChange?: (event: { nativeEvent: CameraStateChangeEvent }) => void;
};

type TripodCameraNativeModule = {
  getPermissionStatusAsync(): Promise<CameraPermissionStatus>;
  requestPermissionAsync(): Promise<CameraPermissionStatus>;
};

// Optional: the module is absent in Expo Go, on web and on Android, where the app
// should show a message instead of crashing at import time.
const NativeModule = requireOptionalNativeModule<TripodCameraNativeModule>('TripodCamera');

/** False when running without the custom native build (e.g. Expo Go). */
export const isCameraModuleAvailable = NativeModule != null;

export const TripodCameraView: ComponentType<TripodCameraViewProps> | null = NativeModule
  ? requireNativeView<TripodCameraViewProps>('TripodCamera')
  : null;

export async function getCameraPermissionStatusAsync(): Promise<CameraPermissionStatus> {
  if (!NativeModule) return 'denied';
  return NativeModule.getPermissionStatusAsync();
}

export async function requestCameraPermissionAsync(): Promise<CameraPermissionStatus> {
  if (!NativeModule) return 'denied';
  return NativeModule.requestPermissionAsync();
}
