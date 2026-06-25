/**
 * Project document — the pure-data, JSON-serialisable representation
 * of an editing session. This is the single source of truth that both
 * the preview player (`<MediaPreview>`) and the exporter
 * (`exportProject`) compile against — they take the SAME document and
 * produce the SAME render. No drift possible.
 *
 * The schema is intentionally minimal for V1: it covers exactly the
 * feature set documented in kiesel/docs/VIDEO_CREATOR.md as of
 * 2026-06-25, MINUS slide transition (dropped by PO — see
 * CHANGELOG.md 0.14.0 for context).
 *
 * Effects are a discriminated union. The native compilers
 * (ProjectCompiler.swift / ProjectCompiler.kt) walk the union and
 * map each variant to its platform primitive. Unknown effect types
 * are logged + ignored — never throw — so OTA updates with new
 * effects don't crash older builds.
 */

export const SCHEMA_VERSION = 1 as const;

export type TimeRange = { startMs: number; endMs: number };

export type Project = {
  id: string;
  schemaVersion: typeof SCHEMA_VERSION;
  canvasSize: { width: number; height: number };
  /** Output frame rate. Defaults to 30. */
  fps?: number;
  /** Cached total duration; computed from tracks. Use `projectDurationMs` to recompute. */
  durationMs: number;
  tracks: Track[];
  /** Effects applied to the final composited frame (e.g. global LUT). */
  globalEffects?: Effect[];
};

export type Track =
  | { kind: "video"; id: string; clips: VideoClip[] }
  | { kind: "audio"; id: string; clips: AudioClip[] }
  | { kind: "overlay"; id: string; items: OverlayClip[] };

/**
 * A video clip. Trim is expressed as TWO ranges:
 *   sourceRange    — where inside the source file to read
 *   timelineRange  — where on the project's timeline the clip lands
 * Both must have the same duration. Speed-change (V2) breaks that
 * invariant intentionally — not in scope here.
 */
export type VideoClip = {
  id: string;
  sourceUri: string;
  sourceRange: TimeRange;
  timelineRange: TimeRange;
  /** Transition to the FOLLOWING clip in the same track. Last clip ignores this. */
  transition?: ClipTransition;
  /** 0..1. Default 1. Mute = 0. */
  originalVolume?: number;
};

/**
 * An image clip. Sits inside a "video" track — image-as-MediaItem
 * with a duration is supported by both AVFoundation and media3.
 */
export type ImageClip = {
  id: string;
  kind: "image";
  sourceUri: string;
  durationMs: number;
  timelineRange: TimeRange;
  transition?: ClipTransition;
};

/**
 * Transition applied AT THE END of a clip (overlapping into the next).
 * `cut` is the implicit default when no transition is set.
 *
 * Slide was dropped in 0.14.0 — media3 has no built-in push-slide and
 * implementing one would require a custom MatrixTransformation plus a
 * multi-sequence Composition split per transition seam. Kept out to
 * keep the V1 surface lean. PO decision 2026-06-25.
 */
export type ClipTransition =
  | { type: "cut" }
  | { type: "fade"; durationMs: number }
  | { type: "fadeToBlack"; durationMs: number };

export type AudioClip = {
  id: string;
  sourceUri: string;
  sourceRange: TimeRange;
  timelineRange: TimeRange;
  /** 0..1. Default 1. */
  volume?: number;
  /**
   * If true, the audio is trimmed/looped to match the total video
   * duration. Used for background music tracks.
   */
  trimToVideo?: boolean;
};

export type OverlayClip = TextOverlayClip | ImageOverlayClip;

/**
 * Text overlay. All the 0.11/0.12 knobs from the legacy TextOverlay
 * type are preserved verbatim — same field names, same semantics —
 * because Kiesel's render-fidelity rules (kiesel/docs/VIDEO_CREATOR.md
 * §"Editor ↔ Render Fidelity") were validated against these exact
 * names and units.
 *
 * Position semantics:
 *   x, y       fractions 0..1 of the source/canvas dimensions
 *   anchor     how (x,y) maps onto the rendered text layer
 *   textAlign  alignment WITHIN the layer
 *
 * Visibility window: timelineRange. (Replaces the legacy startMs/endMs
 * pair so all clips speak the same time-range language.)
 */
