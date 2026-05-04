// Validation tests run in Node (no native module needed).
// We mock the native module so imports resolve.
jest.mock('../src/ExpoMediaEditModule', () => ({
  __esModule: true,
  default: {
    editVideo: jest.fn(),
    getVideoInfo: jest.fn(),
    generateThumbnail: jest.fn(),
    cleanTempFiles: jest.fn(),
  },
}));

import { editVideo, getVideoInfo, generateThumbnail } from '../src/index';

describe('editVideo input validation', () => {
  it('throws when inputUri is missing', async () => {
    await expect(editVideo({ inputUri: '' })).rejects.toThrow('inputUri');
  });

  it('throws when inputUri is not a string', async () => {
    // @ts-expect-error — intentional bad input
    await expect(editVideo({ inputUri: 42 })).rejects.toThrow('inputUri');
  });

  it('throws when trim.startMs >= trim.endMs', async () => {
    await expect(
      editVideo({ inputUri: 'file:///video.mp4', trim: { startMs: 5000, endMs: 5000 } })
    ).rejects.toThrow('trim.startMs must be less than trim.endMs');
  });

  it('throws when trim.startMs > trim.endMs', async () => {
    await expect(
      editVideo({ inputUri: 'file:///video.mp4', trim: { startMs: 6000, endMs: 3000 } })
    ).rejects.toThrow('trim.startMs must be less than trim.endMs');
  });

  it('throws when trim.startMs is negative', async () => {
    await expect(
      editVideo({ inputUri: 'file:///video.mp4', trim: { startMs: -1, endMs: 5000 } })
    ).rejects.toThrow('trim.startMs');
  });

  it('throws when overlay type is invalid', async () => {
    await expect(
      editVideo({
        inputUri: 'file:///video.mp4',
        // @ts-expect-error — intentional bad input
        overlays: [{ type: 'video', x: 0.1, y: 0.1 }],
      })
    ).rejects.toThrow("overlays[0].type must be 'text' or 'image'");
  });

  it('throws when text overlay has no content', async () => {
    await expect(
      editVideo({
        inputUri: 'file:///video.mp4',
        // @ts-expect-error — intentional bad input
        overlays: [{ type: 'text', x: 0.1, y: 0.1 }],
      })
    ).rejects.toThrow('content');
  });

  it('throws when image overlay has no uri', async () => {
    await expect(
      editVideo({
        inputUri: 'file:///video.mp4',
        // @ts-expect-error — intentional bad input
        overlays: [{ type: 'image', x: 0.1, y: 0.1, width: 0.2, height: 0.2 }],
      })
    ).rejects.toThrow('uri');
  });

  it('throws when image overlay width is out of range', async () => {
    await expect(
      editVideo({
        inputUri: 'file:///video.mp4',
        overlays: [{ type: 'image', uri: 'file:///img.png', x: 0.1, y: 0.1, width: 1.5, height: 0.2 }],
      })
    ).rejects.toThrow('width');
  });

  it('throws when audio.uri is empty', async () => {
    await expect(
      editVideo({ inputUri: 'file:///video.mp4', audio: { uri: '' } })
    ).rejects.toThrow('audio.uri');
  });

  it('passes with minimal valid job', async () => {
    const mockModule = require('../src/ExpoMediaEditModule').default;
    mockModule.editVideo.mockResolvedValue('file:///output.mp4');
    const result = await editVideo({ inputUri: 'file:///video.mp4' });
    expect(result).toBe('file:///output.mp4');
  });

  it('passes with full valid job', async () => {
    const mockModule = require('../src/ExpoMediaEditModule').default;
    mockModule.editVideo.mockResolvedValue('file:///output.mp4');
    const result = await editVideo({
      inputUri: 'file:///video.mp4',
      outputUri: 'file:///out.mp4',
      trim: { startMs: 0, endMs: 15000 },
      overlays: [
        { type: 'text', content: 'Hello', x: 0.1, y: 0.8, fontSize: 40, color: '#FFFFFF' },
        { type: 'image', uri: 'file:///logo.png', x: 0.7, y: 0.05, width: 0.2, height: 0.1 },
      ],
      audio: { uri: 'file:///music.mp3', volume: 0.8, originalVolume: 0.2 },
    });
    expect(result).toBe('file:///output.mp4');
  });
});

describe('getVideoInfo input validation', () => {
  it('throws when uri is empty', async () => {
    await expect(getVideoInfo('')).rejects.toThrow('uri');
  });
});

describe('generateThumbnail input validation', () => {
  it('throws when uri is empty', async () => {
    await expect(generateThumbnail('', 0)).rejects.toThrow('uri');
  });

  it('throws when timeMs is negative', async () => {
    await expect(generateThumbnail('file:///video.mp4', -1)).rejects.toThrow('timeMs');
  });
});
