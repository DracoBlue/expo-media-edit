// Pre-bridge validation for exportProject / metadata helpers. The
// native module is mocked so these tests only cover the JS-side
// guards that defend against malformed inputs before the JNI/Obj-C
// call happens.

jest.mock('expo-modules-core', () => ({
  requireNativeModule: () => ({}),
  requireNativeViewManager: () => () => null,
  EventEmitter: class {
    addListener() { return { remove: () => undefined }; }
  },
}));

jest.mock('../src/ExpoMediaEditModule', () => ({
  __esModule: true,
  default: {
    exportProject: jest.fn().mockResolvedValue('file:///tmp/out.mp4'),
    cancelExport: jest.fn().mockResolvedValue(undefined),
    getVideoInfo: jest.fn().mockResolvedValue({}),
    generateThumbnail: jest.fn().mockResolvedValue('file:///tmp/t.jpg'),
    extractAudio: jest.fn().mockResolvedValue('file:///tmp/a.m4a'),
    cleanTempFiles: jest.fn().mockResolvedValue(0),
  },
  emitter: { addListener: () => ({ remove: () => undefined }) },
}));

import {
  exportProject, cancelExport,
  getVideoInfo, generateThumbnail, extractAudio, cleanTempFiles,
  createProject,
} from '../src/index';
import ExpoMediaEditModule from '../src/ExpoMediaEditModule';

const baseProject = createProject({ canvasSize: { width: 1080, height: 1920 } });

describe('exportProject', () => {
  beforeEach(() => jest.clearAllMocks());

  it('forwards the project + options to the native module', async () => {
    await exportProject(baseProject, 'file:///tmp/out.mp4', { quality: 'medium' });
    expect(ExpoMediaEditModule.exportProject).toHaveBeenCalledWith(
      baseProject, 'file:///tmp/out.mp4', { quality: 'medium' },
    );
  });

  it('allows omitting outputUri (native picks a temp path)', async () => {
    await exportProject(baseProject);
    expect(ExpoMediaEditModule.exportProject).toHaveBeenCalledWith(baseProject, null, null);
  });

  it('rejects null-byte in outputUri', async () => {
    await expect(exportProject(baseProject, 'file:///tmp/x\0.mp4')).rejects.toThrow(/null bytes/);
  });
  it('rejects path traversal in outputUri', async () => {
    await expect(exportProject(baseProject, 'file:///tmp/../escape.mp4')).rejects.toThrow(/path traversal/);
  });
  it('rejects non-file:// outputUri', async () => {
    await expect(exportProject(baseProject, 'https://x/y.mp4')).rejects.toThrow(/file:\/\/ URI/);
  });
  it('rejects unknown quality preset', async () => {
    // @ts-expect-error
    await expect(exportProject(baseProject, undefined, { quality: 'huge' })).rejects.toThrow(/quality/);
  });
});

describe('cancelExport', () => {
  it('calls the native cancel', async () => {
    await cancelExport();
    expect(ExpoMediaEditModule.cancelExport).toHaveBeenCalled();
  });
});

describe('metadata helpers (URI gates)', () => {
  it('getVideoInfo rejects malformed uri', async () => {
    await expect(getVideoInfo('http://insecure/v.mp4')).rejects.toThrow(/file:\/\/ or https:\/\//);
    await expect(getVideoInfo('file:///x/../y.mp4')).rejects.toThrow(/path traversal/);
  });
  it('generateThumbnail rejects negative timeMs', async () => {
    await expect(generateThumbnail('file:///v.mp4', -1)).rejects.toThrow(/non-negative/);
  });
  it('extractAudio enforces uri scheme', async () => {
    await expect(extractAudio('ftp://x/a')).rejects.toThrow(/file:\/\/ or https:\/\//);
  });
  it('cleanTempFiles is a passthrough', async () => {
    await cleanTempFiles();
    expect(ExpoMediaEditModule.cleanTempFiles).toHaveBeenCalled();
  });
});
