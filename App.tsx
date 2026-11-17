import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef, useState } from 'react';
import { Alert, Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import {
  type CameraStateChangeEvent,
  type RecordingFinishedEvent,
  TripodCameraView,
  addRecordingFinishedListener,
  getCameraPermissionStatusAsync,
  isCameraModuleAvailable,
  requestCameraPermissionAsync,
  startRecording,
  stopRecording,
} from './modules/tripod-camera';

type Mode = 'home' | 'denied' | 'camera';
type RecordingPhase = 'idle' | 'starting' | 'recording' | 'stopping';
type Banner = { kind: 'success' | 'error'; text: string };

export default function App() {
  const [mode, setMode] = useState<Mode>('home');
  const [busy, setBusy] = useState(false);
  const [cameraStatus, setCameraStatus] = useState<CameraStateChangeEvent>({ state: 'starting' });
  const [phase, setPhase] = useState<RecordingPhase>('idle');
  const [recordingStartedAt, setRecordingStartedAt] = useState<number | null>(null);
  const [elapsedMs, setElapsedMs] = useState(0);
  const [banner, setBanner] = useState<Banner | null>(null);
  // Guards against double taps before React re-renders the disabled button.
  const recordingRequest = useRef(false);

  // Every recording ending (requested or not) arrives here: the single source of truth for UI state.
  useEffect(() => {
    const subscription = addRecordingFinishedListener((event) => {
      recordingRequest.current = false;
      setPhase('idle');
      setRecordingStartedAt(null);
      setBanner(describeRecordingFinished(event));
    });
    return () => subscription?.remove();
  }, []);

  // Recording duration timer.
  useEffect(() => {
    if (phase !== 'recording' || recordingStartedAt == null) {
      setElapsedMs(0);
      return;
    }
    setElapsedMs(Date.now() - recordingStartedAt);
    const timer = setInterval(() => setElapsedMs(Date.now() - recordingStartedAt), 250);
    return () => clearInterval(timer);
  }, [phase, recordingStartedAt]);

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
      Alert.alert('Camera error', errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const onStartRecording = async () => {
    if (recordingRequest.current || phase !== 'idle') return;
    recordingRequest.current = true;
    setBanner(null);
    setPhase('starting');
    try {
      await startRecording();
      setRecordingStartedAt(Date.now());
      setPhase('recording');
    } catch (e) {
      setPhase('idle');
      setBanner({ kind: 'error', text: `Could not start recording: ${errorMessage(e)}` });
    } finally {
      recordingRequest.current = false;
    }
  };

  const onStopRecording = async () => {
    if (phase !== 'recording') return;
    setPhase('stopping');
    try {
      // onRecordingFinished reports the same result; applying it here too means the UI
      // never stays stuck in "Saving…" if the event were missed.
      const info = await stopRecording();
      setPhase('idle');
      setRecordingStartedAt(null);
      setBanner(describeRecordingFinished({ ok: true, ...info }));
    } catch (e) {
      setPhase('idle');
      setRecordingStartedAt(null);
      setBanner({ kind: 'error', text: `Could not stop recording: ${errorMessage(e)}` });
    }
  };

  const onStopCamera = () => {
    // Unmounting the camera view releases the camera; native code finishes and saves
    // any recording first, and the result still arrives through onRecordingFinished.
    setMode('home');
  };

  if (mode === 'camera' && TripodCameraView) {
    const cameraReady = cameraStatus.state === 'running';
    const isRecording = phase === 'recording' || phase === 'stopping';
    return (
      <View style={styles.cameraContainer}>
        <TripodCameraView
          style={StyleSheet.absoluteFill}
          onCameraStateChange={(e) => setCameraStatus(e.nativeEvent)}
        />
        <View style={styles.cameraTopBar} pointerEvents="none">
          {isRecording ? (
            <View style={styles.recIndicator}>
              <View style={styles.recDot} />
              <Text style={styles.recText}>REC {formatElapsed(elapsedMs)}</Text>
            </View>
          ) : (
            <Text style={styles.cameraStatusText}>{describeCameraStatus(cameraStatus)}</Text>
          )}
          {isRecording && !cameraReady && (
            <Text style={[styles.cameraStatusText, styles.topBarSpacing]}>
              {describeCameraStatus(cameraStatus)}
            </Text>
          )}
        </View>
        <View style={styles.cameraBottomBar}>
          {banner && <BannerView banner={banner} onDismiss={() => setBanner(null)} />}
          {isRecording ? (
            <Pressable
              accessibilityRole="button"
              disabled={phase === 'stopping'}
              onPress={onStopRecording}
              style={({ pressed }) => [
                styles.button,
                styles.recordButton,
                (pressed || phase === 'stopping') && styles.buttonPressed,
              ]}
            >
              <Text style={styles.buttonText}>{phase === 'stopping' ? 'Saving…' : 'Stop Recording'}</Text>
            </Pressable>
          ) : (
            <Pressable
              accessibilityRole="button"
              disabled={!cameraReady || phase !== 'idle'}
              onPress={onStartRecording}
              style={({ pressed }) => [
                styles.button,
                styles.recordButton,
                (pressed || !cameraReady || phase !== 'idle') && styles.buttonDisabled,
              ]}
            >
              <Text style={styles.buttonText}>{phase === 'starting' ? 'Starting…' : 'Start Recording'}</Text>
            </Pressable>
          )}
          <Pressable accessibilityRole="button" onPress={onStopCamera} style={styles.closeCameraButton}>
            <Text style={styles.closeCameraText}>Stop Camera</Text>
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
      {/* A recording finished by Stop Camera reports here. */}
      {banner && (
        <View style={styles.homeBanner}>
          <BannerView banner={banner} onDismiss={() => setBanner(null)} />
        </View>
      )}
      <StatusBar style="auto" />
    </View>
  );
}

function BannerView({ banner, onDismiss }: { banner: Banner; onDismiss: () => void }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityHint="Dismisses the message"
      onPress={onDismiss}
      style={[styles.banner, banner.kind === 'error' ? styles.bannerError : styles.bannerSuccess]}
    >
      <Text style={styles.bannerText}>{banner.text}</Text>
    </Pressable>
  );
}

function describeRecordingFinished(event: RecordingFinishedEvent): Banner {
  if (!event.ok) {
    return { kind: 'error', text: `Recording failed: ${event.message}` };
  }
  const details = [
    formatDuration(event.durationSeconds),
    `${event.width}×${event.height}`,
    `${(event.sizeBytes / 1_048_576).toFixed(1)} MB`,
  ].join(' · ');
  const reason =
    event.endedBy === 'system' ? `\nStopped by iOS: ${event.note ?? 'the camera was interrupted'}` : '';
  return { kind: 'success', text: `Saved ${event.fileName}\n${details}${reason}` };
}

function describeCameraStatus({ state, message }: CameraStateChangeEvent): string {
  switch (state) {
    case 'starting':
      return 'Starting camera…';
    case 'running':
      return 'LIVE';
    case 'interrupted':
      return message ?? 'Camera paused';
    case 'error':
      return `Camera error: ${message ?? 'unknown'}`;
  }
}

function formatElapsed(ms: number): string {
  const total = Math.floor(ms / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

function formatDuration(seconds: number): string {
  return seconds < 60 ? `${seconds.toFixed(1)} s` : formatElapsed(seconds * 1000);
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
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
  buttonDisabled: {
    opacity: 0.5,
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
  homeBanner: {
    position: 'absolute',
    bottom: 48,
    left: 16,
    right: 16,
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
  topBarSpacing: {
    marginTop: 8,
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
  recIndicator: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.5)',
    paddingVertical: 6,
    paddingHorizontal: 12,
    borderRadius: 8,
  },
  recDot: {
    width: 12,
    height: 12,
    borderRadius: 6,
    backgroundColor: '#ff3b30',
    marginRight: 8,
  },
  recText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
  },
  cameraBottomBar: {
    position: 'absolute',
    bottom: 40,
    left: 16,
    right: 16,
    alignItems: 'center',
  },
  recordButton: {
    backgroundColor: '#d70015',
    minWidth: 220,
    alignItems: 'center',
  },
  closeCameraButton: {
    marginTop: 12,
    paddingVertical: 10,
    paddingHorizontal: 24,
  },
  closeCameraText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  banner: {
    alignSelf: 'stretch',
    borderRadius: 10,
    paddingVertical: 10,
    paddingHorizontal: 14,
    marginBottom: 12,
  },
  bannerSuccess: {
    backgroundColor: 'rgba(31,122,77,0.92)',
  },
  bannerError: {
    backgroundColor: 'rgba(179,38,30,0.92)',
  },
  bannerText: {
    color: '#fff',
    fontSize: 14,
  },
});
