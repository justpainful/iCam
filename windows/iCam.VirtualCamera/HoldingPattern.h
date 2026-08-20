#pragma once

#include "pch.h"

namespace icam {

// What `iCam Camera` shows when it has no picture from the iPhone.
//
// The DLL never fails to produce video, and it never produces a black
// rectangle. An application that opens a camera and receives nothing shows a
// black frame, a spinner, or an error, and the user cannot tell whether the
// fault is iCam, Windows, or Discord. A frame that says what is happening
// costs almost nothing and answers the question.
//
// Drawn here rather than in the application on purpose: the case that matters
// most is the one where iCam is not running, and then there is nobody else to
// draw it.
class HoldingPattern {
public:
    enum class State {
        // Nothing is connected to the pipe: iCam is not running at all.
        ApplicationNotRunning,
        // iCam is there, but no iPhone is sending yet.
        WaitingForPhone,
        // iCam was sending and stopped — the phone dropped, or is asleep.
        StreamInterrupted,
    };

    ~HoldingPattern();

    HoldingPattern(const HoldingPattern&) = delete;
    HoldingPattern& operator=(const HoldingPattern&) = delete;
    HoldingPattern() = default;

    // Renders one frame directly as NV12 into `destination`.
    void Render(BYTE* destination, UINT32 stride, UINT32 width, UINT32 height,
                State state, UINT64 frameIndex, UINT32 fps);

private:
    bool EnsureSurface(UINT32 width, UINT32 height);
    void Release();
    void Draw(State state, UINT64 frameIndex, UINT32 fps);
    void ConvertToNV12(BYTE* destination, UINT32 stride) const;

    HDC dc_ = nullptr;
    HBITMAP bitmap_ = nullptr;
    HBITMAP previousBitmap_ = nullptr;
    BYTE* pixels_ = nullptr;   // BGRA, top-down

    HFONT titleFont_ = nullptr;
    HFONT statusFont_ = nullptr;

    UINT32 width_ = 0;
    UINT32 height_ = 0;
};

}  // namespace icam
