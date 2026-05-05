export { EditJob, OverlayItem, TextOverlay, ImageOverlay, AudioMix, VideoInfo, ThumbnailOptions, ProgressEvent, Transition, PlaylistItem } from './types';

import ExpoMediaEditModule, { emitter } from './ExpoMediaEditModule';
import type { EditJob, VideoInfo, ThumbnailOptions, ProgressEvent, PlaylistItem } from './types';

function validateUri(uri: string, label: string): void {
  if (uri.includes('../')) {
    throw new Error(`${label} must not contain path traversal sequences.`);
  }
  if (!uri.startsWith('file://') && !uri.startsWith('https://') && !uri.startsWith('http://')) {
    throw new Error(`${label} must be a file:// or https:// URI.`);
  }
}

function validatePlaylistItem(item: PlaylistItem, index: number): void {
  if (item.type !== 'video' && item.type !== 'image') {
    throw new Error(`editVideo: playlist[${index}].type must be 'video' or 'image'.`);
  }
  if (!item.uri || typeof item.uri !== 'string') {
    throw new Error(`editVideo: playlist[${index}].uri is required.`);
  }
  validateUri(item.uri, `editVideo: playlist[${index}].uri`);
  if (item.type === 'image') {
    if (typeof item.durationMs !== 'number' || item.durationMs <= 0) {
      throw new Error(`editVideo: playlist[${index}].durationMs must be a positive number.`);
    }
  }
  if (item.type === 'video' && item.trim !== undefined) {
    if (item.trim.startMs < 0) throw new Error(`editVideo: playlist[${index}].trim.startMs must be >= 0.`);
    if (item.trim.startMs >= item.trim.endMs) throw new Error(`editVideo: playlist[${index}].trim.startMs must be less than endMs.`);
  }
  if (item.transition !== undefined) {
    const t = item.transition;
    if (t.type !== 'cut' && t.type !== 'fade' && t.type !== 'fadeToBlack') {
      throw new Error(`editVideo: playlist[${index}].transition.type must be 'cut', 'fade', or 'fadeToBlack'.`);
    }
    if ((t.type === 'fade' || t.type === 'fadeToBlack') && (typeof t.durationMs !== 'number' || t.durationMs <= 0)) {
      throw new Error(`editVideo: playlist[${index}].transition.durationMs must be a positive number.`);
    }
  }
}

function validateEditJob(job: EditJob): void {
  const hasPlaylist = Array.isArray(job.playlist) && job.playlist.length > 0;
  const hasInputUri = typeof job.inputUri === 'string' && job.inputUri.trim() !== '';

  if (!hasPlaylist && !hasInputUri) {
    throw new Error('editVideo: either inputUri or playlist is required.');
  }
  if (hasPlaylist) {
    for (let i = 0; i < job.playlist!.length; i++) {
      validatePlaylistItem(job.playlist![i], i);
    }
  }
  if (!hasPlaylist && job.trim !== undefined) {
    if (typeof job.trim.startMs !== 'number' || typeof job.trim.endMs !== 'number') {
      throw new Error('editVideo: trim.startMs and trim.endMs must be numbers.');
    }
    if (job.trim.startMs < 0) {
      throw new Error('editVideo: trim.startMs must be >= 0.');
    }
    if (job.trim.startMs >= job.trim.endMs) {
      throw new Error('editVideo: trim.startMs must be less than trim.endMs.');
    }
  }
  if (job.overlays !== undefined) {
    for (let i = 0; i < job.overlays.length; i++) {
      const overlay = job.overlays[i];
      if (overlay.type !== 'text' && overlay.type !== 'image') {
        throw new Error(`editVideo: overlays[${i}].type must be 'text' or 'image'.`);
      }
      if (typeof overlay.x !== 'number' || overlay.x < 0 || overlay.x > 1) {
        throw new Error(`editVideo: overlays[${i}].x must be a number between 0.0 and 1.0.`);
      }
      if (typeof overlay.y !== 'number' || overlay.y < 0 || overlay.y > 1) {
        throw new Error(`editVideo: overlays[${i}].y must be a number between 0.0 and 1.0.`);
      }
      if (overlay.type === 'text') {
        if (!overlay.content || typeof overlay.content !== 'string') {
          throw new Error(`editVideo: overlays[${i}].content is required for text overlays.`);
        }
      }
      if (overlay.type === 'image') {
        if (!overlay.uri || typeof overlay.uri !== 'string') {
          throw new Error(`editVideo: overlays[${i}].uri is required for image overlays.`);
        }
        validateUri(overlay.uri, `editVideo: overlays[${i}].uri`);
        if (typeof overlay.width !== 'number' || overlay.width <= 0 || overlay.width > 1) {
          throw new Error(`editVideo: overlays[${i}].width must be a number between 0.0 and 1.0.`);
        }
        if (typeof overlay.height !== 'number' || overlay.height <= 0 || overlay.height > 1) {
          throw new Error(`editVideo: overlays[${i}].height must be a number between 0.0 and 1.0.`);
        }
      }
      if (
        overlay.startMs !== undefined &&
        overlay.endMs !== undefined &&
        overlay.startMs >= overlay.endMs
      ) {
        throw new Error(`editVideo: overlays[${i}].startMs must be less than endMs.`);
      }
    }
  }
  if (job.audio !== undefined) {
    if (!job.audio.uri || typeof job.audio.uri !== 'string') {
      throw new Error('editVideo: audio.uri is required and must be a non-empty string.');
    }
    validateUri(job.audio.uri, 'editVideo: audio.uri');
    if (job.audio.volume !== undefined && (job.audio.volume < 0 || job.audio.volume > 2)) {
      throw new Error('editVideo: audio.volume must be between 0.0 and 2.0.');
    }
    if (
      job.audio.originalVolume !== undefined &&
      (job.audio.originalVolume < 0 || job.audio.originalVolume > 2)
    ) {
      throw new Error('editVideo: audio.originalVolume must be between 0.0 and 2.0.');
    }
  }
  if (job.quality !== undefined && !['low', 'medium', 'high'].includes(job.quality)) {
    throw new Error("editVideo: quality must be 'low', 'medium', or 'high'.");
  }
}

