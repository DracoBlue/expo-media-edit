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
  /** 0.11.0: italic via the system italic face. Default 'normal'. */
  fontStyle?: 'normal' | 'italic';
  /**
   * 0.11.0: which system font family to use. `'monospace'` picks
   * `UIFont.monospacedSystemFont` on iOS and `Typeface.MONOSPACE` on
   * Android. Default `'system'`.
   */
  fontFamily?: 'system' | 'monospace';
  backgroundColor?: string;
  /** Corner radius for the background box, in pixels at the 1080-height reference. 0 = sharp corners. */
  cornerRadius?: number;
  /**
   * 0.11.0: optional text outline. `strokeWidth` is in pixels at the
   * 1080-height reference (scaled like fontSize). Both fields must be
   * present to render — providing only one is a no-op.
   */
  strokeColor?: string;
  strokeWidth?: number;
  /**
   * 0.11.0: optional soft halo behind the text. `shadowRadius` is in
   * pixels at the 1080-height reference (scaled); `shadowOpacity` is
   * 0..1 (default 1). `shadowColor` + `shadowRadius` required to
   * render; providing only one is a no-op.
   */
  shadowColor?: string;
  shadowRadius?: number;
  shadowOpacity?: number;
  /**
   * 0.11.0: word/substring colouring for karaoke-style captions. The
   * FIRST occurrence of `highlightWord` inside `content` is rendered
   * in `highlightColor`; the rest of the content stays in `color`.
   * Case-sensitive, exact substring match. Both fields required to
   * render — providing only one is a no-op.
   */
  highlightWord?: string;
  highlightColor?: string;
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
