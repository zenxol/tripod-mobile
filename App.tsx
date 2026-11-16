import { StatusBar } from 'expo-status-bar';
import { Alert, Pressable, StyleSheet, Text, View } from 'react-native';

export default function App() {
  // Placeholder only: camera capture comes in a later task (native Swift module).
  const onStartCamera = () => Alert.alert('Coming soon', 'Camera recording is not implemented yet.');

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Tripod</Text>
      <Text style={styles.subtitle}>Pickleball Instant Replay</Text>
      <Pressable
        accessibilityRole="button"
        onPress={onStartCamera}
        style={({ pressed }) => [styles.button, pressed && styles.buttonPressed]}
      >
        <Text style={styles.buttonText}>Start Camera</Text>
      </Pressable>
      <StatusBar style="auto" />
    </View>
  );
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
});
