import {
  createProject,
  applyEdit,
  projectDurationMs,
  validateProject,
  makeClipId,
  SCHEMA_VERSION,
  type Project,
  type VideoClip,
  type AudioClip,
  type TextOverlayClip,
} from "../src/project";

const mkVideo = (id: string, t0: number, t1: number): VideoClip => ({
  id,
  sourceUri: `file:///v/${id}.mp4`,
  sourceRange: { startMs: 0, endMs: t1 - t0 },
  timelineRange: { startMs: t0, endMs: t1 },
});
const mkAudio = (id: string, t0: number, t1: number): AudioClip => ({
  id,
  sourceUri: `file:///a/${id}.mp3`,
  sourceRange: { startMs: 0, endMs: t1 - t0 },
  timelineRange: { startMs: t0, endMs: t1 },
});
const mkText = (id: string, content: string, t0?: number, t1?: number): TextOverlayClip => ({
  id, kind: "text", content,
  x: 0.5, y: 0.5, anchor: "center", textAlign: "center",
  paddingX: 12, paddingY: 8,
  timelineRange: t0 !== undefined && t1 !== undefined ? { startMs: t0, endMs: t1 } : undefined,
});

describe("createProject", () => {
  it("stamps schemaVersion + generates id when omitted", () => {
    const p = createProject({ canvasSize: { width: 1080, height: 1920 } });
    expect(p.schemaVersion).toBe(SCHEMA_VERSION);
    expect(p.id).toMatch(/^proj_/);
    expect(p.canvasSize).toEqual({ width: 1080, height: 1920 });
    expect(p.tracks).toEqual([]);
    expect(p.durationMs).toBe(0);
  });

  it("computes durationMs from initial tracks", () => {
    const p = createProject({
      canvasSize: { width: 1080, height: 1920 },
      tracks: [{ kind: "video", id: "v1", clips: [mkVideo("c1", 0, 5000), mkVideo("c2", 5000, 8000)] }],
    });
    expect(p.durationMs).toBe(8000);
  });
});

describe("projectDurationMs", () => {
  it("returns the max endMs across all tracks", () => {
    expect(projectDurationMs({
      tracks: [
        { kind: "video", id: "v", clips: [mkVideo("c1", 0, 5000)] },
        { kind: "audio", id: "a", clips: [mkAudio("a1", 0, 7000)] },
        { kind: "overlay", id: "o", items: [mkText("o1", "hi", 1000, 3000)] },
      ],
    })).toBe(7000);
  });

  it("ignores overlays without a timelineRange", () => {
    expect(projectDurationMs({
      tracks: [
        { kind: "video", id: "v", clips: [mkVideo("c1", 0, 5000)] },
        { kind: "overlay", id: "o", items: [mkText("o1", "always")] },
      ],
    })).toBe(5000);
  });
});

describe("applyEdit immutability", () => {
  const base = createProject({
    canvasSize: { width: 1080, height: 1920 },
    tracks: [{ kind: "video", id: "v", clips: [mkVideo("c1", 0, 3000)] }],
  });

  it("returns a new project for setCanvasSize without mutating the input", () => {
    const next = applyEdit(base, { type: "setCanvasSize", width: 720, height: 1280 });
    expect(next).not.toBe(base);
    expect(next.canvasSize).toEqual({ width: 720, height: 1280 });
    expect(base.canvasSize).toEqual({ width: 1080, height: 1920 });
  });

  it("addVideoClip appends + updates durationMs", () => {
    const next = applyEdit(base, {
      type: "addVideoClip",
      trackId: "v",
      clip: mkVideo("c2", 3000, 6000),
    });
    expect(next.tracks[0]).toMatchObject({ kind: "video" });
    expect((next.tracks[0] as any).clips).toHaveLength(2);
    expect(next.durationMs).toBe(6000);
    expect((base.tracks[0] as any).clips).toHaveLength(1);
    expect(base.durationMs).toBe(3000);
  });

  it("removeClip drops the clip + recomputes durationMs", () => {
    const withTwo = applyEdit(base, {
      type: "addVideoClip",
      trackId: "v",
      clip: mkVideo("c2", 3000, 6000),
    });
    const next = applyEdit(withTwo, { type: "removeClip", trackId: "v", clipId: "c2" });
    expect((next.tracks[0] as any).clips).toHaveLength(1);
    expect(next.durationMs).toBe(3000);
  });

  it("replaceOverlay swaps the item by id", () => {
    const proj = createProject({
      canvasSize: { width: 1080, height: 1920 },
      tracks: [{ kind: "overlay", id: "ov", items: [mkText("t1", "old", 0, 1000)] }],
    });
    const next = applyEdit(proj, {
      type: "replaceOverlay", trackId: "ov", itemId: "t1",
      item: mkText("t1", "new", 0, 1000),
    });
    expect((next.tracks[0] as any).items[0].content).toBe("new");
    expect((proj.tracks[0] as any).items[0].content).toBe("old");
  });

  it("removeTrack drops the track", () => {
    const next = applyEdit(base, { type: "removeTrack", trackId: "v" });
    expect(next.tracks).toHaveLength(0);
    expect(next.durationMs).toBe(0);
  });
});

describe("validateProject", () => {
  it("accepts a well-formed project", () => {
    const p = createProject({
      canvasSize: { width: 1080, height: 1920 },
      tracks: [{ kind: "video", id: "v", clips: [mkVideo("c1", 0, 1000)] }],
    });
    expect(validateProject(p)).toEqual({ ok: true });
  });

  it("rejects unsupported schemaVersion", () => {
    const p = createProject({ canvasSize: { width: 1080, height: 1920 } });
    const corrupted: Project = { ...p, schemaVersion: 999 as any };
    const r = validateProject(corrupted);
    expect(r.ok).toBe(false);
  });

  it("rejects non-positive canvas dimensions", () => {
    const p = createProject({ canvasSize: { width: 0, height: 1920 } });
    expect(validateProject(p).ok).toBe(false);
  });

  it("rejects video clip with inverted sourceRange", () => {
    const p = createProject({
      canvasSize: { width: 1080, height: 1920 },
      tracks: [{
        kind: "video", id: "v", clips: [{
          id: "c1", sourceUri: "file:///x.mp4",
          sourceRange: { startMs: 1000, endMs: 0 },
          timelineRange: { startMs: 0, endMs: 1000 },
        }],
      }],
    });
    expect(validateProject(p).ok).toBe(false);
  });
});

describe("makeClipId", () => {
  it("returns unique ids with optional prefix", () => {
    const a = makeClipId();
    const b = makeClipId();
    const c = makeClipId("text");
    expect(a).not.toBe(b);
    expect(c).toMatch(/^text_/);
  });
});
