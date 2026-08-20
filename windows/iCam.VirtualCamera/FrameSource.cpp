#include "FrameSource.h"

#include <cmath>
#include <cstring>

namespace icam {

namespace {

// NV12 is planar: a full-resolution luma plane, then one interleaved Cb/Cr
// plane at half height. 128 in both chroma channels is neutral grey.
constexpr BYTE kNeutralChroma = 128;

void FillLuma(BYTE* destination, UINT32 stride, UINT32 width, UINT32 height, BYTE value) {
    for (UINT32 y = 0; y < height; ++y) {
        std::memset(destination + static_cast<size_t>(y) * stride, value, width);
    }
}

void FillChroma(BYTE* destination, UINT32 stride, UINT32 width, UINT32 height) {
    BYTE* chroma = destination + static_cast<size_t>(stride) * height;
    for (UINT32 y = 0; y < height / 2; ++y) {
        std::memset(chroma + static_cast<size_t>(y) * stride, kNeutralChroma, width);
    }
}

void DrawRectangle(BYTE* destination, UINT32 stride, UINT32 x, UINT32 y,
                   UINT32 width, UINT32 height, BYTE luma) {
    for (UINT32 row = 0; row < height; ++row) {
        std::memset(destination + static_cast<size_t>(y + row) * stride + x, luma, width);
    }
}

}  // namespace

FrameSource::~FrameSource() {
    Stop();
}

void FrameSource::Configure(UINT32 width, UINT32 height, UINT32 fps) {
    width_ = width;
    height_ = height;
    fps_ = fps;
}

void FrameSource::Start() {
    if (running_.exchange(true)) return;
    reader_ = std::thread([this] { ReaderLoop(); });
}

void FrameSource::Stop() {
    if (!running_.exchange(false)) return;

    // Closing the handle is what unblocks a reader parked in ReadFile.
    HANDLE pipe = pipe_;
    pipe_ = INVALID_HANDLE_VALUE;
    if (pipe != INVALID_HANDLE_VALUE) {
        CancelIoEx(pipe, nullptr);
        CloseHandle(pipe);
    }
    if (reader_.joinable()) reader_.join();
    connected_.store(false, std::memory_order_relaxed);
}

bool FrameSource::ConnectOnce() {
    HANDLE pipe = CreateFileW(ICAM_PIPE_NAME, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return false;

    PipeRequest request{};
    request.magic = kRequestMagic;
    request.version = kProtocolVersion;
    request.width = width_;
    request.height = height_;
    request.fps = fps_;

    DWORD written = 0;
    if (!WriteFile(pipe, &request, sizeof(request), &written, nullptr)
        || written != sizeof(request)) {
        CloseHandle(pipe);
        return false;
    }

    pipe_ = pipe;
    connected_.store(true, std::memory_order_relaxed);
    return true;
}

bool FrameSource::ReadExactly(void* buffer, DWORD bytes) {
    auto* cursor = static_cast<BYTE*>(buffer);
    DWORD remaining = bytes;
    while (remaining > 0) {
        DWORD read = 0;
        if (!ReadFile(pipe_, cursor, remaining, &read, nullptr) || read == 0) return false;
        cursor += read;
        remaining -= read;
    }
    return true;
}

void FrameSource::ReaderLoop() {
    while (running_.load(std::memory_order_relaxed)) {
        if (pipe_ == INVALID_HANDLE_VALUE) {
            if (!ConnectOnce()) {
                // iCam is not running, or has nothing to show yet. Retrying
                // slowly costs nothing and keeps the camera alive; the holding
                // pattern covers the gap.
                std::this_thread::sleep_for(std::chrono::milliseconds(500));
                continue;
            }
        }

        PipeFrameHeader header{};
        if (!ReadExactly(&header, sizeof(header)) || header.magic != kFrameMagic) {
            connected_.store(false, std::memory_order_relaxed);
            HANDLE pipe = pipe_;
            pipe_ = INVALID_HANDLE_VALUE;
            if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
            continue;
        }

        // A header that does not describe a frame this stream can hold is a
        // desynchronised pipe, not a frame to try to salvage.
        const UINT64 expected =
            static_cast<UINT64>(header.stride) * header.height * 3 / 2;
        if (header.payloadBytes != expected || header.payloadBytes == 0
            || header.payloadBytes > 64u * 1024 * 1024) {
            connected_.store(false, std::memory_order_relaxed);
            HANDLE pipe = pipe_;
            pipe_ = INVALID_HANDLE_VALUE;
            if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
            continue;
        }

        readBuffer_.resize(header.payloadBytes);
        if (!ReadExactly(readBuffer_.data(), header.payloadBytes)) {
            connected_.store(false, std::memory_order_relaxed);
            HANDLE pipe = pipe_;
            pipe_ = INVALID_HANDLE_VALUE;
            if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
            continue;
        }

        if (header.width == width_ && header.height == height_) {
            std::lock_guard<std::mutex> lock(latestMutex_);
            latest_.swap(readBuffer_);
            latestPtsUs_ = header.ptsUs;
            latestIsLive_ = (header.flags & 1u) == 0;
        }
    }
}

void FrameSource::FillFrame(BYTE* destination, UINT32 stride, UINT64* ptsUs, bool* isLive) {
    {
        std::lock_guard<std::mutex> lock(latestMutex_);
        const size_t needed = static_cast<size_t>(stride) * height_ * 3 / 2;
        if (!latest_.empty() && latest_.size() == needed) {
            std::memcpy(destination, latest_.data(), needed);
            if (ptsUs) *ptsUs = latestPtsUs_;
            if (isLive) *isLive = latestIsLive_;
            return;
        }
    }

    DrawHoldingPattern(destination, stride);
    if (ptsUs) *ptsUs = MonotonicUs();
    if (isLive) *isLive = false;
}

void FrameSource::DrawHoldingPattern(BYTE* destination, UINT32 stride) {
    ++frameCounter_;

    // Near-black, matching the application. Not pure black: a genuinely black
    // frame is indistinguishable from a camera that has failed, which is the
    // ambiguity this pattern exists to remove.
    FillLuma(destination, stride, width_, height_, 12);
    FillChroma(destination, stride, width_, height_);

    // A slow pulse, so it is obvious the camera is live rather than frozen.
    const double phase = static_cast<double>(frameCounter_ % (fps_ * 2)) / (fps_ * 2.0);
    const BYTE pulse = static_cast<BYTE>(60 + 40 * std::sin(phase * 6.28318530718));

    const UINT32 barWidth = width_ / 6;
    const UINT32 barHeight = std::max<UINT32>(4, height_ / 90);
    const UINT32 x = (width_ - barWidth) / 2;
    const UINT32 y = height_ / 2 - barHeight / 2;

    DrawRectangle(destination, stride, x & ~1u, y & ~1u,
                  barWidth & ~1u, barHeight & ~1u, pulse);

    // A second, dimmer bar below, so the mark reads as deliberate rather than
    // as a stuck line of pixels.
    const UINT32 subWidth = barWidth / 2;
    DrawRectangle(destination, stride, (width_ - subWidth) / 2 & ~1u,
                  (y + barHeight * 3) & ~1u, subWidth & ~1u,
                  std::max<UINT32>(2, barHeight / 2) & ~1u,
                  static_cast<BYTE>(pulse / 2));
}

}  // namespace icam