/**
 * Listen for progress events during editVideo().
 * Returns a subscription that must be removed when done.
 *
 * @example
 * const sub = addProgressListener(({ progress }) => console.log(progress));
 * await editVideo(job);
 * sub.remove();
 */
export function addProgressListener(callback: (event: ProgressEvent) => void) {
  return emitter.addListener<ProgressEvent>('onProgress', callback);
}

/**
 * Edit a video: trim, add text/image overlays, mix audio.
 * Returns a file URI pointing to the output video.
 *
 * Subscribe to progress events with addProgressListener() before calling this.
 */
export async function editVideo(job: EditJob): Promise<string> {
  validateEditJob(job);

  // Normalize: inputUri → playlist so native always receives a playlist
  const playlist: PlaylistItem[] = job.playlist ?? [
    { type: 'video', uri: job.inputUri!, trim: job.trim },
  ];

  const jobDict: Record<string, unknown> = { playlist };
  if (job.outputUri !== undefined) jobDict.outputUri = job.outputUri;
  if (job.overlays !== undefined) jobDict.overlays = job.overlays;
  if (job.audio !== undefined) jobDict.audio = job.audio;
  if (job.quality !== undefined) jobDict.quality = job.quality;

  return ExpoMediaEditModule.editVideo(jobDict);
}

/**
 * Cancel an in-progress editVideo() call.
 * The editVideo promise will reject with error code "CANCELLED".
 */
export async function cancelEdit(): Promise<void> {
  return ExpoMediaEditModule.cancelEdit();
}

/**
 * Get metadata about a video file.
 */
export async function getVideoInfo(uri: string): Promise<VideoInfo> {
  if (!uri || typeof uri !== 'string') {
    throw new Error('getVideoInfo: uri is required and must be a non-empty string.');
  }
  return ExpoMediaEditModule.getVideoInfo(uri);
}

/**
 * Generate a thumbnail image from a video at the given timestamp.
 * Returns a file URI for the JPEG thumbnail.
 */
export async function generateThumbnail(
  uri: string,
  timeMs: number,
  options?: ThumbnailOptions
): Promise<string> {
  if (!uri || typeof uri !== 'string') {
    throw new Error('generateThumbnail: uri is required and must be a non-empty string.');
  }
  if (typeof timeMs !== 'number' || timeMs < 0) {
    throw new Error('generateThumbnail: timeMs must be a non-negative number.');
  }
  return ExpoMediaEditModule.generateThumbnail(uri, timeMs, options ?? null);
}

/**
 * Delete all temporary files created by expo-media-edit.
 * Returns the number of files deleted.
 */
export async function cleanTempFiles(): Promise<number> {
  return ExpoMediaEditModule.cleanTempFiles();
}
