#include "FrameSource.h"

#include <cmath>
#include <cstring>

namespace icam {

namespace {

// How long after the last frame the card comes back. Long enough to ride out a
// hiccup, short enough that a viewer is not left looking at a frozen face.
constexpr UINT64 kStaleAfterUs = 1'500'000;

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

void FrameSource::Disconnect() {
    connected_.store(false, std::memory_order_relaxed);
    HANDLE pipe = pipe_;
    pipe_ = INVALID_HANDLE_VALUE;
    if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);

    std::lock_guard<std::mutex> lock(latestMutex_);
    latest_.clear();
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
            Disconnect();
            continue;
        }

        // A header that does not describe a frame this stream can hold is a
        // desynchronised pipe, not a frame to try to salvage.
        const UINT64 expected =
            static_cast<UINT64>(header.stride) * header.height * 3 / 2;
        if (header.payloadBytes != expected || header.payloadBytes == 0
            || header.payloadBytes > 64u * 1024 * 1024) {
            Disconnect();
            continue;
        }

        readBuffer_.resize(header.payloadBytes);
        if (!ReadExactly(readBuffer_.data(), header.payloadBytes)) {
            Disconnect();
            continue;
        }

        if (header.width == width_ && header.height == height_) {
            {
                std::lock_guard<std::mutex> lock(latestMutex_);
                latest_.swap(readBuffer_);
                latestPtsUs_ = header.ptsUs;
                latestIsLive_ = (header.flags & 1u) == 0;
            }
            lastFrameUs_.store(MonotonicUs(), std::memory_order_relaxed);
            everReceived_.store(true, std::memory_order_relaxed);
        }
    }
}

HoldingPattern::State FrameSource::CurrentState() const {
    if (!connected_.load(std::memory_order_relaxed)) {
        return HoldingPattern::State::ApplicationNotRunning;
    }
    return everReceived_.load(std::memory_order_relaxed)
        ? HoldingPattern::State::StreamInterrupted
        : HoldingPattern::State::WaitingForPhone;
}

void FrameSource::FillFrame(BYTE* destination, UINT32 stride, UINT64* ptsUs, bool* isLive) {
    const UINT64 last = lastFrameUs_.load(std::memory_order_relaxed);
    const bool fresh = last != 0 && MonotonicUs() - last < kStaleAfterUs;

    if (fresh) {
        std::lock_guard<std::mutex> lock(latestMutex_);
        const size_t needed = static_cast<size_t>(stride) * height_ * 3 / 2;
        if (!latest_.empty() && latest_.size() == needed) {
            std::memcpy(destination, latest_.data(), needed);
            if (ptsUs) *ptsUs = latestPtsUs_;
            if (isLive) *isLive = latestIsLive_;
            return;
        }
    }

    holding_.Render(destination, stride, width_, height_, CurrentState(),
                    frameCounter_++, fps_);
    if (ptsUs) *ptsUs = MonotonicUs();
    if (isLive) *isLive = false;
}


}  // namespace icam
