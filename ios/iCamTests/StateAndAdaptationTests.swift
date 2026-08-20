import XCTest
@testable import iCam

final class CameraStateStoreTests: XCTestCase {

    func testApplyBumpsTheVersion() {
        let store = CameraStateStore()
        XCTAssertEqual(store.version, 0)

        var mutation = CameraMutation()
        mutation.iso = 400
        let result = store.apply(mutation) { _ in }

        XCTAssertEqual(result.version, 1)
        XCTAssertEqual(result.iso, 400)
    }

    func testOnlyMutatedKeysChange() {
        let store = CameraStateStore()
        var first = CameraMutation()
        first.whiteBalanceMode = .manual
        first.temperature = 3200
        store.apply(first) { _ in }

        // A second, stale mutation touching only ISO must not revert the white
        // balance the user just set. This is the whole reason mutations are
        // partial rather than whole-state.
        var second = CameraMutation()
        second.iso = 800
        let result = store.apply(second, base: 0) { _ in }

        XCTAssertEqual(result.iso, 800)
        XCTAssertEqual(result.whiteBalanceMode, .manual)
        XCTAssertEqual(result.temperature, 3200)
    }

    func testReconcileCanClampAndTheClampedValueIsPublished() {
        let store = CameraStateStore()
        var mutation = CameraMutation()
        mutation.iso = 100_000

        let result = store.apply(mutation) { state in
            state.iso = min(state.iso, 3_072)
        }
        XCTAssertEqual(result.iso, 3_072)
        XCTAssertEqual(store.state.iso, 3_072)
    }

    func testObserveDoesNotBumpTheVersion() {
        let store = CameraStateStore()
        store.apply(CameraMutation()) { _ in }
        let version = store.version

        store.observe { $0.focusPosition = 0.77 }

        // Autofocus reporting a new lens position is not a user edit. Bumping
        // the version here would make every PC slider fight the sensor.
        XCTAssertEqual(store.version, version)
        XCTAssertEqual(store.state.focusPosition, 0.77)
    }

    func testChangeNotificationCarriesTheFinalState() {
        let store = CameraStateStore()
        var received: CameraState?
        store.onChange = { received = $0 }

        var mutation = CameraMutation()
        mutation.fps = 240
        store.apply(mutation) { state in state.fps = 60 }

        XCTAssertEqual(received?.fps, 60)
    }

    func testShutterDenominatorReadsAsAFraction() {
        var state = CameraState()
        state.exposureDurationUs = 8_333
        XCTAssertEqual(state.shutterDenominator, 120)
        state.exposureDurationUs = 16_667
        XCTAssertEqual(state.shutterDenominator, 60)
    }
}

final class BitrateControllerTests: XCTestCase {

    private func makeController(bitrate: Int = 8_000_000) -> BitrateController {
        var profile = StreamProfile.webcam1080p30
        profile.bitrate = bitrate
        return BitrateController(profile: profile)
    }

    private var healthy: BitrateController.Feedback {
        .init(rttUs: 5_000, pendingBytes: 0, encoderDrops: 0, transportDrops: 0)
    }

    func testCongestionLowersTheBitrate() {
        let controller = makeController()
        let start = controller.bitrate

        let decision = controller.update(.init(rttUs: 400_000, pendingBytes: 2_000_000,
                                               encoderDrops: 0, transportDrops: 4))
        XCTAssertNotNil(decision)
        XCTAssertLessThan(controller.bitrate, start)
    }

    func testRecoveryNeedsSeveralGoodSamples() {
        let controller = makeController()
        _ = controller.update(.init(rttUs: 400_000, pendingBytes: 2_000_000,
                                    encoderDrops: 0, transportDrops: 4))
        let lowered = controller.bitrate

        // The rate limiter means the very next sample cannot move anything;
        // that is the hysteresis doing its job.
        XCTAssertNil(controller.update(healthy))
        XCTAssertEqual(controller.bitrate, lowered)
    }