export type TextOverlayClip = {
  id: string;
  kind: "text";
  content: string;
  /** Position fractions, 0..1. */
  x: number;
  y: number;
  anchor: "topLeft" | "center";
  textAlign: "left" | "center" | "right";
  /** Horizontal padding at the 1080-height reference. Scaled per platform like fontSize. */
  paddingX: number;
  /** Vertical padding at the 1080-height reference. */
  paddingY: number;
  fontSize?: number;
  color?: string;
  fontWeight?: "normal" | "bold";
  fontStyle?: "normal" | "italic";
  fontFamily?: "system" | "monospace";
  backgroundColor?: string;
  /** Background pill corner radius at 1080-height reference. */
  cornerRadius?: number;
  /** Stroke. Both strokeColor + strokeWidth required to render. */
  strokeColor?: string;
  strokeWidth?: number;
  /** Soft halo behind text. Both shadowColor + shadowRadius required. */
  shadowColor?: string;
  shadowRadius?: number;
  shadowOpacity?: number;
  /**
   * Karaoke / per-substring highlight. All three fields required.
   * `highlightStart` is a UTF-16 char index into `content`; `highlightLength`
   * counts UTF-16 units. The covered range is repainted in `highlightColor`,
   * the rest stays in `color`.
   */
  highlightColor?: string;
  highlightStart?: number;
  highlightLength?: number;
  /** Degrees, default 0. */
  rotation?: number;
  /** When the overlay is visible. Omit for full-project. */
  timelineRange?: TimeRange;
};

export type ImageOverlayClip = {
  id: string;
  kind: "image";
  uri: string;
  /** Position fractions 0..1 of the source/canvas dimensions. */
  x: number;
  y: number;
  /** Size fractions 0..1. */
  width: number;
  height: number;
  opacity?: number;
  rotation?: number;
  timelineRange?: TimeRange;
};

/**
 * Compositing effects. Minimal in V1 — the catalog stays small until
 * there's pressure to grow it. New variants must be added to the
 * native compilers' EffectsRegistry mappings too.
 */
export type Effect =
  | { type: "fade"; durationMs: number; in?: boolean; out?: boolean };

// ─── Helpers ────────────────────────────────────────────────────────

let _idCounter = 0;
/** Cheap, non-cryptographic id for in-memory clip identity. */
export function makeClipId(prefix = "clip"): string {
  _idCounter += 1;
  return `${prefix}_${_idCounter.toString(36)}`;
}

/**
 * Compute total project duration from track contents. Defined as the
 * max `timelineRange.endMs` across every clip in every track.
 *
 * Transitions are EXPECTED to be already accounted for in the
 * `timelineRange` values — i.e. when callers build a project they
 * shorten the timeline for crossfade-style transitions. The compiler
 * trusts this; it does not back-derive durations from transition
 * specs. Keeps the document self-describing.
 */
export function projectDurationMs(p: Pick<Project, "tracks">): number {
  let max = 0;
  for (const t of p.tracks) {
    if (t.kind === "video") {
      for (const c of t.clips) if (c.timelineRange.endMs > max) max = c.timelineRange.endMs;
    } else if (t.kind === "audio") {
      for (const c of t.clips) if (c.timelineRange.endMs > max) max = c.timelineRange.endMs;
    } else {
      for (const o of t.items) {
        const r = o.timelineRange;
        if (r && r.endMs > max) max = r.endMs;
      }
    }
  }
  return max;
}

export type CreateProjectInput = {
  id?: string;
  canvasSize: { width: number; height: number };
  fps?: number;
  tracks?: Track[];
  globalEffects?: Effect[];
};

export function createProject(input: CreateProjectInput): Project {
  const tracks = input.tracks ?? [];
  return {
    id: input.id ?? makeClipId("proj"),
    schemaVersion: SCHEMA_VERSION,
    canvasSize: input.canvasSize,
    fps: input.fps,
    durationMs: projectDurationMs({ tracks }),
    tracks,
    globalEffects: input.globalEffects,
  };
}

// ─── Edit operations ────────────────────────────────────────────────
//
// `applyEdit(project, op) -> project'` keeps the document immutable
// at the API boundary. Internally each op clones the affected branch
// — siblings share references with the previous version (structural
// sharing) so undo stacks stay cheap.

export type EditOp =
  | { type: "setCanvasSize"; width: number; height: number }
  | { type: "addTrack"; track: Track }
  | { type: "removeTrack"; trackId: string }
  | { type: "addVideoClip"; trackId: string; clip: VideoClip }
  | { type: "removeClip"; trackId: string; clipId: string }
  | { type: "replaceVideoClip"; trackId: string; clipId: string; clip: VideoClip }
  | { type: "addAudioClip"; trackId: string; clip: AudioClip }
  | { type: "replaceAudioClip"; trackId: string; clipId: string; clip: AudioClip }
  | { type: "addOverlay"; trackId: string; item: OverlayClip }
  | { type: "removeOverlay"; trackId: string; itemId: string }
  | { type: "replaceOverlay"; trackId: string; itemId: string; item: OverlayClip }
  | { type: "setGlobalEffects"; effects: Effect[] | undefined };

