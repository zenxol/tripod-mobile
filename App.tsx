import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { Alert, Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import {
  type CameraStateChangeEvent,
  TripodCameraView,
  getCameraPermissionStatusAsync,
  isCameraModuleAvailable,
  requestCameraPermissionAsync,
} from './modules/tripod-camera';

type Mode = 'home' | 'denied' | 'camera';

export default function App() {
  const [mode, setMode] = useState<Mode>('home');
  const [busy, setBusy] = useState(false);
  const [cameraStatus, setCameraStatus] = useState<CameraStateChangeEvent>({ state: 'starting' });

  const onStartCamera = async () => {
    if (!isCameraModuleAvailable || !TripodCameraView) {
      Alert.alert(
        'Camera unavailable',
        'The camera needs the Tripod iOS build. It does not work in Expo Go or on web.',
      );
      return;
    }
    if (busy) return;
    setBusy(true);
    try {
      let status = await getCameraPermissionStatusAsync();
      if (status === 'undetermined') {
        status = await requestCameraPermissionAsync();
      }
      if (status === 'granted') {
        setCameraStatus({ state: 'starting' });
        setMode('camera');
      } else {
        setMode('denied');
      }
    } catch (e) {
      Alert.alert('Camera error', e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  if (mode === 'camera' && TripodCameraView) {
    return (
      <View style={styles.cameraContainer}>
        {/* Unmounting this view (Stop Camera) stops the native capture session. */}
        <TripodCameraView
          style={StyleSheet.absoluteFill}
          onCameraStateChange={(e) => setCameraStatus(e.nativeEvent)}
        />
        <View style={styles.cameraTopBar} pointerEvents="none">
          <Text style={styles.cameraStatusText}>{describeCameraStatus(cameraStatus)}</Text>
        </View>
        <View style={styles.cameraBottomBar}>
          <Pressable
            accessibilityRole="button"
            onPress={() => setMode('home')}
            style={({ pressed }) => [styles.button, styles.stopButton, pressed && styles.buttonPressed]}
          >
            <Text style={styles.buttonText}>Stop Camera</Text>
          </Pressable>
        </View>
        <StatusBar style="light" />
      </View>
    );
  }

  if (mode === 'denied') {
    return (
      <View style={styles.container}>
        <Text style={styles.deniedTitle}>Camera access is off</Text>
        <Text style={styles.deniedBody}>
          Tripod needs the camera to show the court. Turn on Camera for Tripod in Settings, then
          come back and tap Start Camera.
        </Text>
        <Pressable
          accessibilityRole="button"
          onPress={() => Linking.openSettings()}
          style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
        >
          <Text style={styles.buttonText}>Open Settings</Text>
        </Pressable>
        <Pressable accessibilityRole="button" onPress={() => setMode('home')} style={styles.linkButton}>
          <Text style={styles.linkText}>Back</Text>
        </Pressable>
        <StatusBar style="auto" />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Tripod</Text>
      <Text style={styles.subtitle}>Pickleball Instant Replay</Text>
      <Pressable
        accessibilityRole="button"
        disabled={busy}
        onPress={onStartCamera}
        style={({ pressed }) => [styles.button, (pressed || busy) && styles.buttonPressed]}
      >
        <Text style={styles.buttonText}>Start Camera</Text>
      </Pressable>
      <StatusBar style="auto" />
    </View>
  );
}

function describeCameraStatus({ state, message }: CameraStateChangeEvent): string {
  switch (state) {
    case 'starting':
      return 'Starting camera…';
    case 'running':
      return 'LIVE';
    case 'interrupted':
      return message ?? 'Camera paused';
    case 'stopped':
      return 'Camera stopped';
    case 'error':
      return `Camera error: ${message ?? 'unknown'}`;
  }
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 24,
  },
  title: {
    fontSize: 44,
    fontWeight: '700',
    color: '#111',
  },
  subtitle: {
    fontSize: 18,
    color: '#555',
    marginTop: 8,
    marginBottom: 40,
  },
  button: {
    backgroundColor: '#1f7a4d',
    paddingVertical: 14,
    paddingHorizontal: 32,
    borderRadius: 12,
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonText: {
    color: '#fff',
    fontSize: 18,
    fontWeight: '600',
  },
  deniedTitle: {
    fontSize: 24,
    fontWeight: '700',
    color: '#111',
    marginBottom: 12,
  },
  deniedBody: {
    fontSize: 16,
    color: '#555',
    textAlign: 'center',
    marginBottom: 32,
  },
  linkButton: {
    marginTop: 16,
    padding: 8,
  },
  linkText: {
    fontSize: 16,
    color: '#1f7a4d',
  },
  cameraContainer: {
    flex: 1,
    backgroundColor: '#000',
  },
  cameraTopBar: {
    position: 'absolute',
    top: 60,
    left: 16,
    right: 16,
    alignItems: 'center',
  },
  cameraStatusText: {
    color: '#fff',
    fontSize: 15,
    fontWeight: '600',
    backgroundColor: 'rgba(0,0,0,0.5)',
    paddingVertical: 6,
    paddingHorizontal: 12,
    borderRadius: 8,
    overflow: 'hidden',
    textAlign: 'center',
  },
  cameraBottomBar: {
    position: 'absolute',
    bottom: 48,
    left: 0,
    right: 0,
    alignItems: 'center',
  },
  stopButton: {
    backgroundColor: '#b3261e',
  },
});
