import XCTest
import CryptoKit
@testable import iCam

final class FrameParserTests: XCTestCase {

    func testRoundTripsASingleFrame() throws {
        let frame = Frame(channel: .control, payload: Data("hello".utf8))
        var parser = FrameParser()
        parser.append(frame.encoded)

        let result = try XCTUnwrap(parser.next())
        XCTAssertEqual(result.frame, frame)
        XCTAssertEqual(result.header.count, Wire.headerSize)
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    func testHeaderIsExactlyTheAssociatedData() throws {
        let payload = Data(repeating: 7, count: 40)
        let frame = Frame(channel: .video, payload: payload)
        var parser = FrameParser()
        parser.append(frame.encoded)

        let result = try XCTUnwrap(parser.next())
        // The header handed back must be byte-identical to the one the sender
        // built, or AEAD verification fails on every frame.
        XCTAssertEqual(result.header,
                       Frame.header(channel: .video, flags: .endOfMessage,
                                    payloadCount: payload.count))
    }

    func testWaitsForTheRestOfAFrame() throws {
        let frame = Frame(channel: .control, payload: Data(repeating: 1, count: 100))
        let encoded = frame.encoded
        var parser = FrameParser()

        parser.append(encoded.prefix(20))
        XCTAssertNil(try parser.next())

        parser.append(encoded.dropFirst(20))
        let result = try XCTUnwrap(parser.next())
        XCTAssertEqual(result.frame.payload.count, 100)
    }

    func testParsesSeveralFramesFromOneRead() throws {
        var buffer = Data()
        for i in 0 ..< 5 {
            buffer.append(Frame(channel: .control, payload: Data([UInt8(i)])).encoded)
        }
        var parser = FrameParser()
        parser.append(buffer)

        for i in 0 ..< 5 {
            let result = try XCTUnwrap(parser.next())
            XCTAssertEqual(result.frame.payload, Data([UInt8(i)]))
        }
        XCTAssertNil(try parser.next())
    }

    func testRejectsAnOversizedFrame() {
        var buffer = Data()
        buffer.appendUInt32BE(UInt32(Wire.maxFrameLength + 1))
        buffer.append(contentsOf: [1, 1, 0, 0])
        var parser = FrameParser()
        parser.append(buffer)

        XCTAssertThrowsError(try parser.next()) { error in
            XCTAssertEqual(error as? FrameError, .oversizedFrame(Wire.maxFrameLength + 1))
        }
    }

    func testSkipsAnUnknownChannelWithoutLosingTheStream() throws {
        var buffer = Data()
        let payload = Data("skip me".utf8)
        buffer.appendUInt32BE(UInt32(payload.count + 4))
        buffer.append(contentsOf: [99, 1, 0, 0])
        buffer.append(payload)
        buffer.append(Frame(channel: .control, payload: Data("keep me".utf8)).encoded)

        var parser = FrameParser()
        parser.append(buffer)

        // An unknown channel is reported, but the bytes are consumed so the
        // next frame still parses. A newer peer must not break an older one.
        XCTAssertThrowsError(try parser.next())
        let result = try XCTUnwrap(parser.next())
        XCTAssertEqual(result.frame.payload, Data("keep me".utf8))
    }

    func testRejectsANonZeroReservedField() {
        var buffer = Data()
        buffer.appendUInt32BE(4)
        buffer.append(contentsOf: [1, 1, 0, 9])
        var parser = FrameParser()
        parser.append(buffer)
        XCTAssertThrowsError(try parser.next())
    }
}

final class SecureChannelTests: XCTestCase {

    private func makePair() throws -> (initiator: SecureChannel, responder: SecureChannel, keys: SessionKeys) {
        let a = P256.KeyAgreement.PrivateKey()
        let b = P256.KeyAgreement.PrivateKey()
        let shared = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
        let keys = SessionKeys.derive(sharedSecret: shared,
                                      clientRandom: Data(repeating: 1, count: 32),
                                      serverRandom: Data(repeating: 2, count: 32))
        return (SecureChannel(keys: keys, role: .initiator),
                SecureChannel(keys: keys, role: .responder),
                keys)
    }

