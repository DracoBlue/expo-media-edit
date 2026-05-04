import React, { useState, useRef, useEffect } from 'react';
import {
  ActivityIndicator,
  Alert,
  Button,
  Image,
  Linking,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import {
  editVideo,
  cancelEdit,
  addProgressListener,
  generateThumbnail,
  getVideoInfo,
  cleanTempFiles,
  type EditJob,
} from 'expo-media-edit';

// Big Buck Bunny — (c) copyright 2008, Blender Foundation / www.bigbuckbunny.org
// Licensed under Creative Commons Attribution 3.0 Unported (CC BY 3.0)
// https://creativecommons.org/licenses/by/3.0/
const BBB_VIDEO_URL =
  'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_2MB.mp4';

export default function App() {
  const [videoUri, setVideoUri] = useState(BBB_VIDEO_URL);
  const [audioUri, setAudioUri] = useState('');
  const [overlayText, setOverlayText] = useState('Big Buck Bunny');
  const [trimStart, setTrimStart] = useState('0');
  const [trimEnd, setTrimEnd] = useState('8000');
  const [quality, setQuality] = useState<'low' | 'medium' | 'high'>('medium');
  const [outputUri, setOutputUri] = useState('');
  const [thumbnailUri, setThumbnailUri] = useState('');
  const [videoInfo, setVideoInfo] = useState('');
  const [loading, setLoading] = useState(false);
  const [progress, setProgress] = useState(0);
  const progressSubRef = useRef<{ remove: () => void } | null>(null);

  useEffect(() => () => { progressSubRef.current?.remove(); }, []);

  const handleEdit = async () => {
    if (!videoUri) { Alert.alert('Error', 'Please enter a video URI'); return; }
    setLoading(true);
    setProgress(0);
    setOutputUri('');

    progressSubRef.current = addProgressListener(({ progress: p }) => setProgress(p));

    try {
      const job: EditJob = {
        inputUri: videoUri,
        trim: { startMs: parseInt(trimStart, 10), endMs: parseInt(trimEnd, 10) },
        quality,
        overlays: overlayText ? [
          {
            type: 'text',
            content: overlayText,
            x: 0.05, y: 0.85,
            fontSize: 48,
            color: '#FFFFFF',
            fontWeight: 'bold',
            backgroundColor: '#000000AA',
          },
          {
            type: 'text',
            content: '© Blender Foundation',
            x: 0.05, y: 0.05,
            fontSize: 24,
            color: '#CCCCCC',
            startMs: 0,
            endMs: 3000,
          },
        ] : [],
        audio: audioUri ? { uri: audioUri, volume: 0.8, originalVolume: 0.3, trimToVideo: true } : undefined,
      };
      const result = await editVideo(job);
      setOutputUri(result);
      setProgress(1);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (!msg.includes('CANCELLED')) Alert.alert('Error', msg);
    } finally {
      progressSubRef.current?.remove();
      progressSubRef.current = null;
      setLoading(false);
    }
  };

  const handleCancel = async () => { await cancelEdit(); };

  const handleGetInfo = async () => {
    if (!videoUri) return;
    setLoading(true);
    try {
      const info = await getVideoInfo(videoUri);
      setVideoInfo(
        `Duration: ${Math.round(info.durationMs)}ms\n` +
        `Size: ${info.width}×${info.height}\n` +
        `FPS: ${info.fps.toFixed(1)}\n` +
        `File size: ${(info.fileSize / 1024).toFixed(1)} KB` +
        (info.codec ? `\nCodec: ${info.codec}` : '')
      );
    } catch (e: unknown) {
      Alert.alert('Error', e instanceof Error ? e.message : String(e));
    } finally { setLoading(false); }
  };

  const handleThumbnail = async () => {
    if (!videoUri) return;
    setLoading(true);
    try {
      const uri = await generateThumbnail(videoUri, parseInt(trimStart, 10));
      setThumbnailUri(uri);
    } catch (e: unknown) {
      Alert.alert('Error', e instanceof Error ? e.message : String(e));
    } finally { setLoading(false); }
  };

  const handleCleanup = async () => {
    const count = await cleanTempFiles();
    Alert.alert('Cleanup', `Deleted ${count} temp files`);
  };

  const qualityButtons: Array<'low' | 'medium' | 'high'> = ['low', 'medium', 'high'];

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>expo-media-edit</Text>
        <Text style={styles.subtitle}>v0.2.0 demo</Text>

        <Text style={styles.label}>Video URI</Text>
        <TextInput
          style={styles.input}
          value={videoUri}
          onChangeText={setVideoUri}
          placeholder="file:///path/to/video.mp4 or https://..."
          autoCapitalize="none"
          autoCorrect={false}
        />
        <Text style={styles.hint}>
          Default: Big Buck Bunny 10s clip (CC BY 3.0 — Blender Foundation)
        </Text>

        <View style={styles.row}>
          <View style={styles.halfField}>
            <Text style={styles.label}>Trim start (ms)</Text>
            <TextInput style={styles.input} value={trimStart} onChangeText={setTrimStart} keyboardType="numeric" />
          </View>
          <View style={styles.halfField}>
            <Text style={styles.label}>Trim end (ms)</Text>
            <TextInput style={styles.input} value={trimEnd} onChangeText={setTrimEnd} keyboardType="numeric" />
          </View>
        </View>

        <Text style={styles.label}>Text overlay (empty to skip)</Text>
        <TextInput style={styles.input} value={overlayText} onChangeText={setOverlayText} />

        <Text style={styles.label}>Audio URI (optional)</Text>
        <TextInput
          style={styles.input}
          value={audioUri}
          onChangeText={setAudioUri}
          placeholder="file:///path/to/music.mp3"
          autoCapitalize="none"
          autoCorrect={false}
        />

        <Text style={styles.label}>Quality</Text>
        <View style={styles.qualityRow}>
          {qualityButtons.map((q) => (
            <Button
              key={q}
              title={q}
              color={quality === q ? '#007AFF' : '#aaa'}
              onPress={() => setQuality(q)}
            />
          ))}
        </View>

        <View style={styles.row}>
          <Button title="Get Info" onPress={handleGetInfo} />
          <Button title="Thumbnail" onPress={handleThumbnail} />
          <Button title="Clean Temp" onPress={handleCleanup} />
        </View>

        {loading ? (
          <View style={styles.progressContainer}>
            <View style={[styles.progressBar, { width: `${Math.round(progress * 100)}%` }]} />
            <Text style={styles.progressText}>{Math.round(progress * 100)}%</Text>
            <Button title="Cancel" color="#FF3B30" onPress={handleCancel} />
          </View>
        ) : (
          <View style={styles.editButton}>
            <Button title="Edit Video" onPress={handleEdit} color="#007AFF" />
          </View>
        )}

        {videoInfo !== '' && (
          <View style={styles.result}>
            <Text style={styles.resultLabel}>Video info:</Text>
            <Text style={styles.resultText}>{videoInfo}</Text>
          </View>
        )}

        {thumbnailUri !== '' && (
          <View style={styles.result}>
            <Text style={styles.resultLabel}>Thumbnail at {trimStart}ms:</Text>
            <Image source={{ uri: thumbnailUri }} style={styles.thumbnail} resizeMode="contain" />
          </View>
        )}

        {outputUri !== '' && (
          <View style={styles.result}>
            <Text style={styles.resultLabel}>Output:</Text>
            <Text style={styles.resultText} selectable>{outputUri}</Text>
          </View>
        )}

        <View style={styles.credits}>
          <Text style={styles.creditsText}>
            Test video: Big Buck Bunny {'\n'}
            © 2008 Blender Foundation / www.bigbuckbunny.org{'\n'}
            Licensed under CC BY 3.0
          </Text>
          <Button
            title="Open bigbuckbunny.org"
            onPress={() => Linking.openURL('https://www.bigbuckbunny.org')}
            color="#666"
          />
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  content: { padding: 16, paddingBottom: 40 },
  title: { fontSize: 24, fontWeight: 'bold', textAlign: 'center' },
  subtitle: { fontSize: 14, color: '#666', textAlign: 'center', marginBottom: 20 },
  label: { fontSize: 13, color: '#666', marginTop: 12, marginBottom: 4 },
  hint: { fontSize: 11, color: '#aaa', marginTop: 2 },
  input: {
    borderWidth: 1, borderColor: '#ccc', borderRadius: 8,
    padding: 10, fontSize: 14, backgroundColor: '#f9f9f9',
  },
  row: { flexDirection: 'row', justifyContent: 'space-around', marginTop: 16, gap: 12 },
  halfField: { flex: 1 },
  qualityRow: { flexDirection: 'row', gap: 12, marginTop: 4 },
  editButton: { marginTop: 16 },
  progressContainer: {
    marginTop: 16, alignItems: 'center', gap: 8,
    backgroundColor: '#f0f0f0', borderRadius: 8, padding: 12,
  },
  progressBar: {
    height: 8, backgroundColor: '#007AFF', borderRadius: 4,
    alignSelf: 'flex-start', minWidth: 4,
  },
  progressText: { fontSize: 13, color: '#333' },
  result: { marginTop: 20, padding: 12, backgroundColor: '#f0f0f0', borderRadius: 8 },
  resultLabel: { fontWeight: '600', marginBottom: 4 },
  resultText: { fontSize: 13, color: '#333' },
  thumbnail: { width: '100%', height: 200, marginTop: 8 },
  credits: {
    marginTop: 32, padding: 16, backgroundColor: '#f8f8f8',
    borderRadius: 8, alignItems: 'center', gap: 8,
  },
  creditsText: { fontSize: 12, color: '#666', textAlign: 'center', lineHeight: 18 },
});
