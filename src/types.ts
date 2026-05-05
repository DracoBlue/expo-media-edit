export type TextOverlay = {
  type: 'text';
  content: string;
  x: number;
  y: number;
  fontSize?: number;
  color?: string;
  fontWeight?: 'normal' | 'bold';
  backgroundColor?: string;
  rotation?: number;  // degrees, default 0
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

export type Transition =
  | { type: 'cut' }
  | { type: 'fade'; durationMs: number }
  | { type: 'fadeToBlack'; durationMs: number };

export type PlaylistItem =
  | { type: 'video'; uri: string; trim?: { startMs: number; endMs: number }; transition?: Transition }
  | { type: 'image'; uri: string; durationMs: number; transition?: Transition };

export type AudioMix = {
  uri: string;
  volume?: number;
  originalVolume?: number;
  startMs?: number;
  trimToVideo?: boolean;
};

export type EditJob = {
  inputUri?: string;           // single-video shorthand; ignored when playlist is provided
  playlist?: PlaylistItem[];   // new in 0.4.0; takes precedence over inputUri
  outputUri?: string;
  trim?: { startMs: number; endMs: number };  // only applies in inputUri mode
  overlays?: OverlayItem[];
  audio?: AudioMix;
  quality?: 'low' | 'medium' | 'high';
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

export type ProgressEvent = {
  progress: number;
};
