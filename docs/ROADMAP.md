# Roadmap

Phases ship in order. A later phase never destabilises an earlier one, and
nothing is drawn in the interface before it works.

---

## Phase 1 — Production foundation

**Goal: open iCam, connect, shoot, stream, record — reliably.**

### iPhone — done

- [x] Native SwiftUI interface: one camera screen, one Camera settings screen,
      one App settings screen
- [x] `CameraEngine` on dedicated queues, with sinks rather than a god class
- [x] Real lens enumeration from `AVCaptureDevice`, including virtual devices
- [x] Zoom, pinch, ramped lens switching, Lens Lock
- [x] Exposure: auto, lock, manual ISO and shutter, EV
- [x] White balance: auto, lock, presets, manual temperature and tint, Pick White
- [x] Focus: continuous, single, manual, tap to focus, face-driven toggle
- [x] Torch, mirror, orientation
- [x] Photo capture through `AVCapturePhotoOutput`, HEIF where supported
- [x] Segmented master recording with an atomic manifest
- [x] Crash recovery: find, offer, compose without re-encoding
- [x] Hardware stream encoder, independent of the master
- [x] `ThermalManager` and `ThermalBudget`
- [x] `BatteryManager`, `StorageMonitor` with real estimates
- [x] Display Off mode
- [x] Localisation-ready throughout; no hardcoded strings in views

### Connectivity — done

- [x] Bonjour discovery
- [x] Pairing with six-digit verification, trust bound to an identity key
- [x] AES-256-GCM record layer with a per-direction counter
- [x] Reconnect with exponential backoff and jitter
- [x] Clock offset estimation
- [x] Adaptive bitrate with hysteresis

### iPhone — remaining

- [ ] Photo copy to PC over the bulk channel
- [ ] Preset save and recall
- [ ] iCam Library: photos, videos, sessions, with `On iPhone` / `On PC` filters
- [ ] Recovery prompt at launch, wired to the interface

### Windows — next

- [ ] `iCam.Core`: the C# half of the protocol, against the same vectors
- [ ] Listener, Bonjour advertisement, pairing UI
- [ ] WinUI 3 shell: Mica, native title bar, remembered window placement
- [ ] Live preview through `MediaStreamSource`, hardware decoded
- [ ] Remote camera control, driving the same `CameraState`
- [ ] PC-side recording
- [ ] `iCam Camera`: out-of-process Media Foundation virtual camera, fed by a
      shared-memory ring so it keeps working with the window closed
- [ ] `iCam Microphone`
- [ ] Signed installer; one-button virtual device setup

---

## Phase 2 — Professional camera

- [ ] 4K, HDR handled separately for master, stream and virtual camera
- [ ] ProRes where the device supports it
- [ ] RAW and Apple ProRAW where supported
- [ ] Focus Peaking, Zebra, False Colour, Histogram — Metal, on a downscaled
      analysis buffer, rate-limited by the thermal budget
- [ ] Composition guides, horizon level, safe areas
- [ ] Image adjustments applied to derived outputs, never to the master
- [ ] Advanced stabilisation
- [ ] Presets, synced between trusted devices

---

## Phase 3 — Smart camera

- [ ] Background blur, replacement, green screen — with the capability-based
      pipeline that lets the PC GPU take the work instead of the phone
- [ ] Subject tracking and Auto Framing, at a fraction of the capture rate
- [ ] Virtual PTZ: crop a 4K master into a 1080p output, master untouched
- [ ] Audio processing: gain, noise reduction, voice isolation, compressor,
      limiter, gate — every one of them optional, clean feed always available
- [ ] Missing-segment recovery, end to end
- [ ] Instant Replay and Pre-Record, on a disk-backed bounded buffer

---

## Phase 4 — iCam Studio

- [ ] Several iPhones on one PC
- [ ] `iCam Camera 2`, `iCam Camera 3`
- [ ] Director Mode with proxy preview tiles
- [ ] Picture-in-picture, layouts, per-camera settings
- [ ] Synchronised recording and timecode

---

## Phase 5 — Ecosystem

- [ ] OBS integration as a plugin layer, not a coupling
- [ ] Stream Deck
- [ ] Apple Watch remote
- [ ] External control API

---

## Explicitly out of scope

- Replacing the Photos app. The library stays focused on iCam's own media.
- Beauty filters that change facial geometry or body shape. Face processing is
  limited to conservative skin smoothing and exposure balancing.
- Any cloud service, account, or relay.
- Analytics that are not opt-in.
