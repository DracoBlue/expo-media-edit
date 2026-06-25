# Changelog

All notable changes to this project will be documented in this file.

## [0.14.0] - 2026-06-25

### Breaking

- **`editVideo(EditJob)` removed.** Replaced by
  `exportProject(project, outputUri?, opts?)` taking a Project document
  (see `src/project.ts`). All EditJob / OverlayItem / PlaylistItem /
  AudioMix / Transition types are gone.
- **`cancelEdit()` → `cancelExport()`.** Same lifecycle, renamed.
- **Slide transition removed.** Only `cut`, `fade`, `fadeToBlack`
  remain. media3 has no built-in push-slide and implementing one would
  have required a custom MatrixTransformation + multi-sequence
  Composition layering — out of scope for this release. PO decision
  2026-06-25.

### Added

- **`Project` schema** (`src/project.ts`) — JSON-serialisable single
  source of truth describing tracks (video/audio/overlay), clips,
  transitions, overlays with all 0.11/0.12 text knobs, and a
  duration. Includes `createProject`, `applyEdit` immutable mutations,
  `projectDurationMs`, `validateProject`.
- **`<MediaPreview project time playing ... />`** — native preview
  component. Same Project, same `ProjectCompiler` output that feeds
  `exportProject`, in an AVPlayer (iOS) / CompositionPlayer (Android).
  Preview pixels == export pixels. Emits `onTime`, `onReady`, `onError`.
- **`exportProject(project, outputUri?, opts?)`** — render a Project
  to MP4 via AVAssetExportSession (iOS) / Transformer (Android).
- **Android: adopts `androidx.media3` 1.5.1** for the composer.
  Replaces the hand-rolled MediaCodec/MediaMuxer pipeline. New deps:
  `media3-{common,exoplayer,ui,effect,transformer}`.

### Design decisions

- **Android text overlays go through `BitmapOverlay`, NOT media3's
  native `TextOverlay`.** The existing Canvas-based renderer
  (per-glyph `Paint.setShadowLayer`, `Paint.STROKE` outline pass,
  `SpannableString` + `ForegroundColorSpan` karaoke highlight,
  italic/monospace Typeface) is the only way to keep 100% fidelity
  with the iOS NSAttributedString path. media3 TextOverlay can't
  express all of those knobs cleanly. The Canvas code lives in
  `OverlayBitmapRenderer.kt`; `ProjectFrameOverlay` is a single full-
  frame BitmapOverlay subclass with a 100ms-bucket LruCache that
  re-renders on demand.
- **Audio mixing is fully native in both preview and export.** The
  Project's audio tracks (music / voice-over) play through the
  Composition's audio mix — kiesel-side `expo-audio` parallel-player
  hack goes away in the matching kiesel migration.

### Known limitations (V1, to be addressed in 0.14.1)

- **Android: inter-clip `fade` / `fadeToBlack` transitions collapse
  to `cut`.** Implementing proper crossfade between items in media3
  requires multi-sequence Composition layering with timed alpha
  overlays or a custom GlEffect. iOS handles all three transitions
  correctly via `AVMutableVideoCompositionInstruction.setOpacityRamp`.
- Per-clip volume ramps not yet emitted (clips honour `originalVolume`
  as a 0-or-1 mute toggle on Android; iOS reads the field but applies
  it as a flat per-track volume, not a ramp).
