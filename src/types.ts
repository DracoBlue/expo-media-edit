export type TextOverlay = {
  type: 'text';
  content: string;
  x: number;
  y: number;
  /**
   * How `x`/`y` are interpreted relative to the rendered text layer.
   * - `topLeft`: `x`/`y` mark the top-left corner of the layer.
   * - `center`: `x`/`y` mark the geometric center of the layer.
   */
  anchor: 'topLeft' | 'center';
  /** Alignment of text within the layer. */
  textAlign: 'left' | 'center' | 'right';
  /** Horizontal padding in pixels at a 1080-height reference. Scaled per platform like fontSize. */
  paddingX: number;
  /** Vertical padding in pixels at a 1080-height reference. Scaled per platform like fontSize. */
  paddingY: number;
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
  | { type: 'fadeToBlack'; durationMs: number }
  | { type: 'slide'; durationMs: number; direction?: 'left' | 'right' | 'up' | 'down' };

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