    func testSealAndOpen() throws {
        let (initiator, responder, _) = try makePair()
        let plaintext = Data("camera.state".utf8)

        let wire = try initiator.seal(channel: .control, plaintext: plaintext)
        var parser = FrameParser()
        parser.append(wire)
        let frame = try XCTUnwrap(parser.next())

        let opened = try responder.open(header: frame.header, payload: frame.frame.payload)
        XCTAssertEqual(opened, plaintext)
    }

    func testLengthAccountsForTheTag() throws {
        let (initiator, _, _) = try makePair()
        let plaintext = Data(repeating: 3, count: 64)
        let wire = try initiator.seal(channel: .video, plaintext: plaintext)

        // 4 header bytes after `length`, plus ciphertext, plus a 16-byte tag.
        XCTAssertEqual(Int(wire.readUInt32BE(at: 0)), 4 + plaintext.count + 16)
        XCTAssertEqual(wire.count, Wire.headerSize + plaintext.count + 16)
    }

    func testCounterAdvancesAcrossChannels() throws {
        let (initiator, responder, _) = try makePair()
        let channels: [Channel] = [.control, .video, .audio, .control]

        var parser = FrameParser()
        for channel in channels {
            parser.append(try initiator.seal(channel: channel,
                                             plaintext: Data("\(channel.rawValue)".utf8)))
        }
        for channel in channels {
            let frame = try XCTUnwrap(parser.next())
            let opened = try responder.open(header: frame.header, payload: frame.frame.payload)
            XCTAssertEqual(opened, Data("\(channel.rawValue)".utf8))
        }
        XCTAssertEqual(initiator.framesSent, 4)
        XCTAssertEqual(responder.framesReceived, 4)
    }

    func testAReorderedFrameFailsToOpen() throws {
        let (initiator, responder, _) = try makePair()
        var parser = FrameParser()
        parser.append(try initiator.seal(channel: .control, plaintext: Data("first".utf8)))
        parser.append(try initiator.seal(channel: .control, plaintext: Data("second".utf8)))

        let first = try XCTUnwrap(parser.next())
        let second = try XCTUnwrap(parser.next())

        // Opening the second frame while the receiver still expects the first
        // must fail: the nonce is bound to the counter.
        XCTAssertThrowsError(try responder.open(header: second.header,
                                                payload: second.frame.payload))
        _ = first
    }

    func testATamperedHeaderFailsToOpen() throws {
        let (initiator, responder, _) = try makePair()
        var parser = FrameParser()
        parser.append(try initiator.seal(channel: .control, plaintext: Data("payload".utf8)))
        let frame = try XCTUnwrap(parser.next())

        var tampered = frame.header
        tampered[tampered.startIndex + 4] = Channel.video.rawValue
        XCTAssertThrowsError(try responder.open(header: tampered, payload: frame.frame.payload))
    }

    func testPairingDigitsAreSixDigitsAndDeterministic() throws {
        let (_, _, keys) = try makePair()
        XCTAssertEqual(keys.pairingDigits.count, 6)
        XCTAssertTrue(keys.pairingDigits.allSatisfy(\.isNumber))

        let a = P256.KeyAgreement.PrivateKey()
        let b = P256.KeyAgreement.PrivateKey()
        let shared = try a.sharedSecretFromKeyAgreement(with: b.publicKey)
        let first = SessionKeys.derive(sharedSecret: shared,
                                       clientRandom: Data(repeating: 9, count: 32),
                                       serverRandom: Data(repeating: 8, count: 32))
        let second = SessionKeys.derive(sharedSecret: shared,
                                        clientRandom: Data(repeating: 9, count: 32),
                                        serverRandom: Data(repeating: 8, count: 32))
        XCTAssertEqual(first, second)
    }

    func testDirectionKeysDiffer() throws {
        let (_, _, keys) = try makePair()
        XCTAssertNotEqual(keys.c2sKey, keys.s2cKey)
        XCTAssertNotEqual(keys.c2sSalt, keys.s2cSalt)
        XCTAssertEqual(keys.c2sKey.count, 32)
        XCTAssertEqual(keys.c2sSalt.count, 4)
    }
}

final class HandshakeCodecTests: XCTestCase {

