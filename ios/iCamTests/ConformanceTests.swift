import XCTest
import CryptoKit
@testable import iCam

/// Verifies the Swift implementation against `protocol/vectors/v1.json`.
///
/// The C# side runs the same vectors. Each implementation can be internally
/// consistent and still disagree with the other — a different byte order, a
/// different JSON escape, a different HKDF label — and nothing would catch it
/// until two real devices failed to pair. This is what catches it.
final class ConformanceTests: XCTestCase {

    private static var vectors: [String: Any] = [:]

    override class func setUp() {
        super.setUp()
        guard let url = Bundle(for: ConformanceTests.self)
            .url(forResource: "v1", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("protocol/vectors/v1.json is missing from the test bundle")
            return
        }
        vectors = parsed
    }

    private func section(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(Self.vectors[key] as? [[String: Any]], "vector section \(key) is missing")
    }

    // MARK: - Framing

    func testFramingMatchesTheVectors() throws {
        for testCase in try section("framing") {
            let name = testCase["name"] as? String ?? "?"
            let channel = try XCTUnwrap(Channel(rawValue: UInt8(testCase["channel"] as! Int)))
            let flags = FrameFlags(rawValue: UInt8(testCase["flags"] as! Int))
            let payload = try XCTUnwrap(Data(hex: testCase["payloadHex"] as! String))
            let expected = try XCTUnwrap(Data(hex: testCase["frameHex"] as! String))

            let encoded = Frame(channel: channel, flags: flags, payload: payload).encoded
            XCTAssertEqual(encoded, expected, "framing vector '\(name)' does not match")

            // And the parser must get back exactly what went in.
            var parser = FrameParser()
            parser.append(expected)
            let decoded = try XCTUnwrap(parser.next())
            XCTAssertEqual(decoded.frame.channel, channel)
            XCTAssertEqual(decoded.frame.payload, payload)
        }
    }

    // MARK: - Key schedule

    func testKeyScheduleMatchesTheVectors() throws {
        let vector = try XCTUnwrap(Self.vectors["keySchedule"] as? [String: Any])
        let shared = try XCTUnwrap(Data(hex: vector["sharedSecretHex"] as! String))
        let clientRandom = try XCTUnwrap(Data(hex: vector["clientRandomHex"] as! String))
        let serverRandom = try XCTUnwrap(Data(hex: vector["serverRandomHex"] as! String))

        let keys = SessionKeys.derive(sharedSecretBytes: shared,
                                      clientRandom: clientRandom,
                                      serverRandom: serverRandom)

        XCTAssertEqual(keys.c2sKey.hexString, vector["c2sKeyHex"] as! String)
        XCTAssertEqual(keys.s2cKey.hexString, vector["s2cKeyHex"] as! String)
        XCTAssertEqual(keys.c2sSalt.hexString, vector["c2sSaltHex"] as! String)
        XCTAssertEqual(keys.s2cSalt.hexString, vector["s2cSaltHex"] as! String)
        XCTAssertEqual(keys.pairingDigits, vector["pairingDigits"] as! String)
    }

    // MARK: - Record layer

    func testAeadMatchesTheVectors() throws {
        let schedule = try XCTUnwrap(Self.vectors["keySchedule"] as? [String: Any])
        let keys = SessionKeys.derive(
            sharedSecretBytes: try XCTUnwrap(Data(hex: schedule["sharedSecretHex"] as! String)),
            clientRandom: try XCTUnwrap(Data(hex: schedule["clientRandomHex"] as! String)),
            serverRandom: try XCTUnwrap(Data(hex: schedule["serverRandomHex"] as! String)))

        // One channel, sealing in order: the counter advances across every
        // channel in a direction, which is exactly what the vectors pin down.
        let channel = SecureChannel(keys: keys, role: .initiator)

        for testCase in try section("aead") {
            let target = try XCTUnwrap(Channel(rawValue: UInt8(testCase["channel"] as! Int)))
            let plaintext = try XCTUnwrap(Data(hex: testCase["plaintextHex"] as! String))
            let expected = try XCTUnwrap(Data(hex: testCase["frameHex"] as! String))
            let counter = testCase["counter"] as! Int

            let sealed = try channel.seal(channel: target, plaintext: plaintext)
            XCTAssertEqual(sealed, expected, "AEAD vector at counter \(counter) does not match")
        }
    }

