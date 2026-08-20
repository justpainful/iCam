# iCam Architecture

## The one idea

The iPhone is the **master recorder**. The PC is a **consumer of a derived
stream**. Everything else follows from that.

```
                   AVCaptureSession
                          |
        +-----------------+------------------+
        |                 |                  |
   Recording          UI Preview        Stream Encoder
    Master             (screen)          (to the PC)
        |                                    |
   4K60 HEVC                            1080p30 H.264
   on the phone                              |
                                     +-------+--------+
                                     |                |
                              PC control preview   iCam Camera
                                720p30 proxy       1080p30 clean
```

Five outputs, five independent quality decisions, one capture. The master is
**never** derived from the stream, and the stream is never derived from the
master. Losing the PC does not touch the master.

---

## Layers

| Layer | iOS | Windows |
|-------|-----|---------|
| Capture | `Camera/CameraEngine` on a dedicated serial queue | — |
| Processing | `Processing/` — Metal, on `CVPixelBuffer` only | Direct3D 11 |
| Encode | `Streaming/StreamEncoder` — VideoToolbox | Media Foundation |
| Transport | `Connectivity/` — Network.framework | `iCam.Core` sockets |
| Protocol | `Connectivity/Protocol` | `iCam.Core/Protocol` |
| Present | SwiftUI, no pixels on the main thread | WinUI 3 + `MediaStreamSource` |

The **rule that keeps the phone cool**: a frame that arrives from
`AVCaptureVideoDataOutput` is a `CVPixelBuffer` backed by an `IOSurface`, and it
stays one. It is never turned into a `UIImage`, a `CGImage`, or a `Data`. The
preview layer takes it, the encoder takes it, and Metal takes it — all three by
reference.

---

## Threading

There are exactly four long-lived queues on iOS:

| Queue | QoS | Owns |
|-------|-----|------|
| `com.icam.session` | `userInitiated` | `AVCaptureSession` configuration, device locks |
| `com.icam.video` | `userInitiated` | video sample buffer delegate, encode submission |
| `com.icam.audio` | `userInitiated` | audio sample buffer delegate |
| `com.icam.net` | `utility` | `NWConnection` send and receive |

SwiftUI observes `@MainActor` view models that are updated by coalesced,
throttled hops off those queues. No view model is written to per frame.

---

## Camera state ownership

One `CameraState` value exists, on the phone, inside `CameraStateStore`. It
carries a version counter. Both the phone UI and the PC send *mutations*, never
whole states. The store applies, clamps to what the live `AVCaptureDevice`
actually supports, bumps the version, and publishes.

The result is that a PC slider and a phone slider can never disagree for longer
than one round trip, and neither can push the device into an unsupported
configuration.

---

## ThermalManager

Not a monitor bolted on afterwards — an input to every quality decision.

Inputs: `ProcessInfo.thermalState`, `AVCaptureSession.systemPressureState`,
battery level and state, dropped-frame rate from the capture delegate, encoder
queue depth, active format cost.

Output: a single `ThermalLevel` (`normal` / `warm` / `hot` / `critical`) plus a
`ThermalBudget` — a set of concrete allowances that subsystems read:

```swift
struct ThermalBudget {
    var monitoringHz: Double        // histogram, false colour, zebra refresh
    var trackingHz: Double          // Vision subject tracking
    var previewScale: Double        // local preview downscale factor
    var pcProxyFps: Int             // PC control preview
    var allowsGpuEffects: Bool      // background replacement, peaking
    var maxStreamBitrate: Int
    var uiAnimationsEnabled: Bool
}
```

Degradation order is fixed and is the same order as the product's quality
priorities:

1. UI animation and decorative effects
2. Monitoring analysis frequency (histogram, false colour, peaking density)
3. Vision tracking frequency
4. GPU background effects
5. PC control-preview resolution and frame rate
6. Stream bitrate
7. Stream resolution
8. **Never** the local master recording, unless the OS forces it

Every automatic reduction raises a user-visible, plain-language note. iCam
never silently lowers quality.

---

## Safety Recording

The recording engine and the network stack share no failure domain.

`RecordingEngine` writes through `SegmentWriter`, which produces fragmented,
independently playable segments and checkpoints a small JSON manifest after each
one. If the process dies, the next launch finds a manifest with a non-empty
segment list and no `finished` marker, and offers recovery. Nothing incomplete
is ever deleted automatically.

When the transport drops mid-session:

- the writer is not told, because it does not care;
- `SessionLedger` records a gap `[lastPcFrameUs, reconnectUs]`;
- on reconnect the ledger is exchanged, and the phone can offer the missing
  range over the bulk channel.

---

## Image adjustments

Brightness, contrast, saturation, warmth and sharpness are applied to the
**derived outputs only** — the PC preview and `iCam Camera`. The master
recording on the phone is never touched by them, so a session graded for a
video call still leaves a clean master to edit later.

They are therefore applied **on the PC**, in `iCam.Core/Media/ImageAdjuster`,
to the decoded NV12 frame on its way out. Two reasons, in order:

1. The rule above. Anything the phone applies before the encoder would land in
   the recording as well, and a grade is not something a recording can be
   talked out of afterwards.
2. The PC is plugged into a wall. `ThermalBudget` exists because every watt on
   the phone is a frame the recorder might not get; the same arithmetic costs
   the PC 1.3 ms of one core per 1080p frame and costs the phone nothing.

The values themselves live in `CameraState`, alongside everything else, so the
phone can show the same five controls and so they survive a reconnect. The
phone carries them and does not act on them — the one place in the protocol
where that is true, and it is deliberate.

---

## Windows media path

Decode is `MediaStreamSource` fed with AVCC access units and a codec private
blob, rendered by `MediaPlayerElement` with `RealTimePlayback = true`. That is
the native, hardware-accelerated, zero-third-party path.

The virtual camera is a separate out-of-process COM server registered through
`MFCreateVirtualCamera`, so **the iCam window does not have to be open, or even
running, for `iCam Camera` to keep working**. The app and the camera
communicate through a named shared-memory ring buffer of NV12 frames plus a
named event. That decoupling is the reason `iCam Camera` does not vanish from
Zoom when the user closes the window.

---

## What is deliberately not here yet

Phase 1 ships the vertical slice: capture, pair, stream, preview, control,
record on both ends. `docs/ROADMAP.md` tracks the rest. Nothing in the tree
pretends to work when it does not — a control that is not implemented is not
drawn.