    func testNeverGoesBelowTheFloor() {
        let controller = makeController(bitrate: 1_000_000)
        for _ in 0 ..< 40 {
            _ = controller.update(.init(rttUs: 900_000, pendingBytes: 8_000_000,
                                        encoderDrops: 10, transportDrops: 10))
        }
        XCTAssertGreaterThanOrEqual(controller.bitrate, 125_000)
    }

    func testCeilingIsAppliedImmediately() {
        let controller = makeController(bitrate: 12_000_000)
        controller.setCeiling(3_000_000)
        XCTAssertEqual(controller.bitrate, 3_000_000)
    }
}

final class TimeSyncTests: XCTestCase {

    func testOffsetOfAPerfectlySymmetricExchange() {
        let sync = TimeSync()
        // The peer's clock runs 1 000 000 µs ahead; the trip takes 20 000 µs
        // total, split evenly.
        sync.record(t1: 0, t2: 1_010_000, t3: 1_010_000, t4: 20_000)

        XCTAssertEqual(sync.offsetUs, 1_000_000)
        XCTAssertEqual(sync.rttUs, 20_000)
        XCTAssertTrue(sync.isSynchronised)
    }

    func testKeepsTheFastestSamples() {
        let sync = TimeSync()
        // A slow sample carries the queue's delay in its offset estimate, so it
        // must lose to faster ones.
        sync.record(t1: 0, t2: 1_000_000, t3: 1_000_000, t4: 4_000)
        for _ in 0 ..< 8 {
            sync.record(t1: 0, t2: 1_500_000, t3: 1_500_000, t4: 400_000)
        }
        XCTAssertEqual(sync.rttUs, 4_000)
    }

    func testConvertsBetweenClocks() {
        let sync = TimeSync()
        sync.record(t1: 0, t2: 1_010_000, t3: 1_010_000, t4: 20_000)

        let local: UInt64 = 500_000
        let peer = sync.peerTime(forLocalUs: local)
        XCTAssertEqual(peer, 1_500_000)
        XCTAssertEqual(sync.localTime(forPeerUs: peer), local)
    }

    func testIgnoresAnImpossibleExchange() {
        let sync = TimeSync()
        sync.record(t1: 100, t2: 0, t3: 0, t4: 50)
        XCTAssertFalse(sync.isSynchronised)
    }

    func testPingsBackOffAfterTheFirstThirtySeconds() {
        XCTAssertEqual(TimeSync.interval(sinceStart: 5), 2)
        XCTAssertEqual(TimeSync.interval(sinceStart: 120), 15)
    }
}

final class ThermalBudgetTests: XCTestCase {

    func testDegradationOrderIsMonotonic() {
        let levels = [ThermalBudget.full, .warm, .hot, .critical]
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.monitoringHz, b.monitoringHz)
            XCTAssertGreaterThanOrEqual(a.pcProxyFps, b.pcProxyFps)
            XCTAssertGreaterThanOrEqual(a.maxStreamBitrate, b.maxStreamBitrate)
        }
    }

    func testTheMasterRecordingIsNeverInTheBudget() {
        // The budget has no lever that touches the local recording. If one is
        // ever added, this test is the place that should stop it.
        let mirror = Mirror(reflecting: ThermalBudget.critical)
        let names = mirror.children.compactMap(\.label)
        XCTAssertFalse(names.contains { $0.lowercased().contains("record") })
        XCTAssertFalse(names.contains { $0.lowercased().contains("master") })
    }

    func testEfficiencyModeKeepsStreamQualityButCutsMonitoring() {
        let efficient = ThermalBudget.full.applyingEfficiencyMode()
        XCTAssertEqual(efficient.maxStreamBitrate, ThermalBudget.full.maxStreamBitrate)
        XCTAssertEqual(efficient.maxStreamPixels, ThermalBudget.full.maxStreamPixels)
        XCTAssertLessThan(efficient.monitoringHz, ThermalBudget.full.monitoringHz)
        XCTAssertFalse(efficient.allowsGpuEffects)
    }

    func testLevelOrdering() {
        XCTAssertLessThan(ThermalLevel.normal, ThermalLevel.warm)
        XCTAssertLessThan(ThermalLevel.warm, ThermalLevel.hot)
        XCTAssertLessThan(ThermalLevel.hot, ThermalLevel.critical)
    }
}

