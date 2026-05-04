import AVFoundation

public class AudioMixer {

  public static func buildAudioMix(
    composition: AVMutableComposition,
    originalTrack: AVMutableCompositionTrack?,
    musicOptions: AudioMixOptions?
  ) -> AVAudioMix? {
    var inputParameters: [AVMutableAudioMixInputParameters] = []

    // Original audio volume
    if let originalTrack = originalTrack {
      let params = AVMutableAudioMixInputParameters(track: originalTrack)
      params.setVolume(Float(musicOptions?.originalVolume ?? (musicOptions == nil ? 1.0 : 0.0)), at: .zero)
      inputParameters.append(params)
    }

    // Music track
    if let musicOpts = musicOptions, let musicURL = URL(string: musicOpts.uri) {
      let musicAsset = AVAsset(url: musicURL)
      guard let musicSourceTrack = musicAsset.tracks(withMediaType: .audio).first else {
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        return audioMix
      }

      guard let musicTrack = composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ) else {
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        return audioMix
      }

      let videoDuration = composition.duration
      let musicStartTime = CMTime(value: CMTimeValue(musicOpts.startMs), timescale: 1000)

      let musicDuration = musicAsset.duration
      let insertDuration = musicOpts.trimToVideo
        ? CMTimeSubtract(videoDuration, musicStartTime)
        : musicDuration

      let musicTimeRange = CMTimeRange(start: .zero, duration: insertDuration)

      try? musicTrack.insertTimeRange(musicTimeRange, of: musicSourceTrack, at: musicStartTime)

      let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
      musicParams.setVolume(Float(musicOpts.volume), at: .zero)
      inputParameters.append(musicParams)
    }

    guard !inputParameters.isEmpty else { return nil }

    let audioMix = AVMutableAudioMix()
    audioMix.inputParameters = inputParameters
    return audioMix
  }
}