    func testTheResponderDirectionOpensWhatTheVectorsSealed() throws {
        let schedule = try XCTUnwrap(Self.vectors["keySchedule"] as? [String: Any])
        let keys = SessionKeys.derive(
            sharedSecretBytes: try XCTUnwrap(Data(hex: schedule["sharedSecretHex"] as! String)),
            clientRandom: try XCTUnwrap(Data(hex: schedule["clientRandomHex"] as! String)),
            serverRandom: try XCTUnwrap(Data(hex: schedule["serverRandomHex"] as! String)))

        let receiver = SecureChannel(keys: keys, role: .responder)
        var parser = FrameParser()

        for testCase in try section("aead") {
            parser.append(try XCTUnwrap(Data(hex: testCase["frameHex"] as! String)))
            let frame = try XCTUnwrap(parser.next())
            let opened = try receiver.open(header: frame.header, payload: frame.frame.payload)
            XCTAssertEqual(opened.hexString, testCase["plaintextHex"] as! String)
        }
    }

    // MARK: - Canonical handshake JSON

    func testClientHelloIsByteIdenticalToTheVector() throws {
        let cases = try section("handshakeJson")
        let vector = try XCTUnwrap(cases.first { ($0["name"] as? String) == "client hello" })
        let expected = try XCTUnwrap(Data(hex: vector["encodedUtf8Hex"] as! String))

        let hello = ClientHello(
            eph: Data((0 ..< 65).map { UInt8($0 == 0 ? 0x04 : $0) }),
            idk: Data((0 ..< 65).map { UInt8($0 == 0 ? 0x04 : 200 - $0) }),
            rnd: Data((0 ..< 32).map { UInt8(0xA0 + $0) }),
            dev: DeviceInfo(name: "آيفون Raeid a/b",
                            model: "iPhone16,1",
                            os: "18.5",
                            app: "1.0.0",
                            id: "0123456789abcdef0123456789abcdef"))

        let encoded = try HandshakeCodec.encode(hello)
        XCTAssertEqual(String(data: encoded, encoding: .utf8),
                       String(data: expected, encoding: .utf8),
                       "the two implementations disagree on canonical handshake JSON")
        XCTAssertEqual(encoded, expected)
    }

    func testServerHelloTranscriptBytesAreByteIdenticalToTheVector() throws {
        let cases = try section("handshakeJson")
        let vector = try XCTUnwrap(cases.first {
            ($0["name"] as? String) == "server hello transcript bytes"
        })
        let expected = try XCTUnwrap(Data(hex: vector["encodedUtf8Hex"] as! String))

        var hello = ServerHello(
            eph: Data((0 ..< 65).map { UInt8($0 == 0 ? 0x04 : $0 + 3) }),
            idk: Data((0 ..< 65).map { UInt8($0 == 0 ? 0x04 : $0 + 9) }),
            rnd: Data((0 ..< 32).map { UInt8(0x10 + $0 * 3) }),
            dev: DeviceInfo(name: "RAEID-PC",
                            model: "Windows 11 Pro",
                            os: "10.0.26200",
                            app: "1.0.0",
                            id: "fedcba9876543210fedcba9876543210"))
        hello.sig = Data([1, 2, 3, 4])

        XCTAssertEqual(try hello.transcriptBytes(), expected)
    }

    // MARK: - Media headers

