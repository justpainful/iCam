# iCam Camera

The device other Windows applications select. Zoom, Teams, Discord, OBS, the
browser — as far as any of them can tell, `iCam Camera` is a webcam.

---

## Why it is a separate process

`MFCreateVirtualCamera` registers a **software camera source**: a COM class
that Windows loads into the **Frame Server** service (`svchost.exe -k Camera`),
not into iCam. Applications talk to the Frame Server, and the Frame Server
talks to our DLL.

That is not an inconvenience — it is the reason the design works. Because the
camera lives in a system service, closing the iCam window does not remove the
camera from a call that is already running. It is also why `iCam Camera` can
appear in an application's device list before iCam has anything to show.

```
   Discord ──► Windows Frame Server ──► iCam.VirtualCamera.dll
                  (session 0)                    │
                                                 │ named pipe
                                                 ▼
                                          iCam.exe (the user's session)
                                                 ▲
                                                 │ decoded NV12
                                          iPhone stream
```

## Why a named pipe and not shared memory

The obvious design is a shared-memory ring. It does not work here, and the
reason is worth writing down so nobody re-derives it later.

The Frame Server runs as **LocalService in session 0**. The iCam application
runs as the user, in their own session. Named kernel objects are
session-scoped: a `Local\` name created by the app is invisible to the service.
The `Global\` namespace crosses sessions, but *creating* an object there needs
`SeCreateGlobalPrivilege`, which an ordinary user does not have — so a
shared-memory ring would only work for administrators.

**Named pipes are not session-scoped.** `\\.\pipe\name` is a single global
namespace, and a pipe can be created with a DACL that lets the Frame Server
connect. So iCam hosts the pipe and the DLL connects to it.

The direction matters too: **the application is the server**. If it were the
other way round, the pipe would only exist while the Frame Server had our DLL
loaded, and iCam would have nothing to connect to until somebody opened a
camera app. With the app as server, the DLL simply retries, and shows a holding
pattern until iCam answers.

## The pipe

`\\.\pipe\iCam.Camera.v1`, byte mode, one client at a time.

### Request — client (DLL) to server (app), once, 24 bytes

```
offset size field
0      4    magic       'ICAM' = 0x4D414349, little-endian
4      4    version     1
8      4    width       the format the Frame Server negotiated
12     4    height
16     4    fps
20     4    reserved    0
```

The DLL sends the format it has to produce. The application scales its decoded
frame to exactly that, which keeps every conversion on the machine with a GPU
and a wall socket, and keeps the DLL a copier rather than a renderer.

### Frame — server to client, repeatedly, 32-byte header then payload

```
offset size field
0      4    magic         'ICFR' = 0x52464349, little-endian
4      4    width
8      4    height
12     4    stride        luma stride in bytes; chroma rows use the same stride
16     4    payloadBytes  stride * height * 3 / 2
20     4    flags         bit0 = holding pattern rather than camera video
24     8    ptsUs         application monotonic clock, microseconds
```

Payload is **NV12**: a full-resolution luma plane, then one interleaved
Cb/Cr plane at half height. It is the format Media Foundation and every
consumer of a webcam already expect, so nothing downstream has to convert.

A writer that falls behind drops frames rather than queuing them. A conference
call would rather skip a frame than drift behind its own audio.

## What the user sees when iCam has nothing

The DLL never fails to produce video. With no application connected, or no
iPhone streaming, it emits a slow, quiet holding frame — the iCam mark and a
line of text — at a low frame rate.

This is deliberate. An application that opens a camera and receives nothing
shows a black rectangle, a spinner, or an error, and the user has no idea
whether the fault is iCam, Windows, or Discord. A frame that says what is
happening costs almost nothing and answers the question.

## What the registered class actually is

This is the part no amount of reading the documentation makes obvious, and
getting it wrong fails **silently**: `MFCreateVirtualCamera` returns `S_OK`
and the camera simply never appears.

The CLSID is **not** the media source. Windows creates the class and
immediately asks it for `IMFActivate`. The registered object is an
*activator*; the media source is what its `ActivateObject` hands back.

Two more that fail the same quiet way:

- **Every interface Windows asks for has to be answered, including base
  interfaces.** WRL only responds for the interfaces named in the class list,
  so `IMFMediaSourceEx` deriving from `IMFMediaSource` is not enough — the
  pipeline asks for the base interface too. `ChainInterfaces` is what makes
  them resolve to the same object.
- **A live source timestamps against the pipeline's presentation clock.**
  Numbering frames from zero hands the pipeline samples that are hours old.
  Every one is discarded as too late, and the symptom is a camera that
  accepts thousands of sample requests a second and delivers nothing.

## Registration

The DLL is a standard in-process COM server under a fixed CLSID:

```
HKLM\SOFTWARE\Classes\CLSID\{6EA042AA-06DB-4533-BADC-ADDF389ED998}\InprocServer32
    (Default)      = %ProgramData%\iCam\VirtualCamera\iCam.VirtualCamera.dll
    ThreadingModel = Both
```

**Machine-wide, and therefore administrator once.** A per-user registration
under `HKCU` does not work, and it is worth being precise about why: the Frame
Server runs as a service, in its own account, and cannot see the current
user's registry hive. `MFCreateVirtualCamera` still succeeds — it is
`IMFVirtualCamera::Start` that fails, with `ERROR_PATH_NOT_FOUND`.

The DLL also has to live somewhere a service can read, which a user profile is
not. It is installed to `%ProgramData%\iCam\VirtualCamera`.

`register.ps1` does both and `register.ps1 -Remove` undoes both, leaving
nothing behind. This is the same one-time elevation OBS Virtual Camera and
every other Windows virtual camera asks for.
