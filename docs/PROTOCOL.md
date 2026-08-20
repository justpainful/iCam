# iCam Wire Protocol — v1

The protocol is the contract between **iCam for iPhone** and **iCam for Windows**.
It is implemented twice, from this document:

- Swift — `ios/iCam/Connectivity/Protocol/`
- C#    — `windows/iCam.Core/Protocol/`

Both implementations are covered by conformance tests that run against the
shared vectors in `protocol/vectors/`. If you change this document, change both
implementations and the vectors in the same commit.

---

## 1. Design rules

1. **No cloud.** Every byte travels over the local link (LAN or USB). There is
   no iCam server, no relay, no account.
2. **Typed, binary framing.** Control messages are typed structures serialised
   as compact JSON inside binary frames — never free-form text commands.
3. **Versioned.** Every connection negotiates a protocol version. Unknown
   message types are ignored, never fatal, so a newer peer can talk to an older
   one within the same major version.
4. **Encrypted and authenticated from the first control byte.** Only the
   handshake itself is plaintext.
5. **The media path is not the control path.** Losing control never stops a
   local recording. See `docs/ARCHITECTURE.md`, Safety Recording.

---

## 2. Transport

| Link | Discovery | Notes |
|------|-----------|-------|
| Wi-Fi / LAN | Bonjour `_icam._tcp` | Primary. Advertised by the **Windows** side; the iPhone browses. |
| USB | Fixed loopback port via the USB tunnel | Preferred when available: lower latency, no RF, charges the phone. |
| Manual | User-entered `host:port` | Fallback for locked-down networks. |

The Windows application is the **listener**; the iPhone is the **initiator**.
That direction is deliberate: the PC is the stationary device, far more likely
to have a stable address and a firewall profile the user controls.

Default TCP port: **48213**. If busy, the listener takes the next free port and
publishes the real port in the Bonjour record.

TXT record keys:

```
v    = protocol major version, decimal      e.g. "1"
name = user-visible computer name (UTF-8)   e.g. "RAEID-PC"
id   = lowercase hex, first 16 bytes of SHA-256 over the listener identity key
os   = "windows"
```

---

## 3. Framing

Every byte on the socket after the TCP handshake belongs to a frame.

```
offset  size  field
0       4     length    u32be - number of bytes that follow this field
4       1     channel   u8
5       1     flags     u8
6       2     reserved  u16be, must be 0
8       N     payload   N = length - 4
```

`length` counts `channel + flags + reserved + payload`. Maximum `length` is
`16 * 1024 * 1024` (16 MiB); a peer that receives a larger value closes the
connection. The 8-byte prefix (`length` through `reserved`) is the frame header
and is used verbatim as AEAD associated data.

### Channels

| id | name      | contents |
|----|-----------|----------|
| 0  | handshake | plaintext handshake messages, section 4 |
| 1  | control   | UTF-8 JSON control envelope, section 5 |
| 2  | video     | encoded video access units, section 6 |
| 3  | audio     | encoded audio packets, section 7 |
| 4  | bulk      | file and segment transfer, section 8 |

### Flags

| bit | meaning |
|-----|---------|
| 0   | `endOfMessage` - reserved for future fragmentation; always 1 in v1 |
| 1-7 | reserved, must be 0 |

---

## 4. Handshake

Goals: mutual authentication against a persisted identity, forward secrecy, and
a short human-verifiable code on first pairing. The primitives are chosen
because they exist natively in **both** CryptoKit and .NET with no third-party
dependency:

- Key agreement: **ECDH P-256**
- Signatures: **ECDSA P-256 with SHA-256**
- KDF: **HKDF-SHA256**
- AEAD: **AES-256-GCM**

Public keys are X9.63 uncompressed points, 65 bytes, first byte `0x04`.

### 4.1 Messages

All handshake messages are JSON on channel 0.

**1 - ClientHello (iPhone to PC)**

```json
{ "t":"hello",
  "v":1,
  "eph":"<base64 65B>",
  "idk":"<base64 65B>",
  "rnd":"<base64 32B>",
  "dev":{ "name":"Raeid iPhone", "model":"iPhone16,1", "os":"18.5", "app":"1.0.0" } }
```

