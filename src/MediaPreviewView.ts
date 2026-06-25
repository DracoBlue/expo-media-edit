/**
 * <MediaPreview /> — native preview view. Renders the SAME Project
 * the exporter consumes, through the SAME ProjectCompiler, in an
 * AVPlayer (iOS) / CompositionPlayer (Android). What you see during
 * scrub is what lands in the MP4.
 *
 * Time + playback are externally controlled — pass `time` and
 * `playing` as props. Subscribe to `onTime` to keep the parent's
 * scrub-position in sync during playback.
 *
 * Implemented as a thin createElement wrapper around the native view
 * so this package doesn't pull in a JSX/TSX toolchain for one file.
 */
import { requireNativeViewManager } from 'expo-modules-core';
import type { Project } from './project';

export type MediaPreviewProps = {
  project: Project;
  /** Current playhead in milliseconds. Updates trigger a seek. */
  time?: number;
  /** True = play, false = pause. */
  playing?: boolean;
  /**
   * Preview-only render scale (0.1–1.0). 0.5 ≈ 540p on a 1080p canvas
   * — useful for smooth scrubbing on older iPhones. Ignored on
   * Android (CompositionPlayer renders at source resolution and the
   * surface scales for display). Default 0.5.
   */
  renderScale?: number;
  /** Fired ~30fps during playback. */
  onTime?: (event: { nativeEvent: { ms: number } }) => void;
  /** Fired once after the compiled composition is loaded into the player. */
  onReady?: (event: { nativeEvent: { durationMs: number } }) => void;
  /** Fired on compile / load errors. */
  onError?: (event: { nativeEvent: { message: string } }) => void;
  /** Standard RN view style. Loosely typed to avoid pulling react-native into the lib. */
  style?: unknown;
};

const NativeView: unknown = requireNativeViewManager('ExpoMediaEdit');

export default NativeView as (props: MediaPreviewProps) => unknown;
