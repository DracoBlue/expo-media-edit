export type TextOverlay = {
  type: 'text';
  content: string;
  x: number;
  y: number;
  fontSize?: number;
  color?: string;
  fontWeight?: 'normal' | 'bold';
  backgroundColor?: string;
  startMs?: number;
  endMs?: number;
};

export type ImageOverlay = {
  type: 'image';
  uri: string;
  x: number;
  y: number;
  width: number;
  height: number;
  opacity?: number;
  startMs?: number;
  endMs?: number;
};

export type OverlayItem = TextOverlay | ImageOverlay;

export type AudioMix = {
  uri: string;
  volume?: number;
  originalVolume?: number;
  startMs?: number;
  trimToVideo?: boolean;
};

export type EditJob = {
  inputUri: string;
  outputUri?: string;
  trim?: { startMs: number; endMs: number };
  overlays?: OverlayItem[];
  audio?: AudioMix;
};

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