**2 - ServerHello (PC to iPhone)**

```json
{ "t":"hello_ack",
  "v":1,
  "eph":"<base64 65B>",
  "idk":"<base64 65B>",
  "rnd":"<base64 32B>",
  "dev":{ "name":"RAEID-PC", "model":"Windows 11 Pro", "os":"10.0.26200", "app":"1.0.0" },
  "sig":"<base64 DER ECDSA>" }
```

**3 - ClientAuth (iPhone to PC)**

```json
{ "t":"auth", "sig":"<base64 DER ECDSA>" }
```

**4 - Ready (PC to iPhone)**

```json
{ "t":"ready", "trusted":true }
```

`trusted` is `false` when the PC has never seen this iPhone identity key. In
that case both sides display the pairing digits (4.3) and the user must confirm
on **both** devices before any channel 1-4 traffic is accepted.

### 4.2 Key schedule

```
transcript = ClientHello.raw || ServerHello_without_sig.raw
ServerHello.sig = ECDSA(serverIdentityKey, SHA256("iCam/v1/server" || transcript))
ClientAuth.sig  = ECDSA(clientIdentityKey, SHA256("iCam/v1/client" || transcript))

z    = ECDH(clientEph, serverEph)                 // 32 bytes
salt = ClientHello.rnd || ServerHello.rnd         // 64 bytes
prk  = HKDF-Extract(salt, z)

c2sKey   = HKDF-Expand(prk, "iCam/v1 c2s key",   32)
s2cKey   = HKDF-Expand(prk, "iCam/v1 s2c key",   32)
c2sSalt  = HKDF-Expand(prk, "iCam/v1 c2s salt",   4)
s2cSalt  = HKDF-Expand(prk, "iCam/v1 s2c salt",   4)
sasSeed  = HKDF-Expand(prk, "iCam/v1 sas",        8)
```

`ServerHello_without_sig.raw` is the exact bytes the server would have sent with
the `sig` member omitted. Both sides must produce byte-identical JSON here, so
handshake JSON uses **sorted keys, no whitespace, no escaped forward slashes**.

### 4.3 Pairing digits

```
digits = (u64be(sasSeed) mod 1000000), rendered zero-padded to six digits
```

Displayed as `123 456`, on first pairing only. On success each side persists the
peer identity public key, the device name, and the pairing date. `Forget Device`
deletes that record on the device it was invoked on and closes any live
connection.

### 4.4 Record encryption

After `Ready`, frames on channels 1-4 are AEAD records:

```
nonce      = directionSalt (4B) || u64be(counter)   // 12 bytes
aad        = the 8-byte frame header
ciphertext = AES-256-GCM(directionKey, nonce, aad, plaintext)
payload    = ciphertext || tag(16B)
```

`counter` starts at 0 and increments by one per frame **per direction, across
all channels**. A gap or repeat in the counter is a protocol violation and
closes the connection. `length` in the header therefore equals
`4 + plaintextLength + 16`.

---

## 5. Control channel

Payload is UTF-8 JSON, one envelope per frame:

```json
{ "t":"camera.command", "id":42, "r":0, "p":{ } }
```

| field | type | meaning |
|-------|------|---------|
| `t`   | string | message type |
| `id`  | u32    | sender-assigned, monotonically increasing, non-zero |
| `r`   | u32    | id this message replies to, or omitted |
| `p`   | object | type-specific payload |

A receiver that does not recognise `t` ignores the frame. If the sender needed a
reply it times out and surfaces a real error — it must never hang forever.

### 5.1 Types

#### Device and capability

| type | direction | payload |
|------|-----------|---------|
| `device.info` | both | name, model, os, app version, capability flags |
| `camera.capabilities` | phone to pc | full capability tree, 5.2 |
| `camera.state` | phone to pc | authoritative `CameraState`, 5.3 |
| `camera.command` | pc to phone | one mutation, 5.4 |
| `camera.command.result` | phone to pc | `{ ok, appliedVersion, error }` |

#### Streaming

