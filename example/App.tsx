import React, { useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Button,
  Image,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { editVideo, generateThumbnail, getVideoInfo, cleanTempFiles } from 'expo-media-edit';

export default function App() {
  const [videoUri, setVideoUri] = useState('');
  const [audioUri, setAudioUri] = useState('');
  const [overlayText, setOverlayText] = useState('Hello World');
  const [trimStart, setTrimStart] = useState('0');
  const [trimEnd, setTrimEnd] = useState('15000');
  const [outputUri, setOutputUri] = useState('');
  const [thumbnailUri, setThumbnailUri] = useState('');
  const [videoInfo, setVideoInfo] = useState<string>('');
  const [loading, setLoading] = useState(false);

  const handleEdit = async () => {
    if (!videoUri) {
      Alert.alert('Error', 'Please enter a video URI');
      return;
    }
    setLoading(true);
    try {
      const result = await editVideo({
        inputUri: videoUri,
        trim: {
          startMs: parseInt(trimStart, 10),
          endMs: parseInt(trimEnd, 10),
        },
        overlays: overlayText
          ? [
              {
                type: 'text',
                content: overlayText,
                x: 0.05,
                y: 0.85,
                fontSize: 48,
                color: '#FFFFFF',
                fontWeight: 'bold',
                backgroundColor: 'rgba(0,0,0,0.4)',
              },
            ]
          : [],
        audio: audioUri
          ? {
              uri: audioUri,
              volume: 0.8,
              originalVolume: 0.2,
              trimToVideo: true,
            }
          : undefined,
      });
      setOutputUri(result);
      Alert.alert('Done', `Output: ${result}`);
    } catch (e: unknown) {
      Alert.alert('Error', e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  const handleGetInfo = async () => {
    if (!videoUri) return;
    setLoading(true);
    try {
      const info = await getVideoInfo(videoUri);
      setVideoInfo(
        `Duration: ${Math.round(info.durationMs)}ms\n` +
          `Size: ${info.width}×${info.height}\n` +
          `FPS: ${info.fps}\n` +
          `File size: ${(info.fileSize / 1024).toFixed(1)} KB` +
          (info.codec ? `\nCodec: ${info.codec}` : '')
      );
    } catch (e: unknown) {
      Alert.alert('Error', e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  const handleThumbnail = async () => {
    if (!videoUri) return;
    setLoading(true);
    try {
      const uri = await generateThumbnail(videoUri, parseInt(trimStart, 10));
      setThumbnailUri(uri);
    } catch (e: unknown) {
      Alert.alert('Error', e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  const handleCleanup = async () => {
    const count = await cleanTempFiles();
    Alert.alert('Cleanup', `Deleted ${count} temp files`);
  };

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>expo-media-edit</Text>

        <Text style={styles.label}>Video URI</Text>
        <TextInput
          style={styles.input}
          value={videoUri}
          onChangeText={setVideoUri}
          placeholder="file:///path/to/video.mp4"
          autoCapitalize="none"
        />

        <Text style={styles.label}>Trim start (ms)</Text>
        <TextInput
          style={styles.input}
          value={trimStart}
          onChangeText={setTrimStart}
          keyboardType="numeric"
        />

        <Text style={styles.label}>Trim end (ms)</Text>
        <TextInput
          style={styles.input}
          value={trimEnd}
          onChangeText={setTrimEnd}
          keyboardType="numeric"
        />

        <Text style={styles.label}>Text overlay</Text>
        <TextInput
          style={styles.input}
          value={overlayText}
          onChangeText={setOverlayText}
          placeholder="Overlay text (leave empty to skip)"
        />

        <Text style={styles.label}>Audio URI (optional)</Text>
        <TextInput
          style={styles.input}
          value={audioUri}
          onChangeText={setAudioUri}
          placeholder="file:///path/to/music.mp3"
          autoCapitalize="none"
        />

        <View style={styles.row}>
          <Button title="Get Info" onPress={handleGetInfo} />
          <Button title="Thumbnail" onPress={handleThumbnail} />
          <Button title="Clean Temp" onPress={handleCleanup} />
        </View>

        <View style={styles.editButton}>
          {loading ? (
            <ActivityIndicator />
          ) : (
            <Button title="Edit Video" onPress={handleEdit} color="#007AFF" />
          )}
        </View>

        {videoInfo !== '' && (
          <View style={styles.result}>
            <Text style={styles.resultLabel}>Video info:</Text>
            <Text style={styles.resultText}>{videoInfo}</Text>
          </View>
        )}

        {thumbnailUri !== '' && (
          <View style={styles.result}>
            <Text style={styles.resultLabel}>Thumbnail:</Text>
            <Image source={{ uri: thumbnailUri }} style={styles.thumbnail} resizeMode="contain" />
          </View>
        )}

        {outputUri !== '' && (
          <View style={styles.result}>
            <Text style={styles.resultLabel}>Output:</Text>
            <Text style={styles.resultText} selectable>{outputUri}</Text>
          </View>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#fff' },
  content: { padding: 16 },
  title: { fontSize: 24, fontWeight: 'bold', marginBottom: 24, textAlign: 'center' },
  label: { fontSize: 13, color: '#666', marginTop: 12, marginBottom: 4 },
  input: {
    borderWidth: 1,
    borderColor: '#ccc',
    borderRadius: 8,
    padding: 10,
    fontSize: 14,
    backgroundColor: '#f9f9f9',
  },
  row: { flexDirection: 'row', justifyContent: 'space-around', marginTop: 20 },
  editButton: { marginTop: 16 },
  result: {
    marginTop: 20,
    padding: 12,
    backgroundColor: '#f0f0f0',
    borderRadius: 8,
  },
  resultLabel: { fontWeight: '600', marginBottom: 4 },
  resultText: { fontSize: 13, color: '#333' },
  thumbnail: { width: '100%', height: 200, marginTop: 8 },
});