    func testHandshakeJSONHasSortedKeysAndNoEscapedSlashes() throws {
        let hello = ClientHello(eph: Data([4, 1, 2]),
                               idk: Data([4, 3, 4]),
                               rnd: Data([5]),
                               dev: DeviceInfo(name: "a/b", model: "m", os: "18.5",
                                               app: "1.0", id: "ff"))
        let encoded = try HandshakeCodec.encode(hello)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.contains("\\/"), "forward slashes must not be escaped")
        // Sorted keys: dev, eph, idk, rnd, t, v.
        let order = ["\"dev\"", "\"eph\"", "\"idk\"", "\"rnd\"", "\"t\"", "\"v\""]
        var cursor = text.startIndex
        for key in order {
            let found = try XCTUnwrap(text.range(of: key, range: cursor ..< text.endIndex))
            cursor = found.upperBound
        }
    }

    func testTranscriptBytesOmitTheSignature() throws {
        var hello = ServerHello(eph: Data([4]), idk: Data([4]), rnd: Data([1]),
                                dev: DeviceInfo(name: "PC", model: "Windows", os: "11",
                                                app: "1.0", id: "aa"))
        hello.sig = Data([9, 9, 9])

        let transcript = try hello.transcriptBytes()
        let text = try XCTUnwrap(String(data: transcript, encoding: .utf8))
        XCTAssertFalse(text.contains("\"sig\""))
    }

    func testIdentitySignatureVerifies() throws {
        let identity = DeviceIdentity(privateKey: .init())
        let message = Data("iCam/v1/client transcript".utf8)
        let signature = try identity.sign(message)

        XCTAssertTrue(DeviceIdentity.verify(signature: signature, message: message,
                                            publicKey: identity.publicKeyData))
        XCTAssertFalse(DeviceIdentity.verify(signature: signature,
                                             message: Data("different".utf8),
                                             publicKey: identity.publicKeyData))
    }

    func testFingerprintIsStableAndShort() {
        let identity = DeviceIdentity(privateKey: .init())
        XCTAssertEqual(identity.fingerprint.count, 32)
        XCTAssertEqual(identity.fingerprint,
                       DeviceIdentity.fingerprint(publicKey: identity.publicKeyData))
    }
}

final class MediaFrameTests: XCTestCase {

    func testVideoHeaderRoundTrip() throws {
        let header = VideoFrameHeader(codec: .hevc, isKeyframe: true, isParameterSets: false,
                                      sequence: 1234, ptsUs: 987_654_321, dtsUs: 987_654_000)
        var payload = header.encoded
        XCTAssertEqual(payload.count, VideoFrameHeader.size)
        payload.append(Data([1, 2, 3, 4]))

        let decoded = try XCTUnwrap(VideoFrameHeader.decode(payload))
        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(decoded.body, Data([1, 2, 3, 4]))
    }

    func testAudioHeaderRoundTrip() throws {
        let header = AudioFrameHeader(codec: .pcmS16LE, channels: 1, isParameterSets: false,
                                      sampleRate: 48_000, sequence: 7, ptsUs: 42)
        var payload = header.encoded
        XCTAssertEqual(payload.count, AudioFrameHeader.size)
        payload.append(Data(repeating: 0, count: 8))

        let decoded = try XCTUnwrap(AudioFrameHeader.decode(payload))
        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(decoded.body.count, 8)
    }

    func testBulkHeaderRoundTrip() throws {
        let header = BulkFrameHeader(kind: .chunk, transferId: 3, offset: 1_048_576)
        var payload = header.encoded
        XCTAssertEqual(payload.count, BulkFrameHeader.size)
        payload.append(Data([0xAB]))

        let decoded = try XCTUnwrap(BulkFrameHeader.decode(payload))
        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(decoded.body, Data([0xAB]))
    }

    func testControlEnvelopeRoundTrip() throws {
        let profile = StreamProfile.webcam1080p30
        let data = try ControlCodec.encode(type: ControlType.streamStart, id: 9,
                                           payload: StreamStartPayload(profile: profile))
        let envelope = try ControlCodec.envelope(from: data)

        XCTAssertEqual(envelope.t, ControlType.streamStart)
        XCTAssertEqual(envelope.id, 9)
        XCTAssertNil(envelope.r)

        let decoded = try ControlCodec.payload(StreamStartPayload.self, from: envelope)
        XCTAssertEqual(decoded.profile, profile)
    }
}
