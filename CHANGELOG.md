# Changelog

All notable changes to this project will be documented in this file.

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