| type | direction | payload |
|------|-----------|---------|
| `stream.start` | pc to phone | `{ profile: StreamProfile }` |
| `stream.stop` | pc to phone | `{ }` |
| `stream.config` | pc to phone | `{ profile: StreamProfile }` - change without restart |
| `stream.status` | phone to pc | `{ active, actual: StreamProfile, reason }` |

`StreamProfile` is what the **PC receives**, and is independent of what the
phone captures or records:

```json
{ "width":1920, "height":1080, "fps":30, "codec":"h264",
  "bitrate":8000000, "keyframeIntervalSeconds":2 }
```

#### Recording and capture

| type | direction | payload |
|------|-----------|---------|
| `record.start` | both | `{ target, sessionId, startedAtUs }` |
| `record.stop` | both | `{ sessionId }` |
| `record.state` | phone to pc | `{ recording, sessionId, target, elapsedUs, phoneOk, pcOk }` |
| `photo.capture` | pc to phone | `{ target, requestId }` |
| `photo.result` | phone to pc | `{ requestId, ok, assetId, transferId, error }` |

`target` is one of `phone`, `pc`, `both`.

#### Telemetry

Sent unsolicited by the phone, at most **once per second**, and only when a
value actually changed:

```json
{ "t":"telemetry", "p":{
    "thermal":"normal",
    "pressure":"nominal",
    "battery":0.82,
    "power":"usb",
    "storageFreeBytes":88123456789,
    "capture":{ "fps":59.9, "dropped":0 },
    "encoder":{ "fps":30.0, "bitrate":7940000, "latencyUs":4100 } } }
```

`thermal` is `normal | elevated | high | critical`.
`pressure` is `nominal | fair | serious | shutdown`.
`power` is `battery | usb | wireless`.

There is deliberately **no temperature value** anywhere in this protocol. iOS
exposes no public sensor for it, so iCam does not invent one.

#### Time synchronisation

```json
{ "t":"time.ping", "id":7,  "p":{ "t1":0 } }
{ "t":"time.pong", "r":7,   "p":{ "t1":0, "t2":0, "t3":0 } }
```

All values are sender-monotonic microseconds. The initiator computes
`rtt = (t4-t1) - (t3-t2)` and `offset = ((t2-t1) + (t3-t4)) / 2`, keeps a
sliding window of the eight lowest `rtt` samples, and uses the median of their
offsets. Pings run every 2 s for the first 30 s of a session, then every 15 s.

### 5.2 `camera.capabilities`

Never invented, never hardcoded — always read from the live `AVCaptureDevice`.

```json
{ "lenses":[
    { "id":"back.ultrawide", "label":"0.5", "deviceType":"builtInUltraWideCamera",
      "minZoom":1.0, "maxZoom":6.0, "position":"back", "supportsMultiCam":true }
  ],
  "formats":[
    { "lensId":"back.wide", "width":1920, "height":1080,
      "fpsRanges":[[1,60]], "hdr":true, "codecs":["h264","hevc"],
      "stabilization":["off","standard","cinematic"],
      "isoRange":[34,3072], "exposureDurationUsRange":[125,1000000],
      "maxPhotoDimensions":[4032,3024], "supportsRaw":false }
  ],
  "torch":{ "supported":true, "levelAdjustable":true },
  "whiteBalance":{ "temperatureRange":[2000,10000], "tintRange":[-150,150] },
  "focus":{ "manual":true, "faceDriven":true },
  "multiCam":{ "supported":true, "combinations":[["back.wide","front"]] } }
```

### 5.3 `CameraState`

**One authoritative state object lives on the phone.** Windows never keeps a
second copy it believes in; it renders the last state it received and sends
commands. Every state carries a version:

```json
{ "v":184,
  "lensId":"back.wide", "zoom":1.0, "lensLocked":false,
  "width":1920, "height":1080, "fps":30, "codec":"hevc", "hdr":"auto",
  "exposureMode":"auto", "iso":80, "exposureDurationUs":8333, "ev":0.0,
  "exposureLocked":false,
  "whiteBalanceMode":"auto", "temperature":4800, "tint":0,
  "focusMode":"continuous", "focusPosition":0.42, "focusLocked":false,
  "stabilization":"standard", "torch":"off", "torchLevel":1.0,
  "mirrored":false, "orientation":"auto",
  "brightness":0.0, "contrast":0.0, "saturation":0.0, "warmth":0.0,
  "sharpness":0.0 }
```

