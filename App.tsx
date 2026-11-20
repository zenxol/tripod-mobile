import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef, useState } from 'react';
import { Alert, Linking, Pressable, StyleSheet, Text, View } from 'react-native';

import {
  type BufferStatus,
  type CameraStateChangeEvent,
  type CaptureSettings,
  DEFAULT_REPLAY_DURATION,
  REPLAY_DURATIONS,
  type RecordingFinishedEvent,
  type ReplayDuration,
  type ReplayInfo,
  TripodCameraView,
  addBufferStatusListener,
  addRecordingFinishedListener,
  getCameraPermissionStatusAsync,
  isCameraModuleAvailable,
  requestCameraPermissionAsync,
  saveReplay,
  startBuffer,
  startRecording,
  stopBuffer,
  stopRecording,
} from './modules/tripod-camera';

type Mode = 'home' | 'denied' | 'camera';
type RecordingPhase = 'idle' | 'starting' | 'recording' | 'stopping';
type BufferRequest = 'none' | 'starting' | 'stopping';
type Banner = { kind: 'success' | 'error' | 'info'; text: string };

/** Ignore a second Save Replay tap this soon after the first (accidental double tap). */
const SAVE_REPLAY_DEBOUNCE_MS = 500;

/** Buffer states during which recording is blocked and the button shows Stop Buffer. */
const BUFFER_ACTIVE_STATES: ReadonlySet<BufferStatus['state']> = new Set([
  'starting',
  'buffering',
  'paused',
  'stopping',
]);

