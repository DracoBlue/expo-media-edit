export { EditJob, OverlayItem, TextOverlay, ImageOverlay, AudioMix, VideoInfo, ThumbnailOptions, ProgressEvent } from './types';

import ExpoMediaEditModule, { emitter } from './ExpoMediaEditModule';
import type { EditJob, VideoInfo, ThumbnailOptions, ProgressEvent } from './types';

function validateUri(uri: string, label: string): void {
  if (uri.includes('../')) {
    throw new Error(`${label} must not contain path traversal sequences.`);
  }
  if (!uri.startsWith('file://') && !uri.startsWith('https://') && !uri.startsWith('http://')) {
    throw new Error(`${label} must be a file:// or https:// URI.`);
  }
}

function validateEditJob(job: EditJob): void {
  if (!job.inputUri || typeof job.inputUri !== 'string' || job.inputUri.trim() === '') {
    throw new Error('editVideo: inputUri is required and must be a non-empty string.');
  }
  if (job.trim !== undefined) {
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

  const { inputUri, outputUri, trim, overlays, audio, quality } = job;

  const jobDict: Record<string, unknown> = {};
  if (outputUri !== undefined) jobDict.outputUri = outputUri;
  if (trim !== undefined) jobDict.trim = trim;
  if (overlays !== undefined) jobDict.overlays = overlays;
  if (audio !== undefined) jobDict.audio = audio;
  if (quality !== undefined) jobDict.quality = quality;

  return ExpoMediaEditModule.editVideo(inputUri, jobDict);
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
