# Testing

Two kinds of test, and a clear line between them.

**Automated** covers everything that can be decided without hardware: the
protocol, the crypto, the state machines, the adaptation logic. These run on
every push, on both platforms.

**Manual** covers everything that needs a real iPhone, a real network, and real
heat. A camera application cannot be certified by unit tests alone, and
pretending otherwise is how a webcam ships that works for ten minutes.

---

## Automated

| Suite | Where | Runs on |
|-------|-------|---------|
| Swift — protocol, state, adaptation, conformance | `ios/iCamTests` | macOS runner, every push |
| C# — protocol, crypto, bitstream, session, conformance | `windows/iCam.Core.Tests` | Windows runner, every push |

```bash
# Swift
cd ios && xcodegen generate && xcodebuild test -scheme iCam \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# C#
cd windows && dotnet test iCam.sln
```

### The conformance vectors

`protocol/vectors/v1.json` is generated from the C# implementation and read by
**both** test suites.

This is the only thing that proves the two halves agree. Each side has its own
tests, and each can be internally consistent while disagreeing with the other —
a different byte order, a different JSON escape, a different HKDF label — and
nothing would catch it until two real devices failed to pair.

The vectors pin down:

- frame encoding, including the exact header bytes used as AEAD associated data
- the key schedule, from a fixed shared secret to the six pairing digits
- sealed AEAD records across four frames, so the shared counter is covered
- canonical handshake JSON, **including a device name in Arabic and a name
  containing a slash** — the two cases where two JSON writers most plausibly
  differ, and where a difference would break pairing for real people
- video, audio and bulk headers
- the control payloads, decoded on both sides

Regenerating must be a no-op:

```bash
dotnet run --project tools/ProtocolVectors
git diff --exit-code -- protocol/vectors
```

CI runs exactly that. A diff means the wire format moved without the tests on
the other side moving with it.

---

## Manual — before every release

Nothing here is optional. Each line is something that has broken a
phone-as-webcam application in the field.

### Camera

- [ ] Every lens the iPhone has appears, and only those. A device with one rear
      camera shows one pill.
- [ ] Tapping a lens ramps rather than cuts.
- [ ] Pinching across a switch-over point updates the selector to the lens that
      is actually live.
- [ ] Lens Lock genuinely prevents the switch, and the zoom range visibly
      shrinks to that lens.
- [ ] Manual ISO and shutter change the picture, and the values shown are the
      ones the sensor accepted. Ask for ISO 100000 and confirm it snaps to the
      maximum rather than displaying 100000.
- [ ] Pick White on a grey card produces a neutral image, and the temperature
      slider moves to a plausible value.
- [ ] Every frame rate offered at each resolution actually holds. 4K 120 must
      not be offered on a device that cannot do it.

### Connection

- [ ] First pairing shows the same six digits on both devices.
- [ ] Digits that do not match, refused on either side, leave nothing trusted.
- [ ] A trusted computer reconnects without asking.
- [ ] `Forget Device` on the iPhone drops the connection and forces pairing again.
- [ ] `Forget` on Windows does the same in the other direction.
- [ ] Manual address entry works on a network with discovery blocked.
- [ ] Renaming the PC does not break trust. **Trust follows the key.**

### Interruption — the part that matters most

- [ ] Start a recording on the iPhone with the PC connected, then turn off
      Wi-Fi. **The recording keeps going.** The interface says the connection
      was lost and that the recording continues.
- [ ] Turn Wi-Fi back on. The connection returns and the recording is still one
      unbroken file.
- [ ] Unplug USB mid-recording. Same result.
- [ ] Force-quit iCam on Windows mid-recording. The iPhone keeps recording.
- [ ] Force-quit iCam on the iPhone mid-recording. On next launch, recovery is
      offered, and composing produces a playable file of everything up to the
      last completed segment.
- [ ] Take a phone call mid-session. The camera pauses and resumes.
- [ ] Lock the iPhone mid-session, then unlock.
- [ ] Sleep and wake the PC. The phone reconnects without help.

### Long duration

Run each of these and watch memory, file handles, dropped frames and A/V drift.
**No unbounded growth is acceptable.**

- [ ] 30 minutes as a webcam over Wi-Fi.
- [ ] 2 hours as a webcam over USB.
- [ ] 4K60 recording on the iPhone while sending 1080p30 to the PC, for 30
      minutes. Confirm the recording is genuinely 4K60 and the PC stream is
      genuinely 1080p30 — that separation is the whole architecture.
- [ ] Ten reconnects in a row. Confirm no encoder, socket or file handle leaks.

### Thermal

- [ ] Under sustained 4K60, confirm iCam reduces monitoring first, then the
      stream — and **never** the local recording.
- [ ] Every automatic reduction produces a plain-language note. No silent
      degradation.
- [ ] `Efficiency Mode` keeps the picture the PC receives while cutting
      everything that only exists on screen.
- [ ] `Display Off` keeps recording and streaming with the screen dark, and
      measurably reduces battery drain.
- [ ] Nowhere in either application is a temperature in degrees shown. iOS
      publishes no sensor for one.

### Storage and battery

- [ ] Fill the iPhone to under 500 MB free. Recording refuses to start and says
      why, rather than dying thirty seconds in.
- [ ] The recording-time estimate tracks the codec and resolution actually
      selected.
- [ ] Below 15% battery, a long session warns before starting.

### Windows consumers

`iCam Camera` must work in each of these, at both 720p and 1080p:

- [ ] Zoom
- [ ] Microsoft Teams
- [ ] Discord
- [ ] OBS Studio
- [ ] Chrome, Edge and Firefox (`getUserMedia`)
- [ ] The Windows Camera app
- [ ] Two consumers at once, where the app supports it

And the decoupling that justifies the architecture:

- [ ] Start a call using `iCam Camera`, then **close the iCam window**. The
      camera keeps working.

### Accessibility

- [ ] VoiceOver reaches every control on the iPhone, with a meaningful label.
- [ ] Narrator reaches every control on Windows.
- [ ] Reduce Motion removes animation without removing function.
- [ ] Reduce Transparency replaces glass with opaque surfaces that stay legible.
- [ ] Dynamic Type at the largest setting does not clip any control.
- [ ] Full keyboard navigation on Windows, with a visible focus ring everywhere.
- [ ] Arabic: the interface mirrors, and **the camera preview does not**.

### Errors

- [ ] No `AVError`, `HRESULT` or numeric code appears in normal interface text.
- [ ] Every error names something the user can do.
- [ ] Denying camera permission produces an explanation, not an empty black
      screen.
- [ ] Denying local-network permission explains what is missing and offers the
      manual address route.
