import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Prepares captured audio for the wire.
///
/// Phase 1 sends 16-bit PCM rather than AAC, deliberately. Mono PCM at the
/// session rate is under 800 kbit/s — nothing next to an 8 Mbit/s video stream
/// on a LAN or USB link — and in exchange it costs **zero** encode latency,
/// zero decode latency, and has no priming samples to compensate for. On a link
/// that cannot afford it, the protocol already carries an AAC codec id; the
/// transport decides, not the capture path.
///
/// `AVCaptureAudioDataOutput.audioSettings` is macOS-only, so on iOS the format
/// is whatever the session negotiated. This class reads the real description off
/// every buffer rather than assuming one, and converts only when it has to.
final class AudioStreamer: AudioFrameSink {

    struct Packet {
        var data: Data
        var ptsUs: UInt64
        var sampleRate: UInt32
        var channels: UInt8
        var sequence: UInt32
    }

    /// Called on the capture audio queue.
    var onPacket: ((Packet) -> Void)?

    private(set) var isEnabled = false
    private(set) var isMuted = false
    private var sequence: UInt32 = 0
    private let lock = NSLock()

    /// Non-zero when a buffer arrived in a layout this class cannot convert.
    /// Surfaced in diagnostics rather than silently producing noise.
    private(set) var unsupportedBuffers: UInt64 = 0

    func setEnabled(_ enabled: Bool) {
        lock.lock(); isEnabled = enabled; lock.unlock()
    }

    /// Mute sends silence rather than stopping the stream: a receiver that sees
    /// audio simply stop has no way to tell mute from a dead connection, and
    /// most conferencing apps handle a gap badly.
    func setMuted(_ muted: Bool) {
        lock.lock(); isMuted = muted; lock.unlock()
    }

    func receive(audio sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let enabled = isEnabled
        let muted = isMuted
        lock.unlock()
        guard enabled, let handler = onPacket else { return }

        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var lengthAtOffset = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, totalLength > 0 else { return }

        let channels = UInt8(max(1, asbd.mChannelsPerFrame))
        guard let payload = Self.convertToInt16(pointer: pointer,
                                                byteCount: totalLength,
                                                asbd: asbd) else {
            unsupportedBuffers &+= 1
            return
        }

        sequence &+= 1
        handler(Packet(data: muted ? Data(count: payload.count) : payload,
                       ptsUs: MonotonicClock.us(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                       sampleRate: UInt32(asbd.mSampleRate),
                       channels: channels,
                       sequence: sequence))
    }

    /// Produces interleaved little-endian `Int16` from whatever iOS delivered.
    ///
    /// In practice this is a pass-through: the capture session hands out
    /// packed 16-bit PCM on every iPhone iCam supports. The float path exists
    /// because "in practice" is not a guarantee, and a few hundred samples of
    /// mono per buffer is a rounding error either way.
    private static func convertToInt16(pointer: UnsafeMutablePointer<Int8>,
                                       byteCount: Int,
                                       asbd: AudioStreamBasicDescription) -> Data? {
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // Big-endian and non-interleaved never occur on iOS capture. Refusing
        // them is more honest than deinterleaving something we cannot test.
        guard !isBigEndian, !isNonInterleaved else { return nil }

        if !isFloat && asbd.mBitsPerChannel == 16 {
            return Data(bytes: pointer, count: byteCount)
        }

        if isFloat && asbd.mBitsPerChannel == 32 {
            let sampleCount = byteCount / MemoryLayout<Float>.size
            var output = Data(count: sampleCount * MemoryLayout<Int16>.size)
            pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floats in
                output.withUnsafeMutableBytes { raw in
                    guard let destination = raw.bindMemory(to: Int16.self).baseAddress else { return }
                    for index in 0 ..< sampleCount {
                        // Clamp before scaling: a float sample can legitimately
                        // exceed ±1.0, and wrapping it would be an audible click
                        // rather than the clip the user actually caused.
                        let clamped = max(-1.0, min(1.0, floats[index]))
                        destination[index] = Int16(clamped * 32767.0)
                    }
                }
            }
            return output
        }

        return nil
    }
}