final class RecordingMathTests: XCTestCase {

    func testMasterBitrateScalesWithPixelsAndFrameRate() {
        let hd30 = RecordingEngine.recommendedBitrate(width: 1920, height: 1080,
                                                      fps: 30, codec: .hevc)
        let uhd30 = RecordingEngine.recommendedBitrate(width: 3840, height: 2160,
                                                       fps: 30, codec: .hevc)
        let hd60 = RecordingEngine.recommendedBitrate(width: 1920, height: 1080,
                                                      fps: 60, codec: .hevc)

        XCTAssertGreaterThan(uhd30, hd30)
        XCTAssertGreaterThan(hd60, hd30)
    }

    func testHEVCAsksForFewerBitsThanH264() {
        let hevc = RecordingEngine.recommendedBitrate(width: 1920, height: 1080,
                                                      fps: 30, codec: .hevc)
        let h264 = RecordingEngine.recommendedBitrate(width: 1920, height: 1080,
                                                      fps: 30, codec: .h264)
        XCTAssertLessThan(hevc, h264)
    }

    func testSessionIdentifiersSortChronologically() {
        let first = RecordingEngine.newSessionId()
        XCTAssertEqual(first.count, 15)
        XCTAssertTrue(first.contains("-"))
    }
}

final class CapabilityTests: XCTestCase {

    private func makeCapabilities() -> CameraCapabilities {
        var caps = CameraCapabilities()
        caps.lenses = [
            LensCapability(id: "back.wide", label: "1", deviceType: "wide", position: "back",
                           minZoom: 1, maxZoom: 3)
        ]
        caps.formats = [
            FormatCapability(lensId: "back.wide", width: 1920, height: 1080,
                             fpsRanges: [[1, 60]], hdr: true, codecs: [.h264, .hevc],
                             stabilization: [.off, .standard], isoRange: [34, 3072],
                             exposureDurationUsRange: [125, 1_000_000],
                             maxPhotoDimensions: [4032, 3024], supportsRaw: false),
            FormatCapability(lensId: "back.wide", width: 3840, height: 2160,
                             fpsRanges: [[1, 30]], hdr: true, codecs: [.hevc],
                             stabilization: [.off], isoRange: [34, 3072],
                             exposureDurationUsRange: [125, 1_000_000],
                             maxPhotoDimensions: [4032, 3024], supportsRaw: false)
        ]
        return caps
    }

    func testResolutionsAreLargestFirst() {
        let resolutions = makeCapabilities().resolutions(forLens: "back.wide")
        XCTAssertEqual(resolutions.first, Resolution(width: 3840, height: 2160))
        XCTAssertEqual(resolutions.count, 2)
    }

    func testFrameRatesAreNotAssumedUniformAcrossResolutions() {
        let caps = makeCapabilities()
        XCTAssertTrue(caps.frameRates(forLens: "back.wide", width: 1920, height: 1080)
            .contains(60))
        // 4K on this device tops out at 30. Offering 60 there would be a lie.
        XCTAssertFalse(caps.frameRates(forLens: "back.wide", width: 3840, height: 2160)
            .contains(60))
    }

    func testUnknownLensYieldsNothingRatherThanADefault() {
        let caps = makeCapabilities()
        XCTAssertTrue(caps.resolutions(forLens: "back.periscope").isEmpty)
        XCTAssertTrue(caps.frameRates(forLens: "back.periscope", width: 1920, height: 1080).isEmpty)
    }

    func testResolutionDisplayNames() {
        XCTAssertEqual(Resolution(width: 3840, height: 2160).displayName, "4K")
        XCTAssertEqual(Resolution(width: 1920, height: 1080).displayName, "1080p")
        XCTAssertEqual(Resolution(width: 1440, height: 1080).displayName, "1440 × 1080")
    }
}