    func testMediaHeadersMatchTheVectors() throws {
        for testCase in try section("mediaHeaders") {
            let expected = try XCTUnwrap(Data(hex: testCase["headerHex"] as! String))

            switch testCase["kind"] as! String {
            case "video":
                let header = VideoFrameHeader(
                    codec: (testCase["codec"] as! String) == "hevc" ? .hevc : .h264,
                    isKeyframe: testCase["isKeyframe"] as! Bool,
                    isParameterSets: testCase["isParameterSets"] as! Bool,
                    sequence: UInt32(testCase["sequence"] as! Int),
                    ptsUs: UInt64(testCase["ptsUs"] as! Int),
                    dtsUs: UInt64(testCase["dtsUs"] as! Int))
                XCTAssertEqual(header.encoded, expected)

            case "audio":
                let header = AudioFrameHeader(
                    codec: .pcmS16LE,
                    channels: UInt8(testCase["channels"] as! Int),
                    isParameterSets: false,
                    sampleRate: UInt32(testCase["sampleRate"] as! Int),
                    sequence: UInt32(testCase["sequence"] as! Int),
                    ptsUs: UInt64(testCase["ptsUs"] as! Int))
                XCTAssertEqual(header.encoded, expected)

            case "bulk":
                let header = BulkFrameHeader(
                    kind: .chunk,
                    transferId: UInt32(testCase["transferId"] as! Int),
                    offset: UInt64(testCase["offset"] as! Int))
                XCTAssertEqual(header.encoded, expected)

            default:
                XCTFail("unknown media header kind")
            }
        }
    }

    // MARK: - Control payloads

    func testCameraStateDecodesTheVectorTheWindowsSideProduces() throws {
        let cases = try section("controlJson")
        let vector = try XCTUnwrap(cases.first { ($0["name"] as? String) == "camera.state" })
        let json = try XCTUnwrap(vector["json"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: json)

        let state = try ControlCodec.decoder.decode(CameraState.self, from: data)
        XCTAssertEqual(state.version, 184)
        XCTAssertEqual(state.lensId, "back.wide")
        XCTAssertEqual(state.codec, .hevc)
        XCTAssertEqual(state.exposureMode, .manual)
        XCTAssertEqual(state.whiteBalancePreset, .daylight)
        XCTAssertEqual(state.focusMode, .manual)
        XCTAssertEqual(state.orientation, .landscapeLeft)
        XCTAssertEqual(state.shutterDenominator, 120)

        // And round-trips back to the same tree, so the phone can echo a state
        // the PC sent without altering it.
        let reencoded = try ControlCodec.encoder.encode(state)
        let reparsed = try ControlCodec.decoder.decode(CameraState.self, from: reencoded)
        XCTAssertEqual(reparsed, state)
    }

    func testCameraCommandDecodesTheVector() throws {
        let cases = try section("controlJson")
        let vector = try XCTUnwrap(cases.first { ($0["name"] as? String) == "camera.command" })
        let json = try XCTUnwrap(vector["json"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: json)

        let payload = try ControlCodec.decoder.decode(CameraCommandPayload.self, from: data)
        XCTAssertEqual(payload.base, 184)
        XCTAssertEqual(payload.set.iso, 200)
        XCTAssertEqual(payload.set.exposureMode, .manual)
        // Everything the PC did not touch must stay absent.
        XCTAssertNil(payload.set.temperature)
        XCTAssertNil(payload.set.lensId)
    }

    func testTelemetryDecodesTheVector() throws {
        let cases = try section("controlJson")
        let vector = try XCTUnwrap(cases.first { ($0["name"] as? String) == "telemetry" })
        let json = try XCTUnwrap(vector["json"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: json)

        let payload = try ControlCodec.decoder.decode(TelemetryPayload.self, from: data)
        XCTAssertEqual(payload.thermal, "elevated")
        XCTAssertEqual(payload.power, "usb")
        XCTAssertEqual(payload.capture.fps, 59.9, accuracy: 0.001)

        // There is no temperature anywhere in the protocol, and there must not
        // be: iOS publishes no sensor for one.
        XCTAssertFalse(json.keys.contains { $0.lowercased().contains("temp") })
    }
}

// MARK: - Hex helpers

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
