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
import { editVideo, addProgressListener, cancelEdit } from 'expo-media-edit';

// Subscribe to progress before starting
const sub = addProgressListener(({ progress }) => {
  console.log(`Progress: ${Math.round(progress * 100)}%`);
});

const outputUri = await editVideo({
  inputUri: 'file:///path/to/video.mp4',
  trim: { startMs: 0, endMs: 15000 },
  quality: 'medium',
  overlays: [
    {
      type: 'text',
      content: 'Hello World',
      x: 0.05,
      y: 0.85,
      anchor: 'topLeft',
      textAlign: 'left',
      paddingX: 16,
      paddingY: 8,
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

sub.remove(); // always clean up the listener
```

To cancel an in-progress edit:

```ts
await cancelEdit(); // the editVideo() promise rejects with code "CANCELLED"
```

## API

### `editVideo(job: EditJob): Promise<string>`

Edit a video and return the URI of the output file.

```ts
type EditJob = {
  inputUri: string;       // Local file URI (file://...) or https:// URL
  outputUri?: string;     // Optional output path; defaults to a temp file
  trim?: {
    startMs: number;      // Start time in milliseconds
    endMs: number;        // End time in milliseconds
  };
  overlays?: OverlayItem[];
  audio?: AudioMix;
  quality?: 'low' | 'medium' | 'high'; // Default: 'high'
};

type OverlayItem =
  | {
      type: 'text';
      content: string;
      x: number;              // 0.0–1.0 relative to video width
      y: number;              // 0.0–1.0 relative to video height
      anchor: 'topLeft' | 'center';        // how x/y are interpreted (required, 0.8.0)
      textAlign: 'left' | 'center' | 'right'; // text alignment within the layer (required, 0.8.0)
      paddingX: number;       // px at 1080-height reference; scaled like fontSize (required, 0.8.0)
      paddingY: number;       // px at 1080-height reference; scaled like fontSize (required, 0.8.0)
      fontSize?: number;      // Default: 32
      color?: string;         // CSS hex, e.g. '#FFFFFF'. Default: '#FFFFFF'
      fontWeight?: 'normal' | 'bold';
      backgroundColor?: string;
      rotation?: number;      // degrees, default 0
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

### `addProgressListener(callback: (event: ProgressEvent) => void): Subscription`

Subscribe to progress events during `editVideo()`. Returns a subscription with a `remove()` method.

```ts
type ProgressEvent = { progress: number }; // 0.0–1.0
```

Always call `sub.remove()` after `editVideo()` resolves or rejects.

### `cancelEdit(): Promise<void>`

Cancel an in-progress `editVideo()` call. The `editVideo` promise rejects with error code `"CANCELLED"`.

### `extractAudio(uri: string): Promise<string>`

Strip the audio track from a video file into a temporary `.m4a`. Returns a `file://` URI pointing to the extracted audio. Useful when feeding video to APIs that only accept raw audio formats — e.g. iOS `SFSpeechRecognizer` via `AVAudioFile`, which can't read `.MOV`/`.MP4` containers directly but reads the extracted `.m4a` fine.

- **iOS:** `AVAssetExportSession` with `AVAssetExportPresetAppleM4A`.
- **Android:** `MediaExtractor` + `MediaMuxer` (stream-copy, no re-encode).
- Rejects with `NO_AUDIO_TRACK` if the source has no audio track.

```ts
const m4aUri = await extractAudio(videoUri);
// pass m4aUri to whatever audio-only API needs it
```

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
- **Overlays**: Frame-by-frame decode via `MediaMetadataRetriever`, Canvas draw, YUV420 re-encode via `MediaCodec`. Quality controlled via bitrate (low: 1Mbps, medium: 2Mbps, high: 4Mbps).
- **Audio**: Stream copy when `volume == 1.0`; PCM decode → scale → AAC re-encode for other volume values. Rotation metadata preserved via `MediaMuxer.setOrientationHint()`.

## Known limitations

- Background processing is not supported (the app must stay in the foreground during editing).
- Android audio mixing does not support simultaneous multi-track volume scaling (original + music both at non-1.0 volume in the same output file). Each track is scaled independently.

## Changelog

### 0.8.1

- **iOS fix**: Time-ranged text/image overlays with both `startMs` and `endMs` stayed visible until the end of the video instead of disappearing at `endMs`. The opacity keyframe animation held the visible value past `endMs` because the third value in a discrete-mode `CAKeyframeAnimation` was still `opacity` instead of `0`. Critical for word-by-word subtitles where overlays accumulated on screen.

### 0.8.0

- **Breaking change — text overlays require explicit layout.** Every text overlay must now specify four fields the native side previously guessed: `anchor` (`'topLeft' | 'center'`), `textAlign` (`'left' | 'center' | 'right'`), `paddingX` (number), and `paddingY` (number). The native compositors always measure the rendered text and size the layer to `ceil(textWidth) + 2*paddingX` × `ceil(textHeight) + 2*paddingY`. `paddingX` / `paddingY` are in pixels at a 1080-height reference and scale per platform the same way `fontSize` does. With `anchor: 'topLeft'`, `x`/`y` are the layer's top-left corner; with `anchor: 'center'`, they are the layer's geometric center. The validator throws `editVideo: overlays[i] must include anchor / textAlign / paddingX / paddingY` if any field is missing.

  ```ts
  overlays: [
    {
      type: 'text',
      content: 'Hello',
      x: 0.5, y: 0.5,
      anchor: 'center',
      textAlign: 'center',
      paddingX: 12,
      paddingY: 6,
      fontSize: 48,
      backgroundColor: '#000000B3',
    },
  ]
  ```

### 0.7.2

- **iOS text overlays — breaking change**: `x` and `y` are now the layer's **center**, not its top-left corner. The text layer is sized tightly to the rendered string (instead of a fixed 90%×8-line rectangle), so backgrounds wrap snugly around the text and `alignmentMode` is centered. Existing overlays at `x: 0.5, y: 0.5` are now visually centered instead of starting at the canvas midpoint.

### 0.7.1

- **iOS fix**: Time-ranged overlays (`startMs` / `endMs`) were never visible in the exported video. The opacity keyframe animation now sets `beginTime = AVCoreAnimationBeginTimeAtZero` so Core Animation maps it to composition time instead of `CACurrentMediaTime()`.

### 0.7.0

- `extractAudio(uri)` — exports the audio track of a video to an `.m4a` file.

## License

MIT
