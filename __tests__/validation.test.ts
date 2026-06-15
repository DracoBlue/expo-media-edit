import { editVideo, getVideoInfo, generateThumbnail, extractAudio, addProgressListener, cancelEdit } from '../src/index';

// Mock the native module
jest.mock('../src/ExpoMediaEditModule', () => ({
  __esModule: true,
  default: {
    editVideo: jest.fn().mockResolvedValue('file:///output/video.mp4'),
    getVideoInfo: jest.fn().mockResolvedValue({ durationMs: 10000, width: 640, height: 360, fps: 30, fileSize: 2000000 }),
    generateThumbnail: jest.fn().mockResolvedValue('file:///tmp/thumb.jpg'),
    extractAudio: jest.fn().mockResolvedValue('file:///tmp/audio.m4a'),
    cleanTempFiles: jest.fn().mockResolvedValue(3),
    cancelEdit: jest.fn().mockResolvedValue(undefined),
  },
  emitter: { addListener: jest.fn().mockReturnValue({ remove: jest.fn() }) },
}));

describe('editVideo validation', () => {
  it('throws on missing inputUri', async () => {
    await expect(editVideo({ inputUri: '' })).rejects.toThrow('inputUri');
  });

  it('throws on non-string inputUri', async () => {
    // @ts-expect-error
    await expect(editVideo({ inputUri: 123 })).rejects.toThrow('inputUri');
  });

  it('throws on trim startMs >= endMs', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', trim: { startMs: 5000, endMs: 5000 } }))
      .rejects.toThrow('trim.startMs must be less than trim.endMs');
  });

  it('throws on negative trimStart', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', trim: { startMs: -1, endMs: 1000 } }))
      .rejects.toThrow('startMs must be >= 0');
  });

  it('accepts valid trim', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', trim: { startMs: 0, endMs: 5000 } }))
      .resolves.toBe('file:///output/video.mp4');
  });

  it('throws on invalid overlay type', async () => {
    const badOverlay = { type: 'video', x: 0, y: 0 } as any;
    await expect(editVideo({ inputUri: 'file:///v.mp4', overlays: [badOverlay] }))
      .rejects.toThrow("type must be 'text' or 'image'");
  });

  it('throws on out-of-bounds x', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', overlays: [{ type: 'text', content: 'Hi', x: 1.5, y: 0, anchor: 'center', textAlign: 'center', paddingX: 0, paddingY: 0 }] }))
      .rejects.toThrow('x must be a number between 0.0 and 1.0');
  });

  it('throws on missing text content', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', overlays: [{ type: 'text', content: '', x: 0, y: 0, anchor: 'center', textAlign: 'center', paddingX: 0, paddingY: 0 }] }))
      .rejects.toThrow('content is required');
  });

  it('throws when text overlay is missing anchor / textAlign / paddingX / paddingY', async () => {
    // @ts-expect-error — missing required layout fields
    await expect(editVideo({ inputUri: 'file:///v.mp4', overlays: [{ type: 'text', content: 'Hi', x: 0, y: 0 }] }))
      .rejects.toThrow('must include anchor / textAlign / paddingX / paddingY');
  });

  it('throws on path traversal in image overlay URI', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', overlays: [{ type: 'image', uri: 'file:///../../../etc/passwd', x: 0, y: 0, width: 0.2, height: 0.2 }] }))
      .rejects.toThrow('path traversal');
  });

  it('throws on invalid image overlay URI scheme', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', overlays: [{ type: 'image', uri: 'ftp://example.com/img.jpg', x: 0, y: 0, width: 0.2, height: 0.2 }] }))
      .rejects.toThrow('file:// or https://');
  });

  it('throws on invalid audio volume', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', audio: { uri: 'file:///music.mp3', volume: 3 } }))
      .rejects.toThrow('audio.volume must be between 0.0 and 2.0');
  });

  it('throws on path traversal in audio URI', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', audio: { uri: 'file:///../etc/music.mp3' } }))
      .rejects.toThrow('path traversal');
  });

  it('throws on invalid quality', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', quality: 'ultra' as any }))
      .rejects.toThrow("quality must be 'low', 'medium', or 'high'");
  });

  it('accepts quality low/medium/high', async () => {
    for (const q of ['low', 'medium', 'high'] as const) {
      await expect(editVideo({ inputUri: 'file:///v.mp4', quality: q })).resolves.toBeTruthy();
    }
  });

  it('accepts valid text overlay with timing', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ type: 'text', content: 'Hello', x: 0.1, y: 0.9, anchor: 'topLeft', textAlign: 'left', paddingX: 12, paddingY: 6, startMs: 0, endMs: 3000 }],
    })).resolves.toBeTruthy();
  });

  it('throws when overlay startMs >= endMs', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ type: 'text', content: 'Hi', x: 0, y: 0, anchor: 'topLeft', textAlign: 'left', paddingX: 0, paddingY: 0, startMs: 3000, endMs: 1000 }],
    })).rejects.toThrow('startMs must be less than endMs');
  });

  it('rejects http inputUri (cleartext no longer allowed)', async () => {
    await expect(editVideo({ inputUri: 'http://example.com/v.mp4' }))
      .rejects.toThrow('file:// or https://');
  });

  it('rejects path traversal in inputUri', async () => {
    await expect(editVideo({ inputUri: 'file:///../../etc/passwd' }))
      .rejects.toThrow('path traversal');
  });

  // 0.11.0 — new optional text overlay knobs.

  const baseTextOverlay = {
    type: 'text', content: 'Hi', x: 0, y: 0,
    anchor: 'topLeft', textAlign: 'left', paddingX: 0, paddingY: 0,
  } as const;

  it('throws on invalid fontStyle', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ ...baseTextOverlay, fontStyle: 'oblique' as any }],
    })).rejects.toThrow("fontStyle must be 'normal' or 'italic'");
  });

  it('throws on invalid fontFamily', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ ...baseTextOverlay, fontFamily: 'comic-sans' as any }],
    })).rejects.toThrow("fontFamily must be 'system' or 'monospace'");
  });

  it('throws on negative strokeWidth', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ ...baseTextOverlay, strokeColor: '#000', strokeWidth: -1 }],
    })).rejects.toThrow('strokeWidth must be a non-negative number');
  });

  it('throws on negative shadowRadius', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ ...baseTextOverlay, shadowColor: '#000', shadowRadius: -2 }],
    })).rejects.toThrow('shadowRadius must be a non-negative number');
  });

  it('throws on out-of-range shadowOpacity', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{ ...baseTextOverlay, shadowColor: '#000', shadowRadius: 4, shadowOpacity: 1.5 }],
    })).rejects.toThrow('shadowOpacity must be a number between 0.0 and 1.0');
  });

  it('accepts all new text overlay knobs together', async () => {
    await expect(editVideo({
      inputUri: 'file:///v.mp4',
      overlays: [{
        ...baseTextOverlay,
        fontStyle: 'italic',
        fontFamily: 'monospace',
        strokeColor: '#000000', strokeWidth: 4,
        shadowColor: '#FFFFFF', shadowRadius: 8, shadowOpacity: 0.6,
        highlightWord: 'Hi', highlightColor: '#FFD60A',
      }],
    })).resolves.toBeTruthy();
  });
});