- No keyframe animations for transform/volume properties yet
  (schema supports it via `Keyframed<T>`, compilers don't read it).

### Removed (legacy files)

- iOS: `OverlayCompositor.swift`, `VideoEditor.swift`, `AudioMixer.swift`
  → replaced by `OverlayRenderer.swift` + `ProjectCompiler.swift` +
  `ProjectExporter.swift`. `SecurityValidation.swift` retained.
- Android: `OverlayCompositor.kt`, `PlaylistCompositor.kt`,
  `VideoEditor.kt`, `VideoTrimmer.kt`, `AudioMixer.kt`, `Models.kt`
  → replaced by `OverlayBitmapRenderer.kt`, `ProjectCompiler.kt`,
  `ProjectExporter.kt`, `MediaPreviewView.kt`, `ProjectModel.kt`.
  `Utils.kt` retained.

### Migration

```ts
// 0.13.x
import { editVideo, addProgressListener } from 'expo-media-edit';
const out = await editVideo({
  inputUri, trim: { startMs: 0, endMs: 5000 },
  overlays: [...], audio: { uri: musicUri, volume: 0.8 },
});

// 0.14.0
import { exportProject, createProject, addProgressListener } from 'expo-media-edit';
const project = createProject({
  canvasSize: { width: 1080, height: 1920 },
  tracks: [
    { kind: 'video', id: 'v', clips: [{
      id: 'c1', sourceUri: inputUri,
      sourceRange: { startMs: 0, endMs: 5000 },
      timelineRange: { startMs: 0, endMs: 5000 },
    }]},
    { kind: 'audio', id: 'a', clips: [{
      id: 'm1', sourceUri: musicUri,
      sourceRange: { startMs: 0, endMs: 5000 },
      timelineRange: { startMs: 0, endMs: 5000 },
      volume: 0.8,
    }]},
    { kind: 'overlay', id: 'o', items: [...] },
  ],
});
const out = await exportProject(project, undefined, { quality: 'medium' });
```

## [0.13.0] - 2026-06-18

### Changed (visual)

- iOS: `TextOverlay.shadowColor` + `shadowRadius` + `shadowOpacity`
  now render as a PER-GLYPH halo via `NSAttributedString.shadow`
  (NSShadow), not as a `CATextLayer.shadowColor` on the wrapping
  layer. Old behaviour: when the overlay also had a `backgroundColor`
  (pill), the halo wrapped the entire pill instead of the glyphs —
  PO repro 2026-06-18 with glow style + dark bg, the pill itself
  carried a soft outer halo. New behaviour matches Android's
  `Paint.setShadowLayer` and the RN-side `textShadow*` editor
  preview: halo radiates outward from each glyph and is naturally
  clipped where the bg pill begins, so the pill stays sharp.

  Visible difference for callers using shadow WITHOUT a bg: the halo
  is now per-glyph, so inter-glyph spacing carries shadow too instead
  of one big rectangular halo around the whole layer. Bumped to
  0.13.0 rather than a patch because the visual character of the
  halo changes meaningfully even though the API is unchanged.

## [0.12.1] - 2026-06-17

### Fixed

- iOS: `highlightStart` / `highlightLength` were parsed via
  `as? NSNumber`, which does not reliably catch the bridged Double
  that the Expo JS↔Swift bridge produces for plain JS numbers. The
  result was a silent no-op — the renderer received `nil` indices,
  the guard rejected the range, and karaoke highlight never painted
  even though `highlightColor` was set. Now parses through
  `as? Double` and maps to `Int`, matching the pattern used by every
  other numeric field in the file (`fontSize`, `strokeWidth`, etc.).

## [0.12.0] - 2026-06-16

### Breaking

- `TextOverlay.highlightWord` (added in 0.11.0) is removed. It
  resolved to the FIRST substring match in `content` which produced
  the wrong word whenever the active word appeared more than once in
  the line (a common case for speech-recogniser output like
  `"Mimi Mimi Mimi"` — the highlight was stuck on word 0).

### Added

- `TextOverlay.highlightStart` (UTF-16 char offset) and
  `TextOverlay.highlightLength` replace `highlightWord`. The character
  range `[highlightStart, highlightStart + highlightLength)` of
  `content` is painted in `highlightColor`. All three fields must be
  set to render — out-of-range or zero-length values are ignored.
- iOS uses `NSString.range(location:length:)` on an
  `NSMutableAttributedString`; Android uses `SpannableString.setSpan`
  with `ForegroundColorSpan`. Both treat the indices as UTF-16 units
  to match JS `String.length`.

### Migration

Callers that emitted `highlightWord: word, highlightColor: c` should
compute the word's offset in `content` and emit
`highlightStart, highlightLength, highlightColor` instead. For a line
joined with single spaces from a `words: { text: string }[]` array,
`start = words.slice(0, i).map(w => w.text.length + 1).reduce((a,b)=>a+b, 0)`
and `length = words[i].text.length`.

## [0.11.0] - 2026-06-15

### Security

URI validation that 0.10.0 added on the JS side is now enforced
**natively** as well — the JS gate can be bypassed by calling the
ExpoModule directly, so the native side becomes the source of truth.

- iOS: new `MediaEditSecurity` enum with `isReadableURIAllowed(_:)` and
  `isOutputURLAllowed(_:)`. Output URLs are canonicalized
  (`standardizedFileURL.resolvingSymlinksInPath()`) and must resolve
  inside one of: `tmp`, `Library/Caches`, `Documents`, `Application
  Support`. Defeats absolute-path escapes that a plain `"../"`
  substring check misses.
- Android: new `isReadableUriAllowed(uri)` and
  `resolveAllowedOutputFile(context, uri)` in `Utils.kt`. Output is
  canonicalized (`File(path).canonicalPath`) and must be inside
  `cacheDir`, `filesDir`, `getExternalFilesDir(null)`, or
  `externalCacheDir`.
- `getVideoInfo`, `generateThumbnail`, `extractAudio`, and the
  `editVideo` output path now reject malformed input from the native
  side before any work starts.
- `android/build.gradle` was still on `0.10.0` after the previous
  release — bumped along with `versionName` to match `package.json`.

### Added

`TextOverlay` gains 9 optional fields so consumers can render the full preset
library of subtitle/caption styles you see in modern mobile editors
(CapCut/Videoleap/Canva/Mojo/VITA) without baking style names into the
library.

- `strokeColor` + `strokeWidth` — outline. `strokeWidth` is in 1080-ref pixels
  and scaled like `fontSize`. iOS renders via `NSAttributedString` with a
  negative `strokeWidth` (fill+stroke); Android does a stroke-only paint pass
  first, then the fill, so the outline aligns pixel-perfect.
- `shadowColor` + `shadowRadius` + `shadowOpacity` — soft halo. iOS uses
  `CALayer.shadow*` (clips the corner-radius mask when both are set);
  Android uses `Paint.setShadowLayer` (the halo draws inside the glyph bounds
  rather than around the layer, which gives a different feel — both are
  intentional for their platform's idiom).
- `fontStyle: 'normal' | 'italic'` — iOS composes `.traitItalic` onto the
  current font descriptor so italic stacks with bold and with monospace;
  Android uses `Typeface.create(base, ITALIC)`.
- `fontFamily: 'system' | 'monospace'` — iOS `UIFont.monospacedSystemFont`,
  Android `Typeface.MONOSPACE`.
- `highlightWord` + `highlightColor` — repaint the FIRST occurrence of the
  substring in a different color (case-sensitive exact match). Built for
  karaoke-style word-by-word captions where the active word needs to pop.
  iOS uses `NSAttributedString` with a `.foregroundColor` attribute on the
  range; Android uses a `SpannableString` with `ForegroundColorSpan`.

All new fields are optional — overlays from 0.10.0 callers render identically.

### Internal

- iOS `OverlayCompositor.buildTextLayer` now drives an `NSAttributedString`
  throughout (was a raw `String`). The plain-string path was dropped — the
  attributed path renders the same when no new fields are set.
- Two iOS helpers extracted: `resolveFont(weight, style, family)` and
  `textAttributes(font, color, opts)`.
- Two Android helpers extracted: `resolveTypeface(family, weight, style)` and
  `buildSpannable(opts)`, plus a `parseColorOrDefault` wrapper that the
  text and background paint paths now share.
- +6 JS-side validation tests for the new optional fields.

## [0.10.0] - 2026-06-12

### Security

This release hardens URI handling. All checks are enforced on the **native** side
(Swift/Kotlin) as the source of truth — the JS validation is convenience only and
can be bypassed by calling the native module directly.

- **`outputUri` is now validated and confined to the app sandbox.** Previously
  `outputUri` was passed through unchecked on both platforms. Because the export
  path is deleted before writing (iOS `removeItem`, Android `outputFile.delete()`
  on cancel/error) and then overwritten, a `file://` (or scheme-less) path could be
  used to **overwrite or delete an arbitrary file** the app had access to. The path
  is now canonicalized and must resolve inside one of the app's writable directories
  (iOS: temp / caches / documents / application-support; Android: `cacheDir` /
  `filesDir` / external files / external cache). Otherwise the call rejects with
  `INVALID_OUTPUT`.
- **`getVideoInfo`, `generateThumbnail`, and `extractAudio` now validate their `uri`.**
  These three accepted any string and passed it straight to `AVAsset` /
  `MediaMetadataRetriever` / `MediaExtractor`, allowing reads of arbitrary local
  files (absolute `file:///…`) and, on Android, `content://` providers of other
  apps. They now require a `file://` or `https://` URI without traversal and reject
  with `INVALID_URI`.
- **Path-traversal protection no longer relies on the `../` substring alone.** An
  absolute path such as `file:///data/data/<app>/databases/x` contains no `../` and
  previously slipped through. Output paths are now checked against an allowlist after
  canonicalization (`URL.standardizedFileURL.resolvingSymlinksInPath` /
  `File.canonicalPath`), which also defeats symlink escapes.
- **`http://` is no longer accepted; only `file://` and `https://` are.** The TS
  layer previously allowed cleartext `http://` for input/overlay/audio URIs while the
  native side already rejected it for most fields — the layers are now consistent.
  This is a behavioral breaking change for anyone passing `http://` URIs; switch to
  `https://`.
- Null-byte (`\0`) injection is now rejected in all URIs.

## [0.9.1] - 2026-06-05

### Fixed
- **Android `getVideoInfo` no longer references a non-existent SDK constant.** `ExpoMediaEditModule.kt` previously read `MediaMetadataRetriever.METADATA_KEY_VIDEO_CODEC`, which doesn't exist in the Android SDK — the Kotlin compiler rejected the file. The codec is now read from the `MediaExtractor` track's `MediaFormat.KEY_MIME` (the same loop that already reads `KEY_FRAME_RATE`) and translated to the same FourCC string the iOS side returns via `CMFormatDescription`. New `mimeToFourCC` helper covers `avc1`/`hvc1`/`vp08`/`vp09`/`av01`/`mp4v`; unknown MIME types pass through unchanged.

## [0.9.0] - 2026-06-05

### Fixed
- **Android build configuration migrated to the modern Expo SDK 55 module pattern.** Previously `android/build.gradle` declared its own `buildscript` classpath for `kotlin-gradle-plugin:$kotlinVersion` (which resolved to an empty version when the host project hadn't pre-defined `kotlinVersion`) and used a bare `apply plugin: 'maven-publish'` (which fails on AGP 8+ with `SoftwareComponent with name 'release' not found`). The build now uses `applyKotlinExpoModulesCorePlugin()` + `useCoreDependencies()` + `useExpoPublishing()` — same pattern as other SDK-55 modules — and declares `namespace "expo.modules.mediaedit"` inside the `android {}` block. Adds `safeExtGet` so the root project can override `compileSdkVersion` / `minSdkVersion` / `targetSdkVersion` via `ext.*`. No source or API change on either platform.

## [0.8.2] - 2026-05-22

### Added
- **`TextOverlay.cornerRadius`** (optional, px at 1080-height reference). When `backgroundColor` is set, the box is drawn with rounded corners. Defaults to `0` (sharp).

## [0.8.1] - 2026-05-22

### Fixed
- **iOS time-ranged text/image overlays disappear at `endMs`.** Overlays with both `startMs` and `endMs` were staying visible until the end of the video instead of vanishing at `endMs`, because the opacity keyframe animation in a discrete-mode `CAKeyframeAnimation` held the visible value past `endMs` (the third value was still `opacity` instead of `0`). Critical for word-by-word subtitles where overlays accumulated on screen.

## [0.8.0] - 2026-05-22

### Changed
- **Breaking — text overlays require explicit layout.** Every text overlay must now specify four fields the native side previously guessed: `anchor` (`'topLeft' | 'center'`), `textAlign` (`'left' | 'center' | 'right'`), `paddingX` (number), and `paddingY` (number). The native compositors always measure the rendered text and size the layer to `ceil(textWidth) + 2*paddingX` × `ceil(textHeight) + 2*paddingY`. `paddingX` / `paddingY` are in pixels at a 1080-height reference and scale per platform the same way `fontSize` does. With `anchor: 'topLeft'`, `x`/`y` are the layer's top-left corner; with `anchor: 'center'`, they are the layer's geometric center. The validator throws `editVideo: overlays[i] must include anchor / textAlign / paddingX / paddingY` if any field is missing.

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

## [0.7.2] - 2026-05-22

### Changed
- **Breaking — iOS text overlays: `x` and `y` are now the layer's center, not its top-left corner.** The text layer is sized tightly to the rendered string (instead of a fixed 90%×8-line rectangle), so backgrounds wrap snugly around the text and `alignmentMode` is centered. Existing overlays at `x: 0.5, y: 0.5` are now visually centered instead of starting at the canvas midpoint.

## [0.7.1] - 2026-05-22

### Fixed
- **iOS time-ranged overlays (`startMs` / `endMs`) were never visible in the exported video.** The opacity keyframe animation now sets `beginTime = AVCoreAnimationBeginTimeAtZero` so Core Animation maps it to composition time instead of `CACurrentMediaTime()`.

## [0.7.0] - 2026-05-21

### Added
- **`extractAudio(uri)` → M4A file URI.** Strips the audio track from a video into an M4A file. Useful for feeding video to APIs that only accept raw audio formats — e.g. iOS `SFSpeechRecognizer` via `AVAudioFile`, which silently fails on `.MOV`/`.MP4` containers but reads the extracted `.m4a` fine.
  - iOS: `AVAssetExportSession` with `AVAssetExportPresetAppleM4A`.
  - Android: `MediaExtractor` + `MediaMuxer` (no re-encode; stream-copies the AAC track).
  - Rejects with `NO_AUDIO_TRACK` if the source has no audio.

## [0.6.0] - 2026-05-21

### Fixed
- **iOS playlist transitions preserve per-item rotation.** Cross-fade and slide transitions previously set `preferredTransform` only on the incoming track's layer instruction; during the overlap the outgoing track lost its rotation and portrait clips appeared sideways. Both layer instructions in the overlap now get the correct transform (`prevSrcTransform` for the outgoing, `srcTx` for the incoming) at the overlap start time.
- **iOS slide direction composes with rotation.** Previously the slide translations were applied as `.identity → translation`, which discarded the source's `preferredTransform`. Translations are now `srcTx.concatenating(translation)`, so rotated source clips stay correctly oriented during the slide.
- **iOS `setTransform(_:at:)` time argument.** Was `.zero` (matched the first track but became ambiguous for later items on a shared track). Now uses the instruction's start time, which is unambiguous and matches the existing `setOpacityRamp` / `setTransformRamp` time ranges.
- **iOS playlist letterbox / aspect-fit.** When mixing portrait and landscape items in one playlist, later items kept their natural size and overflowed (or were cropped) inside the renderSize chosen from the first item. Each item is now aspect-fit (scale + centered translation composed onto `preferredTransform`) so mixed-aspect playlists letterbox cleanly.
- **Android playlist now rejects with `INVALID_INPUT` instead of leaving the JS promise hanging** when the playlist contains no valid video item.

### Changed
- **`getVideoInfo` is platform-consistent now.**
  - iOS: applies `preferredTransform` so portrait clips report `width: 1080, height: 1920` (was `1920×1080`), and now also returns `codec` (FourCC code from `CMFormatDescription`).
  - Android: applies rotation metadata so portrait clips report swapped dimensions consistently with iOS, and `fps` is read from `MediaExtractor` (video track's `KEY_FRAME_RATE`) which is set for every encoded video; the previous `CAPTURE_FRAMERATE` source was only set for camera captures.

## [0.5.1] - 2026-05-05

### Fixed
- **iOS image scaling in playlist** — `imageToAsset` now scales the image to fit the video's render size (aspect-fit, centered on black) before creating the pixel buffer. Previously the image was encoded at its full physical pixel dimensions (e.g. 2160×3840 on a 2× device), causing it to appear at 200% size in the rendered video when the render target was 1080×1920. The render size is pre-computed from the first video item in the playlist before any images are processed.

## [0.5.0] - 2026-05-05

### Added
- **`slide` transition** — `{ type: 'slide'; durationMs: number; direction?: 'left' | 'right' | 'up' | 'down' }` (default direction: `'left'`). The previous item slides out while the new item slides in simultaneously over `durationMs`. Timeline overlap is the same as `fade` (total duration shortened by `durationMs`). iOS uses `setTransformRamp` on `AVMutableVideoCompositionLayerInstruction`; Android translates the canvas per-frame.

## [0.4.0] - 2026-05-05

### Added
- **Playlist API** — `EditJob.playlist?: PlaylistItem[]` accepts a mix of video and image items. JS normalises legacy `inputUri` to a single-item playlist automatically. Native routes to the fast single-video path unless the playlist has more than one item or starts with an image.
- **`PlaylistItem` type** — `{ type: 'video'; uri; trim?; transition? }` or `{ type: 'image'; uri; durationMs; transition? }`.
- **`Transition` type** — `{ type: 'cut' }`, `{ type: 'fade'; durationMs }`, `{ type: 'fadeToBlack'; durationMs }`.
- **iOS playlist compositor** — `VideoEditor.editPlaylist()` builds an `AVMutableComposition` with two alternating tracks. Fade uses `setOpacityRamp` on layer instructions; FadeToBlack blacks out and restores opacity per-item. Images are converted to single-frame MP4 via `AVAssetWriter` before composition.
- **Android playlist compositor** — `PlaylistCompositor` decodes each item frame-by-frame and blends with `Paint.alpha` for cross-fade and fade-to-black transitions.
- **`Transition`, `PlaylistItem` re-exported** from package entry point.

### Changed
- `editVideo(jobDict)` native signature changed on both iOS and Android from `(inputUri, jobDict)` to `(jobDict)`. Playlist is always passed; `inputUri` is no longer a separate parameter at the native layer.

## [0.3.1] - 2026-05-05

### Fixed
- **iOS font size consistency** — `fontSize` is now scaled by `videoHeight / 1080` on iOS, matching the existing Android behaviour. Text size in rendered videos is now identical across platforms.
- **Android text wrapping** — `canvas.drawText()` replaced by `StaticLayout` so multi-line text wraps at 90% of video width, matching iOS (`CATextLayer.isWrapped = true`).
- **iOS layer height for multi-line text** — `layerHeight` increased from `fontSize * 2.5` to `fontSize * 8` so wrapped text is no longer clipped.
- **Android rotation pivot** — rotation is now applied around the center of the `StaticLayout` bounds (was around the text anchor point).

## [0.3.0] - 2026-05-05

### Added
- **Text overlay rotation** — `rotation?: number` (degrees) on `TextOverlay`. iOS wraps `CATextLayer` in a container `CALayer` and applies `CATransform3DMakeRotation`. Android uses `canvas.save()` / `canvas.rotate()` / `canvas.restore()` around the text draw call. Default: 0 (no rotation).

## [0.2.0] - 2026-05-04

### Added
- **Progress callbacks** — `addProgressListener(callback)` returns a subscription; iOS polls `AVAssetExportSession.progress` every 200ms, Android fires per-frame in `OverlayCompositor`.
- **Cancellation** — `cancelEdit()` exported function. iOS calls `AVAssetExportSession.cancelExport()`, Android uses `@Volatile cancelRequested` flag checked per frame.
- **Quality preset** — `quality?: 'low' | 'medium' | 'high'` on `EditJob`. iOS maps to `AVAssetExportPreset*Quality`, Android maps to bitrate (1M/2M/4M).
- **Android audio volume scaling** — when `originalVolume` or `volume` is between 0 and 1 (exclusive), PCM decode → scale → re-encode AAC. Volume 0 skips track, volume 1 uses stream copy.
- **Video rotation on Android** — reads `METADATA_KEY_VIDEO_ROTATION` and calls `muxer.setOrientationHint(rotation)` on output.
- **URI security hardening** — JS `validateEditJob()` and native iOS/Android both reject image overlay URIs and audio URIs containing `../` or with schemes other than `file://` / `https://`.
- **Temp file cleanup on error** — iOS: removes output file on cancel/failure. Android: `try/finally` in `VideoEditor` deletes all intermediate temp files on error or cancellation.
- **Comprehensive example app** — Big Buck Bunny test video (CC BY 3.0), progress bar, cancel button, quality selector, all overlay types, credits section.
- **`ProgressEvent` type** exported from `src/types.ts`.

### Changed
- `EditJob` now includes `quality?: 'low' | 'medium' | 'high'`.
- `ExpoMediaEditModule.ts` now exports an `EventEmitter` (`emitter`) for progress events.
- `VideoEditor.swift` `edit()` signature changed: `progress` callback replaced by `onSessionReady` callback that receives the `AVAssetExportSession`.
- `VideoEditor.kt` `edit()` signature extended with `cancelCheck: () -> Boolean` parameter.
- `OverlayCompositor.kt` `composite()` now accepts `quality`, `progressCallback`, and `cancelCheck` parameters.
- `EditJob` (Kotlin) now includes `quality: String`.
- `OverlayCompositor.swift` `buildImageLayer` now validates URI against path traversal and uses proper `file://` prefix stripping.

## [0.1.0] - 2026-05-04

### Added
- `editVideo(job)` — trim, text/image overlays, audio mix via native APIs
- `getVideoInfo(uri)` — read video metadata (duration, dimensions, fps, file size)
- `generateThumbnail(uri, timeMs, options?)` — extract JPEG thumbnail at any timestamp
- `cleanTempFiles()` — delete all temporary files created by the module
- iOS implementation via AVFoundation (AVMutableComposition, CALayer overlay burn-in, AVAssetExportSession)
- Android implementation via MediaCodec + MediaMuxer (stream-copy trim, frame-by-frame overlay composite, audio track mixing)
- TypeScript strict types for all public APIs
- Input validation with descriptive error messages
- Automatic temp file management in `<cacheDir>/expo-media-edit/`