export function applyEdit(project: Project, op: EditOp): Project {
  switch (op.type) {
    case "setCanvasSize":
      return { ...project, canvasSize: { width: op.width, height: op.height } };
    case "setGlobalEffects":
      return { ...project, globalEffects: op.effects };
    case "addTrack":
      return withTracks(project, [...project.tracks, op.track]);
    case "removeTrack":
      return withTracks(project, project.tracks.filter((t) => t.id !== op.trackId));
    case "addVideoClip":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "video" && t.id === op.trackId
          ? { ...t, clips: [...t.clips, op.clip] }
          : t,
      ));
    case "replaceVideoClip":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "video" && t.id === op.trackId
          ? { ...t, clips: t.clips.map((c) => c.id === op.clipId ? op.clip : c) }
          : t,
      ));
    case "addAudioClip":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "audio" && t.id === op.trackId
          ? { ...t, clips: [...t.clips, op.clip] }
          : t,
      ));
    case "replaceAudioClip":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "audio" && t.id === op.trackId
          ? { ...t, clips: t.clips.map((c) => c.id === op.clipId ? op.clip : c) }
          : t,
      ));
    case "removeClip":
      return withTracks(project, project.tracks.map((t) => {
        if (t.id !== op.trackId) return t;
        if (t.kind === "video") return { ...t, clips: t.clips.filter((c) => c.id !== op.clipId) };
        if (t.kind === "audio") return { ...t, clips: t.clips.filter((c) => c.id !== op.clipId) };
        return t;
      }));
    case "addOverlay":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "overlay" && t.id === op.trackId
          ? { ...t, items: [...t.items, op.item] }
          : t,
      ));
    case "removeOverlay":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "overlay" && t.id === op.trackId
          ? { ...t, items: t.items.filter((i) => i.id !== op.itemId) }
          : t,
      ));
    case "replaceOverlay":
      return withTracks(project, project.tracks.map((t) =>
        t.kind === "overlay" && t.id === op.trackId
          ? { ...t, items: t.items.map((i) => i.id === op.itemId ? op.item : i) }
          : t,
      ));
  }
}

function withTracks(project: Project, tracks: Track[]): Project {
  return { ...project, tracks, durationMs: projectDurationMs({ tracks }) };
}

// ─── Validation ─────────────────────────────────────────────────────
//
// Cheap structural validation that happens BEFORE the JS↔native
// bridge so a malformed Project never reaches the native compiler.

export function validateProject(p: Project): { ok: true } | { ok: false; reason: string } {
  if (p.schemaVersion !== SCHEMA_VERSION) {
    return { ok: false, reason: `Unsupported schemaVersion ${p.schemaVersion}. Expected ${SCHEMA_VERSION}.` };
  }
  if (!Number.isFinite(p.canvasSize.width) || p.canvasSize.width <= 0) return { ok: false, reason: "canvasSize.width must be > 0" };
  if (!Number.isFinite(p.canvasSize.height) || p.canvasSize.height <= 0) return { ok: false, reason: "canvasSize.height must be > 0" };
  if (!Array.isArray(p.tracks)) return { ok: false, reason: "tracks must be an array" };
  for (const t of p.tracks) {
    if (t.kind === "video") {
      for (const c of t.clips) {
        if (!c.sourceUri) return { ok: false, reason: `video clip ${c.id} missing sourceUri` };
        if (c.sourceRange.endMs <= c.sourceRange.startMs) return { ok: false, reason: `video clip ${c.id} sourceRange invalid` };
        if (c.timelineRange.endMs <= c.timelineRange.startMs) return { ok: false, reason: `video clip ${c.id} timelineRange invalid` };
      }
    } else if (t.kind === "audio") {
      for (const c of t.clips) {
        if (!c.sourceUri) return { ok: false, reason: `audio clip ${c.id} missing sourceUri` };
        if (c.sourceRange.endMs <= c.sourceRange.startMs) return { ok: false, reason: `audio clip ${c.id} sourceRange invalid` };
        if (c.timelineRange.endMs <= c.timelineRange.startMs) return { ok: false, reason: `audio clip ${c.id} timelineRange invalid` };
      }
    } else {
      for (const o of t.items) {
        if (o.kind === "text" && typeof o.content !== "string") return { ok: false, reason: `text overlay ${o.id} content must be string` };
        if (o.kind === "image" && !o.uri) return { ok: false, reason: `image overlay ${o.id} missing uri` };
      }
    }
  }
  return { ok: true };
}
