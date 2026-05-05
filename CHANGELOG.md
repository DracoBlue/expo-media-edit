# Changelog

All notable changes to this project will be documented in this file.

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
