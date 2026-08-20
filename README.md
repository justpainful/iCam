<div align="center">

<img src="assets/iCam.ico" width="96" alt="iCam">

# iCam

**Your iPhone. Your camera. Everywhere.**

A native iPhone camera app and a native Windows companion. The iPhone keeps the
full-quality master recording; Windows gets a clean, low-latency webcam and
microphone. No cloud, no account, no watermark.

</div>

---

## What it is

iCam is two applications and two Windows devices:

| Piece | What it is |
|-------|-----------|
| **iCam for iPhone** | Swift / SwiftUI / AVFoundation. A complete camera on its own — the PC is an extra, not a requirement. |
| **iCam for Windows** | WinUI 3 / Windows App SDK / Media Foundation. Native, not a web app in a shell. |
| **iCam Camera** | A Media Foundation virtual camera. Appears in Zoom, Teams, Discord, OBS, browsers. |
| **iCam Microphone** | The iPhone microphone, as a Windows input device. |

## The one idea

```
                   AVCaptureSession
                          │
        ┌─────────────────┼──────────────────┐
        │                 │                  │
   Recording          UI Preview        Stream Encoder
    Master             (screen)          (to the PC)
        │                                    │
   4K60 HEVC                            1080p30 H.264
   on the phone                              │
                                     ┌───────┴────────┐
                                     │                │
                              PC control preview   iCam Camera
                                720p30 proxy       1080p30 clean
```

Five outputs, five independent quality decisions, **one capture**. The master is
never derived from the stream, and the stream is never derived from the master.

Which is why **Safety Recording** costs nothing: when Wi-Fi drops mid-take, the
recorder is not told, because it was never connected to the network in the first
place. The gap the PC missed is written into the session ledger, and iCam can
offer exactly that range once the link comes back.

## What is built

Phase 1 — the vertical slice, end to end.

- [x] Wire protocol, specified and implemented ([`docs/PROTOCOL.md`](docs/PROTOCOL.md))
- [x] Secure pairing: P-256 ECDH + ECDSA, AES-256-GCM records, six-digit
      verification, trust bound to a key rather than to an IP address
- [x] Capture engine: real lens enumeration, Lens Lock, exposure, ISO, shutter,
      white balance, Pick White, focus, torch — every range read from the live
      device, never hardcoded
- [x] Segmented, crash-recoverable master recording
- [x] Hardware stream encoder, independent of the master, with adaptive bitrate
- [x] `ThermalManager` and a single `ThermalBudget` every subsystem reads
- [x] Display Off mode for multi-hour sessions
- [x] iPhone interface: one screen, three surfaces
- [ ] Windows application ([`docs/ROADMAP.md`](docs/ROADMAP.md))
- [ ] `iCam Camera` virtual device
- [ ] `iCam Microphone`

Nothing in the tree pretends to work when it does not. A control that is not
implemented is not drawn.

## The iPhone interface

One screen. A large preview, and a deck of five controls beneath it — never over
it. The divider between them is draggable, so the split is the user's to set.

```
┌──────────────────────────────┐
│ ● 00:04:18        RAEID-PC ● │   thin status band, beside the picture
├──────────────────────────────┤
│                              │
│                              │
│           PREVIEW            │   the brightest thing on screen, always
│                              │
│                              │
├──────────────┬───────────────┤
│      ▬▬      │                   drag to resize
│    .5  1  3                  │   lenses this iPhone actually has
│   ⌾    ◉    ⏺    ⇄    ☰      │
└──────────────────────────────┘
```

Two more screens, and no others: **Camera** for everything about the picture,
**Settings** for everything else.

## Building

### iPhone

Requires a Mac with Xcode 16 or later.

```bash
brew install xcodegen
cd ios && xcodegen generate && open iCam.xcodeproj
```

The `.xcodeproj` is generated, not committed — a project file is a merge
conflict waiting to happen. Every setting lives in [`ios/project.yml`](ios/project.yml).

CI builds and tests every push on a macOS runner, and produces an unsigned
device archive on `main`.

### Icons

Both applications draw from one source file:

```bash
python tools/generate-icons.py
```

Reads `assets/iCam.ico` and writes the iOS icon set and the Windows / MSIX logo
assets.

## Repository

```
docs/          PROTOCOL.md · ARCHITECTURE.md · ROADMAP.md · TESTING.md
ios/           the iPhone app
windows/       the Windows app, virtual camera and virtual microphone
protocol/      conformance vectors shared by both implementations
tools/         icon generation and other build helpers
assets/        the source icon
```

## Principles

**Recording reliability first.** When something has to give, it is never the
recording. The priority order is written down in `docs/ARCHITECTURE.md` and the
thermal budget is built to honour it.

**No invented numbers.** iOS publishes no temperature reading, so iCam reports
`Normal` / `Elevated` / `High` and never a fake `42°C`. Every ISO range, frame
rate and resolution comes from the live `AVCaptureDevice`.

**Local first.** No account, no cloud, no relay, no analytics. Video and audio
travel between your own devices, encrypted, and nowhere else.

**Cool and quiet.** A captured frame is an `IOSurface`-backed `CVPixelBuffer`
and stays one — never a `UIImage`, never a `CGImage`, never a `Data`. The
preview is the system's own layer, so no frame crosses into app memory just to
be shown.

## Licence

Not yet chosen.
