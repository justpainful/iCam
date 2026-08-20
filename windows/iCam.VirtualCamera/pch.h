// iCam Camera — the Media Foundation software camera source.
//
// Loaded by the Windows Frame Server, not by iCam. See docs/VIRTUAL-CAMERA.md
// for why, and for the pipe contract this DLL speaks.

#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <combaseapi.h>
#include <initguid.h>

#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <mfvirtualcamera.h>
#include <ks.h>
#include <ksmedia.h>

#include <wrl/client.h>
#include <wrl/implements.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;

// {6EA042AA-06DB-4533-BADC-ADDF389ED998}
//
// Stable for the life of the product. Changing it orphans every existing
// registration, so it is written here once and never regenerated.
DEFINE_GUID(CLSID_ICamCameraSource,
            0x6ea042aa, 0x06db, 0x4533, 0xba, 0xdc, 0xad, 0xdf, 0x38, 0x9e, 0xd9, 0x98);

#define ICAM_CLSID_STRING L"{6EA042AA-06DB-4533-BADC-ADDF389ED998}"
#define ICAM_FRIENDLY_NAME L"iCam Camera"
#define ICAM_PIPE_NAME L"\\\\.\\pipe\\iCam.Camera.v1"

// A tiny local version of wil's macro. One dependency avoided, and the failure
// path stays visible at every call site.
#define RETURN_IF_FAILED(expression) \
    do { const HRESULT icam_hr__ = (expression); if (FAILED(icam_hr__)) return icam_hr__; } while (0)

// IKsControl, from ksproxy.h. Declared here rather than pulling in that
// DirectShow-era header for three methods, and because ks.h only declares it
// behind guards that do not give it a UUID WRL can use.
MIDL_INTERFACE("28F54685-06FD-11D2-B27A-00A0C9223196")
IKsControlLite : public IUnknown {
    STDMETHOD(KsProperty)(PKSPROPERTY property, ULONG propertyLength, PVOID data,
                          ULONG dataLength, ULONG* bytesReturned) PURE;
    STDMETHOD(KsMethod)(PKSMETHOD method, ULONG methodLength, PVOID data,
                        ULONG dataLength, ULONG* bytesReturned) PURE;
    STDMETHOD(KsEvent)(PKSEVENT event, ULONG eventLength, PVOID data,
                       ULONG dataLength, ULONG* bytesReturned) PURE;
};

namespace icam {

// Diagnostics from inside the Frame Server, which runs as a service in session
// 0 where there is no console to print to and no debugger attached by default.
// Without this, every failure in here is a bare HRESULT with no context.
void LogLine(const char* format, ...);
void LogInterface(const char* prefix, REFIID riid, HRESULT result);

// The formats iCam Camera offers. Deliberately short: every entry is a format
// the application has to be able to produce, and a list of twenty would only
// make consumers pick badly.
struct VideoFormat {
    UINT32 width;
    UINT32 height;
    UINT32 fps;
};

inline constexpr VideoFormat kFormats[] = {
    {1280, 720, 30},
    {1920, 1080, 30},
};

inline constexpr UINT32 kDefaultFormatIndex = 0;

// Pipe framing — docs/VIRTUAL-CAMERA.md.
inline constexpr UINT32 kRequestMagic = 0x4D414349;  // 'ICAM'
inline constexpr UINT32 kFrameMagic = 0x52464349;    // 'ICFR'
inline constexpr UINT32 kProtocolVersion = 1;

#pragma pack(push, 1)
struct PipeRequest {
    UINT32 magic;
    UINT32 version;
    UINT32 width;
    UINT32 height;
    UINT32 fps;
    UINT32 reserved;
};

struct PipeFrameHeader {
    UINT32 magic;
    UINT32 width;
    UINT32 height;
    UINT32 stride;
    UINT32 payloadBytes;
    UINT32 flags;
    UINT64 ptsUs;
};
#pragma pack(pop)

static_assert(sizeof(PipeRequest) == 24, "the pipe request is 24 bytes");
static_assert(sizeof(PipeFrameHeader) == 32, "the pipe frame header is 32 bytes");

inline UINT64 MonotonicUs() {
    using namespace std::chrono;
    return static_cast<UINT64>(
        duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count());
}

}  // namespace icam