The last five are the **image controls**, and they are the one part of this
state the phone does not act on. Each runs `-1.0` to `+1.0` and means "leave it
alone" at `0.0`. They live here rather than in a message of their own because
both ends must show the same five sliders, and because they are settings the
user expects to survive a reconnect — but they are applied by the PC, to the
preview and to `iCam Camera`, and never to the master recording. See
`docs/ARCHITECTURE.md`.

### 5.4 `camera.command`

```json
{ "t":"camera.command", "id":91,
  "p":{ "base":184, "set":{ "iso":200, "exposureMode":"manual" } } }
```

`base` is the state version the sender was looking at.

- If `base` equals the phone's current version, the mutation applies and the
  version increments.
- If `base` is **older**, the phone still applies the mutation, but only for the
  keys present in `set`. Last writer wins per key. This is deliberate: a stale
  ISO slider on the PC must not silently revert the user's white balance.
- The phone always answers with `camera.command.result` and always broadcasts
  the new full `camera.state`.

Values outside the live device's supported range are **clamped, not rejected**,
and the clamped value comes back in the new state so the PC slider snaps to
reality.

---

## 6. Video channel

Payload is a 24-byte header followed by the access unit.

```
offset size field
0      1    codec       1 = h264, 2 = hevc
1      1    flags       bit0 keyframe, bit1 parameterSets, bit2 endOfStream
2      2    reserved    u16be = 0
4      4    sequence    u32be, +1 per access unit, wraps
8      8    ptsUs       u64be, sender monotonic clock, microseconds
16     8    dtsUs       u64be
```

When `parameterSets` is set the payload is the codec configuration record
(`avcC` for H.264, `hvcC` for HEVC) and `sequence` and `ptsUs` carry the values
of the next access unit. A configuration frame is sent before the first frame,
again before every IDR after a format change, and on every reconnect.

Otherwise the payload is **AVCC**: a sequence of `u32be length` + NAL unit. Not
Annex-B — AVCC maps directly onto both `CMSampleBuffer` and Media Foundation
without a conversion pass.

Video is dropped, never queued, when the link is congested. Timing is worth more
than completeness on a live camera feed.

## 7. Audio channel

```
offset size field
0      1    codec       1 = aac-lc, 2 = pcm_s16le
1      1    channels
2      1    flags       bit1 parameterSets (AudioSpecificConfig)
3      1    reserved
4      4    sampleRate  u32be
8      4    sequence    u32be
12     8    ptsUs       u64be
```

Audio is never dropped for congestion before video is. A gap in audio is far
more audible than a dropped video frame is visible.

## 8. Bulk channel

Used for photo copies and for the missing-segment recovery described in
`docs/ARCHITECTURE.md`.

```
offset size field
0      1    kind        1 = offer, 2 = chunk, 3 = ack, 4 = done, 5 = cancel
1      3    reserved
4      4    transferId  u32be
8      8    offset      u64be
16     N    body
```

An `offer` body is JSON:
`{ "name":"", "bytes":0, "sha256":"", "kind":"photo", "sessionId":"", "rangeUs":[0,0] }`.
Chunks are at most 256 KiB. The receiver acks every 4 MiB. An interrupted
transfer resumes from the last acked offset — recovery transfers can be long and
must survive a Wi-Fi blip.

---

## 9. Errors

```json
{ "t":"error", "r":91,
  "p":{ "code":"camera.busy", "message":"", "detail":"AVError -11800" } }
```

`code` is a stable machine identifier. `message` is already-localised, human
text — the receiving UI shows it as-is. `detail` is technical and only surfaces
inside Developer Diagnostics.

Defined codes: `protocol.version`, `protocol.malformed`, `auth.untrusted`,
`auth.failed`, `camera.busy`, `camera.unavailable`, `camera.unsupported`,
`storage.full`, `record.active`, `record.failed`, `stream.unsupported`,
`internal`.
