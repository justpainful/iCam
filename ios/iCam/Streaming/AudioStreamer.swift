import Foundation
import AVFoundation
import CoreMedia

/// Prepares captured audio for the wire.
///
/// Phase 1 sends 48 kHz mono 16-bit PCM rather than AAC, deliberately.
/// Uncompressed mono audio is about 768 kbit/s — nothing next to an 8 Mbit/s
/// video stream on a LAN or USB link — and in exchange it costs **zero** encode
/// latency, zero decode latency, and has no priming samples to compensate for.
/// On a link that cannot afford it, the protocol already carries an AAC codec
/// id; the transport decides, not the capture path.
final class AudioStreamer: AudioFrameSink {

    /// The exact format `AVCaptureAudioDataOutput` is asked to deliver, so this
    /// class copies bytes instead of converting them.
    static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

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

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var lengthAtOffset = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, totalLength > 0 else { return }

        // Muting sends silence of the same length, so the receiver's clock
        // and jitter buffer keep running exactly as before.
        let payload = muted ? Data(count: totalLength) : Data(bytes: pointer, count: totalLength)
        guard !payload.isEmpty else { return }

        var sampleRate: UInt32 = 48_000
        var channels: UInt8 = 1
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            sampleRate = UInt32(asbd.pointee.mSampleRate)
            channels = UInt8(max(1, asbd.pointee.mChannelsPerFrame))
        }

        sequence &+= 1
        handler(Packet(data: payload,
                       ptsUs: MonotonicClock.us(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                       sampleRate: sampleRate,
                       channels: channels,
                       sequence: sequence))
    }
}
