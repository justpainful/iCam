#include "pch.h"

#include <cstdarg>
#include <cstdio>

namespace icam {

namespace {

// The Frame Server runs as a service in session 0. There is no console, no
// stdout anyone will see, and no debugger attached unless somebody went looking.
// A file in a world-writable location is the only channel that works from both
// sides, and it is what turns "E_NOINTERFACE" into an answer.
const wchar_t* kLogPath = L"C:\\Users\\Public\\icam-virtualcamera.log";

std::mutex& LogMutex() {
    static std::mutex mutex;
    return mutex;
}

// Off unless somebody turns it on. The camera pipeline queries interfaces
// thousands of times a second, and a file write per call would cost more than
// the frames do.
//
// Read from HKLM, not HKCU: this DLL runs inside the Frame Server, as
// LocalService, whose HKCU is not the user's. A per-user flag here is
// invisible to the only process that would honour it.
//
//   reg add HKLM\Software\iCam /v VirtualCameraLogging /t REG_DWORD /d 1 /reg:64
bool LoggingEnabled() {
    static const bool enabled = [] {
        DWORD value = 0;
        DWORD size = sizeof(value);
        DWORD type = REG_DWORD;
        const LSTATUS status = RegGetValueW(HKEY_LOCAL_MACHINE, L"Software\\iCam",
                                            L"VirtualCameraLogging", RRF_RT_REG_DWORD,
                                            &type, &value, &size);
        return status == ERROR_SUCCESS && value != 0;
    }();
    return enabled;
}

void Append(const char* text) {
    std::lock_guard<std::mutex> guard(LogMutex());

    HANDLE file = CreateFileW(kLogPath, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;

    SYSTEMTIME now{};
    GetLocalTime(&now);

    char line[1024];
    const int length = _snprintf_s(line, _TRUNCATE, "%02d:%02d:%02d.%03d [%lu] %s\r\n",
                                   now.wHour, now.wMinute, now.wSecond, now.wMilliseconds,
                                   GetCurrentProcessId(), text);
    if (length > 0) {
        DWORD written = 0;
        WriteFile(file, line, static_cast<DWORD>(length), &written, nullptr);
    }
    CloseHandle(file);
}

}  // namespace

void LogLine(const char* format, ...) {
    if (!LoggingEnabled()) return;
    char buffer[900];
    va_list args;
    va_start(args, format);
    _vsnprintf_s(buffer, _TRUNCATE, format, args);
    va_end(args);
    Append(buffer);
}

void LogInterface(const char* prefix, REFIID riid, HRESULT result) {
    if (!LoggingEnabled()) return;
    wchar_t wide[64]{};
    StringFromGUID2(riid, wide, ARRAYSIZE(wide));

    char narrow[64]{};
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, narrow, sizeof(narrow), nullptr, nullptr);

    LogLine("%s %s -> 0x%08X%s", prefix, narrow, static_cast<unsigned>(result),
            FAILED(result) ? "   <-- refused" : "");
}

}  // namespace icam
