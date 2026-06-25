# expo-media-edit

Native video composer for Expo apps. Define a Project, render it
identically in a live preview view and an exported MP4 — fully
on-device via AVFoundation (iOS) and androidx.media3 (Android). No
FFmpeg, no cloud rendering.

> 0.14.0 is a breaking redesign. See [CHANGELOG.md](./CHANGELOG.md)
> for the migration from the 0.13.x `editVideo(EditJob)` API.

## Requirements

- iOS 16+
- Android API 26+
- Expo SDK 54+
- Requires a native build (EAS Build or `expo run:ios` / `expo
  run:android`). Does **not** work in Expo Go.

## Installation

```sh
npx expo install expo-media-edit
```

Then rebuild your native app:

```sh
npx expo run:ios     # or: eas build --platform ios
npx expo run:android # or: eas build --platform android
```

## Concepts

A `Project` is a pure-data, JSON-serialisable document describing
tracks (video / audio / overlay), clips inside each track, transitions
between video clips, and overlays. The library exposes ONE compiler
that turns a Project into a native composition. That composition
feeds BOTH:

- `<MediaPreview project={...} />` for live in-app preview, AND
- `exportProject(project)` for the final MP4 render

Same compiler, same composition → preview pixels equal export pixels.

## Usage

```ts
import {
  createProject, applyEdit, exportProject,
  addProgressListener, MediaPreview, type Project,
} from 'expo-media-edit';

// Build a Project (pure data — store/serialise/diff freely).
const project: Project = createProject({
  canvasSize: { width: 1080, height: 1920 },
  tracks: [
    { kind: 'video', id: 'v', clips: [{
      id: 'c1',
      sourceUri: 'file:///path/to/clip.mp4',
      sourceRange: { startMs: 0, endMs: 5000 },
      timelineRange: { startMs: 0, endMs: 5000 },
    }] },
    { kind: 'audio', id: 'a', clips: [{
      id: 'm1',
      sourceUri: 'file:///path/to/music.mp3',
      sourceRange: { startMs: 0, endMs: 5000 },
      timelineRange: { startMs: 0, endMs: 5000 },
      volume: 0.8, trimToVideo: true,
    }] },
    { kind: 'overlay', id: 'o', items: [{
      id: 'txt',
      kind: 'text', content: 'Hello',
      x: 0.5, y: 0.88, anchor: 'center', textAlign: 'center',
      paddingX: 16, paddingY: 8, fontSize: 48,
      color: '#FFFFFF', fontWeight: 'bold',
    }] },
  ],
});

// Live preview — controlled time + playing from React state.
<MediaPreview
  project={project}
  time={currentTimeMs}
  playing={isPlaying}
  onTime={({ nativeEvent }) => setCurrentTimeMs(nativeEvent.ms)}
  onReady={({ nativeEvent }) => console.log('duration', nativeEvent.durationMs)}
  style={{ width: 360, height: 640 }}
/>

// Final export — same Project, same compiler, identical pixels.
const sub = addProgressListener(({ progress }) => {
  console.log(`Export: ${Math.round(progress * 100)}%`);
});
const outputUri = await exportProject(project, undefined, { quality: 'medium' });
sub.remove();
```

To cancel an in-flight export:

```ts
await cancelExport(); // exportProject() promise rejects with code "CANCELLED"
```

## API

See `src/project.ts` for the complete schema (≈250 LOC) — it's the
authoritative type definition. Highlights:

- `createProject(input)` — make a new Project. Sets `schemaVersion`,
  generates an id if you didn't, computes `durationMs` from tracks.
- `applyEdit(project, op)` — immutable mutation. `op` is a
  discriminated union (`addVideoClip` / `removeClip` /
  `replaceOverlay` / …). Returns a new Project; original is untouched.
  Pair with your own undo stack.
- `validateProject(project)` — structural check; returns
  `{ ok: true }` or `{ ok: false; reason }`. Run before crossing the
  JS↔native bridge.
- `exportProject(project, outputUri?, opts?)` — render to MP4.
- `cancelExport()` — cancel the in-flight export.
- `addProgressListener(cb)` — subscribe to progress events
  (`{ progress: 0..1 }`) during an export.
- `getVideoInfo(uri)` — read duration / dims / fps / codec / size.
- `generateThumbnail(uri, timeMs, opts?)` — JPEG frame extraction.
- `extractAudio(uri)` — pull the audio track into a temp .m4a (useful
  for SFSpeechRecognizer file-based recognition).
- `cleanTempFiles()` — delete all expo-media-edit temp files.

### Text overlay knobs (all preserved from 0.11/0.12)

All the visual knobs from 0.11.0 (`strokeColor`/`strokeWidth`,
`shadowColor`/`shadowRadius`/`shadowOpacity`, `fontStyle: italic`,
`fontFamily: monospace`) and 0.12.0 (karaoke
`highlightStart`/`highlightLength`/`highlightColor` over an explicit
UTF-16 char range) are kept verbatim on `TextOverlayClip`.

### Supported transitions

- `cut` — hard cut between clips
- `fade` — true crossfade (alpha-ramp blend between outgoing +
  incoming clips during the overlap window). Implemented natively
  on both platforms: iOS via `setOpacityRamp` on overlapping tracks,
  Android via multi-sequence Composition with `AlphaScaleEffect` (a
  GlEffect that multiplies output alpha per frame).
- `fadeToBlack` — fade out to black, then fade in from black. No
  overlap; total timeline length = sum of clip durations.

Slide transition was removed in 0.14.0 (PO decision).

## Platform notes

### iOS

- **Compile:** `ProjectCompiler.swift` builds
  `AVMutableComposition` + `AVMutableVideoComposition` +
  `AVAudioMix`. Overlays draw into a `CALayer` tree via
  `AVVideoCompositionCoreAnimationTool` — same as 0.13.x but reshaped
  to consume `ProjectOverlayClip` directly.
- **Preview:** `<MediaPreview>` is an `AVPlayer` + `AVPlayerLayer`
  fed by the compiled composition. Zero-tolerance seek; periodic
  time observer at 30fps.
- **Export:** `AVAssetExportSession` consumes the same composition.

### Android

- **Compile:** `ProjectCompiler.kt` builds an
  `androidx.media3.transformer.Composition` with one
  `EditedMediaItemSequence` per video track plus per-audio-track
  audio-only sequences.
- **Text/image overlays go through `BitmapOverlay`, NOT media3's
  native `TextOverlay`.** The existing Canvas-based renderer
  (`OverlayBitmapRenderer.kt`) renders all overlays into a single
  full-frame bitmap per frame bucket (100ms snapping), wrapped in a
  single `BitmapOverlay` attached to the Composition's `OverlayEffect`.
  Per-glyph `Paint.setShadowLayer`, `Paint.STROKE` outlines and
  `SpannableString` karaoke highlights all keep working unchanged.
- **Preview:** `<MediaPreview>` is a `PlayerView` + `CompositionPlayer`
  fed by the same Composition.
- **Export:** `androidx.media3.transformer.Transformer`.

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).

## License

MIT
