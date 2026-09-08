// Copyright © 2026 Anton Novoselov. All rights reserved.

@preconcurrency import AVFoundation
import Foundation

/// Result of the inexpensive local checks performed before sending a
/// recording to a transcription provider.
public enum AudioRecordingValidation: Equatable, Sendable {
    case valid
    case tooShort
    case silent
}

/// Checks duration and signal level without making a network request.
///
/// The recorder writes AAC/m4a on macOS, while tests and other clients may
/// provide PCM WAV. AVAudioFile decodes both formats, so the same check can
/// be used for a fresh recording and for a retained failed recording.
public enum AudioRecordingValidator {
    public static let defaultMinimumDuration: TimeInterval = 0.3

    // About -54 dBFS RMS and -40 dBFS peak. Requiring both to be below the
    // threshold avoids rejecting a quiet but intelligible recording while
    // still catching an empty microphone input.
    private static let silenceRMSThreshold = 0.002
    private static let silencePeakThreshold = 0.01

    public static func validate(
        url: URL,
        minimumDuration: TimeInterval = defaultMinimumDuration
    ) throws -> AudioRecordingValidation {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return .silent }

        let duration = Double(file.length) / sampleRate
        guard duration >= minimumDuration else {
            return .tooShort
        }

        guard file.length > 0 else { return .silent }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: 4_096
        ) else {
            return .silent
        }

        var sampleCount = 0
        var sumOfSquares = 0.0
        var peak = 0.0

        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let framesToRead = min(remaining, 4_096)
            try file.read(into: buffer, frameCount: framesToRead)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }

            accumulate(
                buffer: buffer,
                frameCount: frameCount,
                sampleCount: &sampleCount,
                sumOfSquares: &sumOfSquares,
                peak: &peak
            )
        }

        guard sampleCount > 0 else { return .silent }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        return rms < silenceRMSThreshold && peak < silencePeakThreshold ? .silent : .valid
    }

    private static func accumulate(
        buffer: AVAudioPCMBuffer,
        frameCount: Int,
        sampleCount: inout Int,
        sumOfSquares: inout Double,
        peak: inout Double
    ) {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }

        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let value = Double(samples[frame])
                    let magnitude = abs(value)
                    sumOfSquares += value * value
                    peak = max(peak, magnitude)
                }
            }
            sampleCount += frameCount * channelCount
            return
        }

        if let channels = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let value = Double(samples[frame]) / 32_768.0
                    let magnitude = abs(value)
                    sumOfSquares += value * value
                    peak = max(peak, magnitude)
                }
            }
            sampleCount += frameCount * channelCount
        }
    }
}
