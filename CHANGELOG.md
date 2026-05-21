# Changelog

All notable changes to this project will be documented in this file.

## [0.6.0] - 2026-05-21

### Fixed
- **iOS playlist transitions preserve per-item rotation.** Cross-fade and slide transitions previously set `preferredTransform` only on the incoming track's layer instruction; during the overlap the outgoing track lost its rotation and portrait clips appeared sideways. Both layer instructions in the overlap now get the correct transform (`prevSrcTransform` for the outgoing, `srcTx` for the incoming) at the overlap start time.
- **iOS slide direction composes with rotation.** Previously the slide translations were applied as `.identity → translation`, which discarded the source's `preferredTransform`. Translations are now `srcTx.concatenating(translation)`, so rotated source clips stay correctly oriented during the slide.
- **iOS `setTransform(_:at:)` time argument.** Was `.zero` (matched the first track but became ambiguous for later items on a shared track). Now uses the instruction's start time, which is unambiguous and matches the existing `setOpacityRamp` / `setTransformRamp` time ranges.

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
