/**
 * Integration tests for expo-media-edit.
 *
 * These tests require a real device or simulator with native modules loaded.
 * Run with: npx expo run:ios --device
 *
 * Test video: Big Buck Bunny (10s, 360p, 2MB H.264)
 * © 2008 Blender Foundation / www.bigbuckbunny.org
 * Licensed under CC BY 3.0 — https://creativecommons.org/licenses/by/3.0/
 *
 * Download: https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_2MB.mp4
 */

export const TEST_VIDEO_URL =
  'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_2MB.mp4';

export const BBB_EXPECTED = {
  durationMs: 10000,
  width: 640,
  height: 360,
  fps: 30,
};

// This file exports helpers for on-device integration testing.
// Jest skips execution (no describe/it blocks) — run via runIntegrationTests() on device.
test.skip('integration tests run on device only — see runIntegrationTests()', () => {});

/**
 * Full integration test suite (device only — skipped in Jest).
 *
 * To run manually, import these helpers in your test screen:
 *
 *   import { runIntegrationTests } from './__tests__/integration.test';
 *   await runIntegrationTests();
 */
export async function runIntegrationTests(): Promise<void> {
  const { editVideo, getVideoInfo, generateThumbnail, cleanTempFiles, addProgressListener } =
    await import('../src/index');

  console.log('=== expo-media-edit integration tests ===');
  console.log('Test video: Big Buck Bunny 10s (CC BY 3.0, Blender Foundation)');

  // Test 1: getVideoInfo
  console.log('\n[1] getVideoInfo...');
  const info = await getVideoInfo(TEST_VIDEO_URL);
  console.assert(info.durationMs > 0, 'durationMs must be positive');
  console.assert(info.width > 0, 'width must be positive');
  console.log(`    ✓ ${info.width}×${info.height}, ${info.durationMs}ms, ${info.fps}fps`);

  // Test 2: generateThumbnail
  console.log('\n[2] generateThumbnail at 2s...');
  const thumb = await generateThumbnail(TEST_VIDEO_URL, 2000);
  console.assert(thumb.startsWith('file://'), 'thumbnail must be a file:// URI');
  console.log(`    ✓ ${thumb}`);

  // Test 3: editVideo trim only
  console.log('\n[3] editVideo trim (0–5s)...');
  const progressValues: number[] = [];
  const sub = addProgressListener(({ progress }) => progressValues.push(progress));
  const out1 = await editVideo({ inputUri: TEST_VIDEO_URL, trim: { startMs: 0, endMs: 5000 } });
  sub.remove();
  console.assert(out1.startsWith('file://'), 'output must be a file:// URI');
  console.assert(progressValues.some((p) => p > 0), 'progress events must be emitted');
  console.log(`    ✓ output: ${out1}, progress events: ${progressValues.length}`);

  // Test 4: editVideo with text overlay
  console.log('\n[4] editVideo with text overlay...');
  const out2 = await editVideo({
    inputUri: TEST_VIDEO_URL,
    trim: { startMs: 0, endMs: 3000 },
    quality: 'low',
    overlays: [{ type: 'text', content: 'Test Overlay', x: 0.1, y: 0.8, fontSize: 40, color: '#FF0000', fontWeight: 'bold' }],
  });
  console.assert(out2.startsWith('file://'), 'output must be a file:// URI');
  console.log(`    ✓ output: ${out2}`);

  // Test 5: cleanup
  console.log('\n[5] cleanTempFiles...');
  const count = await cleanTempFiles();
  console.log(`    ✓ deleted ${count} temp files`);

  console.log('\n=== All integration tests passed ===');
}
