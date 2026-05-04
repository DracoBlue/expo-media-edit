# Changelog

All notable changes to this project will be documented in this file.

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
