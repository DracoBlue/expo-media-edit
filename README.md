# expo-media-edit

Native video editing for Expo apps. Trim, overlay text/images, and mix audio — fully on-device via AVFoundation (iOS) and MediaCodec (Android). No FFmpeg, no cloud rendering.

## Requirements

- iOS 16+
- Android API 26+
- Expo SDK 54+
- Requires a native build (EAS Build or `expo run:ios` / `expo run:android`). Does **not** work in Expo Go.

## Installation

```sh
npx expo install expo-media-edit
```

Then rebuild your native app:

```sh
# iOS
npx expo run:ios
# or
eas build --platform ios

# Android
npx expo run:android
```

## Usage

```ts
import { editVideo } from 'expo-media-edit';

const outputUri = await editVideo({
  inputUri: 'file:///path/to/video.mp4',
  trim: { startMs: 0, endMs: 15000 },
  overlays: [
    {
      type: 'text',
      content: 'Hello World',
      x: 0.05,
      y: 0.85,
      fontSize: 48,
      color: '#FFFFFF',
      fontWeight: 'bold',
    },
    {
      type: 'image',
      uri: 'file:///path/to/logo.png',
      x: 0.7,
      y: 0.05,
      width: 0.2,
      height: 0.1,
      opacity: 0.9,
    },
  ],
  audio: {
    uri: 'file:///path/to/music.mp3',
    volume: 0.8,
    originalVolume: 0.2,
    trimToVideo: true,
  },
});
```

## API

### `editVideo(job: EditJob): Promise<string>`

Edit a video and return the URI of the output file.

```ts
type EditJob = {
  inputUri: string;       // Local file URI (file://...)
  outputUri?: string;     // Optional output path; defaults to a temp file
  trim?: {
    startMs: number;      // Start time in milliseconds
    endMs: number;        // End time in milliseconds
  };
  overlays?: OverlayItem[];
  audio?: AudioMix;
};

type OverlayItem =
  | {
      type: 'text';
      content: string;
      x: number;              // 0.0–1.0 relative to video width
      y: number;              // 0.0–1.0 relative to video height
      fontSize?: number;      // Default: 32
      color?: string;         // CSS hex, e.g. '#FFFFFF'. Default: '#FFFFFF'
      fontWeight?: 'normal' | 'bold';
      backgroundColor?: string;
      startMs?: number;       // Show from this time (default: 0)
      endMs?: number;         // Hide after this time (default: video end)
    }
  | {
      type: 'image';
      uri: string;            // Local image URI
      x: number;
      y: number;
      width: number;          // 0.0–1.0 relative to video width
      height: number;         // 0.0–1.0 relative to video height
      opacity?: number;       // 0.0–1.0. Default: 1.0
      startMs?: number;
      endMs?: number;
    };

type AudioMix = {
  uri: string;                // Local audio URI (.mp3, .m4a, .wav)
  volume?: number;            // Music track volume 0.0–1.0. Default: 1.0
  originalVolume?: number;    // Original audio volume 0.0–1.0. Default: 0.0
  startMs?: number;           // Music start offset in ms. Default: 0
  trimToVideo?: boolean;      // Cut music at video end. Default: true
};
```

### `getVideoInfo(uri: string): Promise<VideoInfo>`

Read metadata about a video file.

```ts
type VideoInfo = {
  durationMs: number;
  width: number;
  height: number;
  fps: number;
  fileSize: number;   // Bytes
  codec?: string;
};
```

### `generateThumbnail(uri: string, timeMs: number, options?: { width?: number; height?: number }): Promise<string>`

Extract a JPEG thumbnail from a video at the given timestamp. Returns a `file://` URI.

### `cleanTempFiles(): Promise<number>`

Delete all temporary files created by expo-media-edit. Returns the number of files deleted.

## Platform notes

### iOS

Uses AVFoundation:
- **Trim**: `AVAssetExportSession` with a time range — lossless stream copy.
- **Overlays**: `AVVideoCompositionCoreAnimationTool` with `CATextLayer` / `CALayer` burn-in.
- **Audio**: `AVMutableAudioMixInputParameters` for volume control; additional `AVMutableCompositionTrack` for music.

### Android

Uses MediaCodec + MediaMuxer:
- **Trim**: `MediaExtractor` + `MediaMuxer` stream copy (no re-encode).
- **Overlays**: Frame-by-frame decode via `MediaMetadataRetriever`, Canvas draw, YUV420 re-encode via `MediaCodec`.
- **Audio**: `MediaExtractor` stream copy for original audio and music track.

> **Note**: Android audio volume scaling via stream copy is not supported (requires PCM decode/re-encode). Both tracks are copied at their encoded levels. Full volume mixing is planned for v0.2.

## Known limitations

- Remote URLs (HTTPS) are not supported — local `file://` URIs only.
- Video rotation metadata is not applied during overlay compositing on Android.
- Background processing is not supported.
- Progress callbacks are not yet implemented.

## License

MIT