describe('outputUri validation', () => {
  it('rejects a non-file outputUri', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', outputUri: 'https://evil.example/x.mp4' }))
      .rejects.toThrow('outputUri must be a file:// URI');
  });

  it('rejects path traversal in outputUri', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', outputUri: 'file:///out/../../etc/x.mp4' }))
      .rejects.toThrow('path traversal');
  });

  it('rejects null bytes in outputUri', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', outputUri: 'file:///out/x\0.mp4' }))
      .rejects.toThrow('null bytes');
  });

  it('accepts a file:// outputUri', async () => {
    await expect(editVideo({ inputUri: 'file:///v.mp4', outputUri: 'file:///tmp/out.mp4' }))
      .resolves.toBeTruthy();
  });
});

describe('read-uri scheme hardening', () => {
  it('rejects a bad scheme in getVideoInfo', async () => {
    await expect(getVideoInfo('content://media/external/video/1')).rejects.toThrow('file:// or https://');
  });

  it('rejects path traversal in generateThumbnail', async () => {
    await expect(generateThumbnail('file:///../etc/passwd', 0)).rejects.toThrow('path traversal');
  });

  it('rejects a bad scheme in extractAudio', async () => {
    await expect(extractAudio('ftp://x/v.mp4')).rejects.toThrow('file:// or https://');
  });
});

describe('addProgressListener', () => {
  it('returns a subscription with remove()', () => {
    const sub = addProgressListener(() => {});
    expect(typeof sub.remove).toBe('function');
    sub.remove();
  });
});

describe('cancelEdit', () => {
  it('resolves without error', async () => {
    await expect(cancelEdit()).resolves.toBeUndefined();
  });
});

describe('getVideoInfo', () => {
  it('throws on empty URI', async () => {
    await expect(getVideoInfo('')).rejects.toThrow('uri is required');
  });

  it('resolves with video metadata', async () => {
    const info = await getVideoInfo('file:///v.mp4');
    expect(info).toMatchObject({ durationMs: expect.any(Number), width: expect.any(Number) });
  });
});

describe('generateThumbnail', () => {
  it('throws on negative timeMs', async () => {
    await expect(generateThumbnail('file:///v.mp4', -1)).rejects.toThrow('timeMs must be a non-negative number');
  });

  it('resolves with URI', async () => {
    await expect(generateThumbnail('file:///v.mp4', 0)).resolves.toBe('file:///tmp/thumb.jpg');
  });
});
