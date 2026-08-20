#include "HoldingPattern.h"

#include <algorithm>
#include <cmath>

namespace icam {

namespace {

// BT.709 studio swing. HD video is BT.709, and a source that hands the
// pipeline full-range values in a limited-range format shows up as crushed
// blacks and clipped highlights in every consumer.
inline void RgbToYuv(BYTE r, BYTE g, BYTE b, BYTE& y, BYTE& cb, BYTE& cr) {
    const double red = r;
    const double green = g;
    const double blue = b;

    const double luma = 16.0 + 0.1826 * red + 0.6142 * green + 0.0620 * blue;
    const double chromaB = 128.0 - 0.1006 * red - 0.3386 * green + 0.4392 * blue;
    const double chromaR = 128.0 + 0.4392 * red - 0.3989 * green - 0.0403 * blue;

    y = static_cast<BYTE>(std::clamp(luma, 16.0, 235.0));
    cb = static_cast<BYTE>(std::clamp(chromaB, 16.0, 240.0));
    cr = static_cast<BYTE>(std::clamp(chromaR, 16.0, 240.0));
}

const wchar_t* Headline(HoldingPattern::State state) {
    switch (state) {
    case HoldingPattern::State::ApplicationNotRunning: return L"iCam is not running";
    case HoldingPattern::State::WaitingForPhone:       return L"Waiting for your iPhone";
    case HoldingPattern::State::StreamInterrupted:     return L"Reconnecting to your iPhone";
    }
    return L"iCam";
}

const wchar_t* Detail(HoldingPattern::State state) {
    switch (state) {
    case HoldingPattern::State::ApplicationNotRunning:
        return L"Open iCam on this computer to use your iPhone as a camera.";
    case HoldingPattern::State::WaitingForPhone:
        return L"Open iCam on your iPhone. Your devices should find each other automatically.";
    case HoldingPattern::State::StreamInterrupted:
        return L"Your iPhone stopped sending. Anything it was recording is still safe.";
    }
    return L"";
}

}  // namespace

HoldingPattern::~HoldingPattern() {
    Release();
}

void HoldingPattern::Release() {
    if (dc_) {
        if (previousBitmap_) SelectObject(dc_, previousBitmap_);
        DeleteDC(dc_);
        dc_ = nullptr;
    }
    if (bitmap_) {
        DeleteObject(bitmap_);
        bitmap_ = nullptr;
    }
    if (titleFont_) {
        DeleteObject(titleFont_);
        titleFont_ = nullptr;
    }
    if (statusFont_) {
        DeleteObject(statusFont_);
        statusFont_ = nullptr;
    }
    pixels_ = nullptr;
    width_ = 0;
    height_ = 0;
}

bool HoldingPattern::EnsureSurface(UINT32 width, UINT32 height) {
    if (dc_ && width_ == width && height_ == height) return true;
    Release();

    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = static_cast<LONG>(width);
    // Negative height for a top-down DIB, so row 0 is the top row and the NV12
    // conversion does not have to walk the image backwards.
    info.bmiHeader.biHeight = -static_cast<LONG>(height);
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    bitmap_ = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!bitmap_ || !bits) {
        Release();
        return false;
    }

    dc_ = CreateCompatibleDC(nullptr);
    if (!dc_) {
        Release();
        return false;
    }
    previousBitmap_ = static_cast<HBITMAP>(SelectObject(dc_, bitmap_));
    pixels_ = static_cast<BYTE*>(bits);
    width_ = width;
    height_ = height;

    // Sized from the frame rather than fixed, so the card reads the same at
    // 720p and at 1080p.
    const int titleHeight = -static_cast<int>(height / 9);
    const int statusHeight = -static_cast<int>(height / 26);

    titleFont_ = CreateFontW(titleHeight, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, VARIABLE_PITCH, L"Segoe UI");
    statusFont_ = CreateFontW(statusHeight, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, VARIABLE_PITCH, L"Segoe UI");
    return titleFont_ != nullptr && statusFont_ != nullptr;
}

