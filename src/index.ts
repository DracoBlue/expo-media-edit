/**
 * expo-media-edit 0.14.0 — Project-based video composer
 *
 * The public API is built around `Project` (src/project.ts), a pure-
 * data document describing tracks/clips/overlays. Both the preview
 * view (<MediaPreview />) and the exporter (`exportProject`) compile
 * the SAME Project into a native composition — preview pixels equal
 * export pixels.
 *
 * The 0.13.x `editVideo(EditJob)` API is REMOVED in 0.14.0. Callers
 * must migrate to `exportProject(project)`. See CHANGELOG.md.
 */

import ExpoMediaEditModule, { emitter } from './ExpoMediaEditModule';
import type { Project } from './project';
import type { VideoInfo, ThumbnailOptions, ProgressEvent } from './types';

// Re-exports: the Project schema is the new public surface.
export * from './project';
export type { VideoInfo, ThumbnailOptions, ProgressEvent } from './types';
export { default as MediaPreview, type MediaPreviewProps } from './MediaPreviewView';

// ─── URI guards (kept from 0.13.x, still defence-in-depth) ──────────

function validateUri(uri: string, label: string): void {
  if (uri.includes('\0')) throw new Error(`${label} must not contain null bytes.`);
  if (uri.includes('../')) throw new Error(`${label} must not contain path traversal sequences.`);
  if (!uri.startsWith('file://') && !uri.startsWith('https://')) {
    throw new Error(`${label} must be a file:// or https:// URI.`);
  }
}

function validateOutputUri(uri: string, label: string): void {
  if (uri.includes('\0')) throw new Error(`${label} must not contain null bytes.`);
  if (uri.includes('../')) throw new Error(`${label} must not contain path traversal sequences.`);
  if (!uri.startsWith('file://')) throw new Error(`${label} must be a file:// URI.`);
}

// ─── Export ─────────────────────────────────────────────────────────

export type ExportOptions = {
  /** Encode quality preset. Maps to native preset names. Default 'high'. */
  quality?: 'low' | 'medium' | 'high';
};

/**
 * Subscribe to render progress events emitted during `exportProject`.
 * Returns a subscription whose `.remove()` must be called when done
 * (typically in a `finally` block alongside the export call).
 */
export function addProgressListener(callback: (event: ProgressEvent) => void) {
  return emitter.addListener<ProgressEvent>('onProgress', callback);
}

/**
 * Render a Project to an MP4 file. Returns the output file:// URI.
 *
 * Subscribe to progress with `addProgressListener` before calling.
 * The compile step runs on a background thread so this function does
 * not block the JS thread during JSON parsing.
 */
export async function exportProject(
  project: Project,
  outputUri?: string,
  options?: ExportOptions
): Promise<string> {
  if (outputUri !== undefined) {
    validateOutputUri(outputUri, 'exportProject: outputUri');
  }
  if (options?.quality !== undefined && !['low', 'medium', 'high'].includes(options.quality)) {
    throw new Error("exportProject: options.quality must be 'low', 'medium', or 'high'.");
  }
  return ExpoMediaEditModule.exportProject(project, outputUri ?? null, options ?? null);
}

/**
 * Cancel an in-flight `exportProject` call. The pending export
 * promise rejects with code "CANCELLED".
 */
export async function cancelExport(): Promise<void> {
  return ExpoMediaEditModule.cancelExport();
}

// ─── Metadata / utilities (unchanged from 0.13.x) ───────────────────

export async function getVideoInfo(uri: string): Promise<VideoInfo> {
  if (!uri || typeof uri !== 'string') {
    throw new Error('getVideoInfo: uri is required and must be a non-empty string.');
  }
  validateUri(uri, 'getVideoInfo: uri');
  return ExpoMediaEditModule.getVideoInfo(uri);
}

export async function generateThumbnail(
  uri: string,
  timeMs: number,
  options?: ThumbnailOptions
): Promise<string> {
  if (!uri || typeof uri !== 'string') {
    throw new Error('generateThumbnail: uri is required and must be a non-empty string.');
  }
  validateUri(uri, 'generateThumbnail: uri');
  if (typeof timeMs !== 'number' || timeMs < 0) {
    throw new Error('generateThumbnail: timeMs must be a non-negative number.');
  }
  return ExpoMediaEditModule.generateThumbnail(uri, timeMs, options ?? null);
}

export async function extractAudio(uri: string): Promise<string> {
  if (!uri || typeof uri !== 'string') {
    throw new Error('extractAudio: uri is required and must be a non-empty string.');
  }
  validateUri(uri, 'extractAudio: uri');
  return ExpoMediaEditModule.extractAudio(uri);
}

export async function cleanTempFiles(): Promise<number> {
  return ExpoMediaEditModule.cleanTempFiles();
}
