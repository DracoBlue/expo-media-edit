/**
 * Non-Project types: thin metadata/utility shapes that survived the
 * 0.14.0 composer refactor. Project-related types live in
 * `src/project.ts`.
 */

export type VideoInfo = {
  durationMs: number;
  width: number;
  height: number;
  fps: number;
  fileSize: number;
  codec?: string;
};

export type ThumbnailOptions = {
  width?: number;
  height?: number;
};

export type ProgressEvent = {
  progress: number;
};
