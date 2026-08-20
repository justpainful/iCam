#pragma once

#include "pch.h"

namespace icam {

// Produces one NV12 frame whenever the stream asks for one.
//
// Two sources, in order of preference: the iCam application over the named
// pipe, and — when that is not answering — a holding pattern generated here.
//
// The holding pattern is not a placeholder for missing work. An application
// that opens a camera and receives nothing shows a black rectangle or an error,
// and the user cannot tell whether the fault is iCam, Windows, or Discord. A
// frame that says what is happening costs almost nothing and answers that.
class FrameSource {
public:
    FrameSource() = default;
    ~FrameSource();

    FrameSource(const FrameSource&) = delete;
    FrameSource& operator=(const FrameSource&) = delete;

    // Sets the format the Frame Server negotiated. The application is told, and
    // scales to it, so this class never has to resample.
    void Configure(UINT32 width, UINT32 height, UINT32 fps);

    void Start();
    void Stop();

    // Fills `destination` with one NV12 frame. `stride` is the luma stride.
    // Always succeeds: if the application is not connected, the holding pattern
    // is drawn instead.
    void FillFrame(BYTE* destination, UINT32 stride, UINT64* ptsUs, bool* isLive);

    bool IsApplicationConnected() const { return connected_.load(std::memory_order_relaxed); }

private:
    void ReaderLoop();
    bool ConnectOnce();
    bool ReadExactly(void* buffer, DWORD bytes);
    void DrawHoldingPattern(BYTE* destination, UINT32 stride);

    UINT32 width_ = kFormats[kDefaultFormatIndex].width;
    UINT32 height_ = kFormats[kDefaultFormatIndex].height;
    UINT32 fps_ = kFormats[kDefaultFormatIndex].fps;

    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    std::thread reader_;
    std::atomic<bool> running_{false};
    std::atomic<bool> connected_{false};

    // One completed frame, swapped under the lock. Deliberately not a queue:
    // a consumer that is behind should see the newest frame, not work through
    // a backlog it will only fall further behind on.
    std::mutex latestMutex_;
    std::vector<BYTE> latest_;
    UINT64 latestPtsUs_ = 0;
    bool latestIsLive_ = false;

    std::vector<BYTE> readBuffer_;
    UINT64 frameCounter_ = 0;
};

}  // namespace icam