export default function App() {
  const [mode, setMode] = useState<Mode>('home');
  const [busy, setBusy] = useState(false);
  const [cameraStatus, setCameraStatus] = useState<CameraStateChangeEvent>({ state: 'starting' });
  const [captureSettings, setCaptureSettings] = useState<CaptureSettings | null>(null);
  const [phase, setPhase] = useState<RecordingPhase>('idle');
  const [recordingStartedAt, setRecordingStartedAt] = useState<number | null>(null);
  const [elapsedMs, setElapsedMs] = useState(0);
  const [banner, setBanner] = useState<Banner | null>(null);
  const [bufferStatus, setBufferStatus] = useState<BufferStatus | null>(null);
  const [bufferRequest, setBufferRequest] = useState<BufferRequest>('none');
  // Guards against double taps before React re-renders the disabled button.
  const recordingRequest = useRef(false);
  const bufferRequestRef = useRef(false);
  const [replayDuration, setReplayDuration] = useState<ReplayDuration>(DEFAULT_REPLAY_DURATION);
  const [savingCount, setSavingCount] = useState(0);
  const lastSavePress = useRef(0);

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

  // Buffer diagnostics: every state change and every finished segment.
  useEffect(() => {
    let lastLogged = '';
    const subscription = addBufferStatusListener((status) => {
      setBufferStatus(status);
      const line = `${status.state} ${status.segmentCount} segs ${status.bufferedSeconds.toFixed(1)} s`;
      if (line !== lastLogged) {
        lastLogged = line;
        console.log(`[buffer] ${formatBufferSummary(status)}${status.message ? ` (${status.message})` : ''}`);
      }
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

  const onStartBuffer = async () => {
    if (bufferRequestRef.current || phase !== 'idle') return;
    bufferRequestRef.current = true;
    setBanner(null);
    setBufferRequest('starting');
    try {
      setBufferStatus(await startBuffer());
    } catch (e) {
      setBanner({ kind: 'error', text: `Could not start the buffer: ${errorMessage(e)}` });
    } finally {
      bufferRequestRef.current = false;
      setBufferRequest('none');
    }
  };

  const onStopBuffer = async () => {
    if (bufferRequestRef.current) return;
    bufferRequestRef.current = true;
    setBufferRequest('stopping');
    try {
      setBufferStatus(await stopBuffer());
    } catch (e) {
      setBanner({ kind: 'error', text: `Could not stop the buffer: ${errorMessage(e)}` });
    } finally {
      bufferRequestRef.current = false;
      setBufferRequest('none');
    }
  };

  const onSaveReplay = async () => {
    const now = Date.now();
    if (now - lastSavePress.current < SAVE_REPLAY_DEBOUNCE_MS) return;
    lastSavePress.current = now;
    const seconds = replayDuration;
    // Each press is its own save: native code fixes the endpoint immediately and queues the export.
    setSavingCount((count) => count + 1);
    setBanner({ kind: 'info', text: `Saving the last ${seconds} s…` });
    try {
      const info = await saveReplay(seconds);
      console.log(`[replay] saved ${info.fileName}: ${info.durationSeconds.toFixed(2)} s in ${info.exportSeconds} s`);
      setBanner(describeReplaySaved(info));
    } catch (e) {
      setBanner({ kind: 'error', text: `Replay not saved: ${errorMessage(e)}` });
    } finally {
      setSavingCount((count) => count - 1);
    }
  };

  const onCameraEvent = (event: CameraStateChangeEvent) => {
    setCameraStatus(event);
    const next = event.settings;
    if (next) {
      setCaptureSettings((previous) => {
        const changed = !previous || formatSettings(previous) !== formatSettings(next) || previous.note !== next.note;
        if (changed) {
          console.log(`[camera] ${formatSettings(next)}${next.note ? ` (${next.note})` : ''}`);
        }
        return changed ? next : previous;
      });
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
    const bufferActive =
      bufferRequest !== 'none' || (bufferStatus != null && BUFFER_ACTIVE_STATES.has(bufferStatus.state));
    const showBufferPanel =
      bufferStatus != null && (bufferActive || bufferStatus.segmentCount > 0 || bufferStatus.state === 'error');
    const canStartRecording = cameraReady && phase === 'idle' && !bufferActive;
    const canSaveReplay =
      bufferRequest === 'none' &&
      bufferStatus != null &&
      (bufferStatus.state === 'buffering' || bufferStatus.segmentCount > 0);
    return (
      <View style={styles.cameraContainer}>
        <TripodCameraView
          style={StyleSheet.absoluteFill}
          onCameraStateChange={(e) => onCameraEvent(e.nativeEvent)}
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
          {captureSettings && (
            <Text style={[styles.settingsText, styles.topBarSpacing]}>
              {formatSettings(captureSettings)}
              {captureSettings.note ? `\n${captureSettings.note}` : ''}
            </Text>
          )}
          {showBufferPanel && bufferStatus && <BufferPanel status={bufferStatus} />}
        </View>
        <View style={styles.cameraBottomBar}>
          {banner && <BannerView banner={banner} onDismiss={() => setBanner(null)} />}
          <View style={styles.durationRow} accessibilityRole="radiogroup">
            {REPLAY_DURATIONS.map((seconds) => (
              <Pressable
                key={seconds}
                accessibilityRole="radio"
                accessibilityState={{ selected: seconds === replayDuration }}
                onPress={() => setReplayDuration(seconds)}
                style={[styles.durationChip, seconds === replayDuration && styles.durationChipSelected]}
              >
                <Text style={[styles.durationText, seconds === replayDuration && styles.durationTextSelected]}>
                  {seconds}s
                </Text>
              </Pressable>
            ))}
          </View>
          <Pressable
            accessibilityRole="button"
            disabled={!canSaveReplay}
            onPress={onSaveReplay}
            style={({ pressed }) => [
              styles.button,
              styles.replayButton,
              (pressed || !canSaveReplay) && styles.buttonDisabled,
            ]}
          >
            <Text style={styles.buttonText}>
              {savingCount > 0 ? `Save Replay (${savingCount} saving…)` : `Save Last ${replayDuration}s`}
            </Text>
          </Pressable>
          {bufferActive ? (
            <Pressable
              accessibilityRole="button"
              disabled={bufferRequest !== 'none' || bufferStatus?.state === 'stopping'}
              onPress={onStopBuffer}
              style={({ pressed }) => [
                styles.button,
                styles.bufferButton,
                (pressed || bufferRequest !== 'none') && styles.buttonPressed,
              ]}
            >
              <Text style={styles.buttonText}>
                {bufferRequest === 'starting'
                  ? 'Starting…'
                  : bufferRequest === 'stopping' || bufferStatus?.state === 'stopping'
                    ? 'Stopping…'
                    : 'Stop Buffer'}
              </Text>
            </Pressable>
          ) : (
            <Pressable
              accessibilityRole="button"
              disabled={!cameraReady || phase !== 'idle'}
              onPress={onStartBuffer}
              style={({ pressed }) => [
                styles.button,
                styles.bufferButton,
                (pressed || !cameraReady || phase !== 'idle') && styles.buttonDisabled,
              ]}
            >
              <Text style={styles.buttonText}>Start Buffer</Text>
            </Pressable>
          )}
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
              disabled={!canStartRecording}
              onPress={onStartRecording}
              style={({ pressed }) => [
                styles.button,
                styles.recordButton,
                (pressed || !canStartRecording) && styles.buttonDisabled,
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
      style={[
        styles.banner,
        banner.kind === 'error' ? styles.bannerError : banner.kind === 'info' ? styles.bannerInfo : styles.bannerSuccess,
      ]}
    >
      <Text style={styles.bannerText}>{banner.text}</Text>
    </Pressable>
  );
}

/** Minimal replay-buffer diagnostics (Task 4A test UI). */
function BufferPanel({ status }: { status: BufferStatus }) {
  const last = status.lastSegment;
  const lines = [
    formatBufferSummary(status),
    `${status.codec.toUpperCase()} ${status.width}×${status.height} · ${Math.round(status.fps)} fps target · ${status.measuredFps.toFixed(1)} fps measured`,
    last
      ? `Last segment: ${last.durationSeconds.toFixed(2)} s · ${last.frameCount} frames · max gap ${last.maxFrameIntervalMs.toFixed(1)} ms`
      : 'Last segment: none yet',
    `Dropped ${status.captureDroppedFrames} (camera) + ${status.writerDroppedFrames} (encoder) · missing ${status.missingFrames}`,
    `Pauses ${status.gaps} · segment gaps ${status.segmentGaps} · overlaps ${status.segmentOverlaps} · failed ${status.failedSegments}`,
    `Disk ${formatMB(status.diskBytes)} in ${status.fileCount} files · RAM ${formatMB(status.memoryBytes)} · expired ${status.expiredSegments}`,
  ];
  if (status.message) lines.push(status.message);
  // Amber when continuity or file problems were detected (camera drops are shown but not flagged).
  const hasProblems =
    status.segmentGaps + status.segmentOverlaps + status.orderingErrors + status.failedSegments + status.outOfOrderFrames > 0;
  return (
    <View
      style={[
        styles.bufferPanel,
        hasProblems && styles.bufferPanelWarning,
        status.state === 'error' && styles.bufferPanelError,
      ]}
    >
      {lines.map((line, i) => (
        <Text key={i} style={[styles.bufferText, i === 0 && styles.bufferTitle]}>
          {line}
        </Text>
      ))}
    </View>
  );
}

function formatBufferSummary(s: BufferStatus): string {
  return [
    `BUFFER ${s.state.toUpperCase()}`,
    `${s.segmentCount} segments`,
    `${s.bufferedSeconds.toFixed(1)} s`,
    formatMB(s.storageBytes),
  ].join(' · ');
}

function formatMB(bytes: number): string {
  return `${(bytes / 1_048_576).toFixed(0)} MB`;
}

function describeReplaySaved(info: ReplayInfo): Banner {
  const details = [
    `${info.durationSeconds.toFixed(2)} s`,
    `${info.width}×${info.height}`,
    info.codec.toUpperCase(),
    formatMB(info.sizeBytes),
    `export ${info.exportSeconds.toFixed(1)} s`,
  ].join(' · ');
  return {
    kind: 'success',
    text: `Saved ${info.fileName}\n${details}${info.note ? `\n${info.note}` : ''}`,
  };
}

function describeRecordingFinished(event: RecordingFinishedEvent): Banner {
  if (!event.ok) {
    return { kind: 'error', text: `Recording failed: ${event.message}` };
  }
  const details = [
    formatDuration(event.durationSeconds),
    `${event.width}×${event.height}`,
    `${Math.round(event.frameRate)} fps`,
    event.codec.toUpperCase(),
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

function formatSettings(s: CaptureSettings): string {
  return `${s.width}×${s.height} · ${Math.round(s.fps)} fps · ${s.codec.toUpperCase()}`;
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
  settingsText: {
    color: '#fff',
    fontSize: 13,
    backgroundColor: 'rgba(0,0,0,0.45)',
    paddingVertical: 4,
    paddingHorizontal: 10,
    borderRadius: 6,
    overflow: 'hidden',
    textAlign: 'center',
    fontVariant: ['tabular-nums'],
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
  bufferButton: {
    backgroundColor: '#0a5fb4',
    minWidth: 220,
    alignItems: 'center',
    marginBottom: 10,
  },
  bufferPanel: {
    marginTop: 8,
    alignSelf: 'stretch',
    backgroundColor: 'rgba(0,0,0,0.55)',
    borderRadius: 8,
    paddingVertical: 6,
    paddingHorizontal: 10,
  },
  replayButton: {
    backgroundColor: '#e07a00',
    minWidth: 220,
    alignItems: 'center',
    marginBottom: 10,
  },
  durationRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'center',
    marginBottom: 10,
  },
  durationChip: {
    paddingVertical: 6,
    paddingHorizontal: 10,
    marginHorizontal: 3,
    marginVertical: 3,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.6)',
    backgroundColor: 'rgba(0,0,0,0.45)',
  },
  durationChipSelected: {
    backgroundColor: '#fff',
    borderColor: '#fff',
  },
  durationText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  durationTextSelected: {
    color: '#111',
  },
  bannerInfo: {
    backgroundColor: 'rgba(40,40,40,0.9)',
  },
  bufferPanelWarning: {
    backgroundColor: 'rgba(160,100,0,0.85)',
  },
  bufferPanelError: {
    backgroundColor: 'rgba(179,38,30,0.8)',
  },
  bufferText: {
    color: '#fff',
    fontSize: 12,
    fontVariant: ['tabular-nums'],
  },
  bufferTitle: {
    fontSize: 13,
    fontWeight: '700',
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