void HoldingPattern::Draw(State state, UINT64 frameIndex, UINT32 fps) {
    const int width = static_cast<int>(width_);
    const int height = static_cast<int>(height_);

    // Near-black, matching the iPhone app. Not pure black: a genuinely black
    // frame is indistinguishable from a camera that has failed, which is the
    // ambiguity this whole card exists to remove.
    HBRUSH background = CreateSolidBrush(RGB(10, 10, 11));
    RECT full{0, 0, width, height};
    FillRect(dc_, &full, background);
    DeleteObject(background);

    SetBkMode(dc_, TRANSPARENT);

    // A slow breath rather than a blink. It tells the viewer the camera is
    // live without becoming the most interesting thing in a meeting.
    const double period = std::max(1u, fps) * 3.0;
    const double phase = static_cast<double>(frameIndex % static_cast<UINT64>(period)) / period;
    const double breath = 0.5 + 0.5 * std::sin(phase * 6.28318530718);

    RECT line{};

    SelectObject(dc_, titleFont_);
    SetTextColor(dc_, RGB(236, 236, 238));
    line = {0, static_cast<LONG>(height * 0.34), width, static_cast<LONG>(height * 0.50)};
    DrawTextW(dc_, L"iCam", -1, &line, DT_CENTER | DT_SINGLELINE | DT_VCENTER);

    SelectObject(dc_, statusFont_);
    const BYTE headlineTone = static_cast<BYTE>(150 + 60 * breath);
    SetTextColor(dc_, RGB(headlineTone, headlineTone, headlineTone + 2));
    line = {0, static_cast<LONG>(height * 0.52), width, static_cast<LONG>(height * 0.60)};
    DrawTextW(dc_, Headline(state), -1, &line, DT_CENTER | DT_SINGLELINE | DT_VCENTER);

    SetTextColor(dc_, RGB(112, 112, 118));
    line = {static_cast<LONG>(width * 0.15), static_cast<LONG>(height * 0.61),
            static_cast<LONG>(width * 0.85), static_cast<LONG>(height * 0.72)};
    DrawTextW(dc_, Detail(state), -1, &line,
              DT_CENTER | DT_WORDBREAK | DT_EDITCONTROL);

    // A hairline under the wordmark, the same restrained separator the rest of
    // the product uses.
    HBRUSH rule = CreateSolidBrush(RGB(38, 38, 42));
    RECT hairline{static_cast<LONG>(width * 0.42), static_cast<LONG>(height * 0.505),
                  static_cast<LONG>(width * 0.58), static_cast<LONG>(height * 0.505) + 1};
    FillRect(dc_, &hairline, rule);
    DeleteObject(rule);

    GdiFlush();
}

void HoldingPattern::ConvertToNV12(BYTE* destination, UINT32 stride) const {
    BYTE* chroma = destination + static_cast<size_t>(stride) * height_;

    for (UINT32 y = 0; y < height_; ++y) {
        const BYTE* source = pixels_ + static_cast<size_t>(y) * width_ * 4;
        BYTE* luma = destination + static_cast<size_t>(y) * stride;

        for (UINT32 x = 0; x < width_; ++x) {
            BYTE cb, cr;
            RgbToYuv(source[x * 4 + 2], source[x * 4 + 1], source[x * 4 + 0],
                     luma[x], cb, cr);
        }
    }

    // Chroma is subsampled by averaging each 2x2 block rather than point
    // sampling: point sampling puts visible jaggies on the edges of text,
    // which is most of what this frame contains.
    for (UINT32 y = 0; y + 1 < height_; y += 2) {
        BYTE* row = chroma + static_cast<size_t>(y / 2) * stride;
        const BYTE* top = pixels_ + static_cast<size_t>(y) * width_ * 4;
        const BYTE* bottom = top + static_cast<size_t>(width_) * 4;

        for (UINT32 x = 0; x + 1 < width_; x += 2) {
            int red = 0;
            int green = 0;
            int blue = 0;
            for (const BYTE* line : {top, bottom}) {
                for (UINT32 offset : {x, x + 1}) {
                    blue += line[offset * 4 + 0];
                    green += line[offset * 4 + 1];
                    red += line[offset * 4 + 2];
                }
            }

            BYTE luma, cb, cr;
            RgbToYuv(static_cast<BYTE>(red / 4), static_cast<BYTE>(green / 4),
                     static_cast<BYTE>(blue / 4), luma, cb, cr);
            row[x] = cb;
            row[x + 1] = cr;
        }
    }
}

void HoldingPattern::Render(BYTE* destination, UINT32 stride, UINT32 width, UINT32 height,
                            State state, UINT64 frameIndex, UINT32 fps) {
    if (!EnsureSurface(width, height)) {
        // GDI is unavailable for some reason. A flat dark frame is still far
        // better than handing the pipeline nothing.
        for (UINT32 y = 0; y < height; ++y) {
            std::memset(destination + static_cast<size_t>(y) * stride, 16, width);
        }
        BYTE* chroma = destination + static_cast<size_t>(stride) * height;
        for (UINT32 y = 0; y < height / 2; ++y) {
            std::memset(chroma + static_cast<size_t>(y) * stride, 128, width);
        }
        return;
    }

    Draw(state, frameIndex, fps);
    ConvertToNV12(destination, stride);
}

}  // namespace icam
