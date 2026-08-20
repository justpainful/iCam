#include "MediaStream.h"
#include "MediaSource.h"

namespace icam {

namespace {

constexpr UINT64 kHundredNanosPerSecond = 10'000'000ULL;

// NV12 rows are padded to an even width; the luma stride is the row pitch and
// the chroma plane reuses it.
UINT32 LumaStride(UINT32 width) {
    return (width + 1) & ~1u;
}

}  // namespace

HRESULT MediaStream::Initialize(MediaSource* source, UINT32 formatIndex) {
    source_ = source;

    width_ = kFormats[formatIndex].width;
    height_ = kFormats[formatIndex].height;
    fps_ = kFormats[formatIndex].fps;

    RETURN_IF_FAILED(MFCreateEventQueue(&events_));

    // Every format is offered, with the default first: consumers that take the
    // first entry rather than negotiating still get something sensible.
    std::vector<ComPtr<IMFMediaType>> types;
    std::vector<IMFMediaType*> raw;
    for (UINT32 i = 0; i < ARRAYSIZE(kFormats); ++i) {
        ComPtr<IMFMediaType> type;
        RETURN_IF_FAILED(CreateMediaType(i, &type));
        types.push_back(type);
        raw.push_back(type.Get());
    }

    RETURN_IF_FAILED(MFCreateStreamDescriptor(0, static_cast<DWORD>(raw.size()),
                                              raw.data(), &descriptor_));

    ComPtr<IMFMediaTypeHandler> handler;
    RETURN_IF_FAILED(descriptor_->GetMediaTypeHandler(&handler));
    RETURN_IF_FAILED(handler->SetCurrentMediaType(types[kDefaultFormatIndex].Get()));

    // What marks this as a camera stream rather than an arbitrary media stream.
    // Without these a consumer will not treat the source as a webcam.
    RETURN_IF_FAILED(descriptor_->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 0));
    RETURN_IF_FAILED(descriptor_->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY,
                                          PINNAME_VIDEO_CAPTURE));
    RETURN_IF_FAILED(descriptor_->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES,
                                            MFFrameSourceTypes_Color));

    frames_.Configure(width_, height_, fps_);
    return S_OK;
}

HRESULT MediaStream::CreateMediaType(UINT32 formatIndex, IMFMediaType** type) {
    const VideoFormat& format = kFormats[formatIndex];

    ComPtr<IMFMediaType> media;
    RETURN_IF_FAILED(MFCreateMediaType(&media));
    RETURN_IF_FAILED(media->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    RETURN_IF_FAILED(media->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12));
    RETURN_IF_FAILED(media->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    RETURN_IF_FAILED(media->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE));
    RETURN_IF_FAILED(media->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE));
    RETURN_IF_FAILED(MFSetAttributeSize(media.Get(), MF_MT_FRAME_SIZE,
                                        format.width, format.height));
    RETURN_IF_FAILED(MFSetAttributeRatio(media.Get(), MF_MT_FRAME_RATE, format.fps, 1));
    RETURN_IF_FAILED(MFSetAttributeRatio(media.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));

    const UINT32 stride = LumaStride(format.width);
    RETURN_IF_FAILED(media->SetUINT32(MF_MT_DEFAULT_STRIDE, stride));
    RETURN_IF_FAILED(media->SetUINT32(MF_MT_SAMPLE_SIZE, stride * format.height * 3 / 2));

    *type = media.Detach();
    return S_OK;
}

HRESULT MediaStream::SetSelectedFormat(IMFMediaType* type) {
    std::lock_guard<std::mutex> guard(lock_);

    UINT32 width = 0;
    UINT32 height = 0;
    RETURN_IF_FAILED(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &width, &height));

    UINT32 numerator = 30;
    UINT32 denominator = 1;
    MFGetAttributeRatio(type, MF_MT_FRAME_RATE, &numerator, &denominator);

    width_ = width;
    height_ = height;
    fps_ = denominator > 0 ? std::max<UINT32>(1, numerator / denominator) : 30;

    // Telling the application the negotiated format is what keeps every
    // conversion on the machine with a GPU and a wall socket, and keeps this
    // DLL a copier rather than a renderer.
    LogLine("MediaStream::SetSelectedFormat %ux%u@%u", width_, height_, fps_);
    frames_.Configure(width_, height_, fps_);
    return S_OK;
}

HRESULT MediaStream::Shutdown() {
    std::lock_guard<std::mutex> guard(lock_);
    shutdown_ = true;
    frames_.Stop();
    if (events_) {
        events_->Shutdown();
        events_.Reset();
    }
    descriptor_.Reset();
    source_ = nullptr;
    return S_OK;
}

// MARK: - IMFMediaEventGenerator

IFACEMETHODIMP MediaStream::BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) {
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_ || !events_) return MF_E_SHUTDOWN;
    return events_->BeginGetEvent(callback, state);
}

IFACEMETHODIMP MediaStream::EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) {
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_ || !events_) return MF_E_SHUTDOWN;
    return events_->EndGetEvent(result, event);
}

IFACEMETHODIMP MediaStream::GetEvent(DWORD flags, IMFMediaEvent** event) {
    ComPtr<IMFMediaEventQueue> queue;
    {
        std::lock_guard<std::mutex> guard(lock_);
        if (shutdown_ || !events_) return MF_E_SHUTDOWN;
        queue = events_;
    }
    // Called outside the lock: GetEvent blocks, and holding the lock across it
    // would deadlock anything trying to queue an event.
    return queue->GetEvent(flags, event);
}

IFACEMETHODIMP MediaStream::QueueEvent(MediaEventType type, REFGUID extendedType,
                                       HRESULT status, const PROPVARIANT* data) {
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_ || !events_) return MF_E_SHUTDOWN;
    return events_->QueueEventParamVar(type, extendedType, status, data);
}

// MARK: - IMFMediaStream

IFACEMETHODIMP MediaStream::GetMediaSource(IMFMediaSource** source) {
    if (!source) return E_POINTER;
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_ || !source_) return MF_E_SHUTDOWN;
    return source_->QueryInterface(IID_PPV_ARGS(source));
}

IFACEMETHODIMP MediaStream::GetStreamDescriptor(IMFStreamDescriptor** descriptor) {
    LogLine("MediaStream::GetStreamDescriptor");
    if (!descriptor) return E_POINTER;
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_ || !descriptor_) return MF_E_SHUTDOWN;
    return descriptor_.CopyTo(descriptor);
}

IFACEMETHODIMP MediaStream::RequestSample(IUnknown* token) {
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaEventQueue> queue;
    {
        std::lock_guard<std::mutex> guard(lock_);
        if (shutdown_ || !events_) {
            LogLine("RequestSample: shut down");
            return MF_E_SHUTDOWN;
        }
        if (state_ != MF_STREAM_STATE_RUNNING) {
            LogLine("RequestSample: state is %d, not running", static_cast<int>(state_));
            return MF_E_INVALIDREQUEST;
        }
        queue = events_;
    }

    const HRESULT produced = ProduceSample(token, &sample);
    if (FAILED(produced)) {
        LogLine("RequestSample: ProduceSample failed 0x%08X", static_cast<unsigned>(produced));
        return produced;
    }

    // Queued outside the lock: the queue calls back into whoever is waiting,
    // and that path must not re-enter this object holding its own lock.
    const HRESULT queued =
        queue->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample.Get());

    // Only the first few and then occasionally: at thirty frames a second this
    // would otherwise be the largest file on the disk.
    static std::atomic<UINT64> logged{0};
    const UINT64 count = logged.fetch_add(1);
    if (count < 5 || count % 500 == 0) {
        LogLine("RequestSample #%llu: token=%p queued=0x%08X", count,
                static_cast<void*>(token), static_cast<unsigned>(queued));
    }
    return queued;
}

HRESULT MediaStream::ProduceSample(IUnknown* token, IMFSample** sample) {
    UINT32 width;
    UINT32 height;
    UINT32 fps;
    UINT64 index;
    {
        std::lock_guard<std::mutex> guard(lock_);
        width = width_;
        height = height_;
        fps = fps_;
        index = frameIndex_++;
    }

    const UINT32 stride = LumaStride(width);
    const DWORD bytes = stride * height * 3 / 2;

    ComPtr<IMFMediaBuffer> buffer;
    RETURN_IF_FAILED(MFCreateMemoryBuffer(bytes, &buffer));

    BYTE* raw = nullptr;
    DWORD maxLength = 0;
    RETURN_IF_FAILED(buffer->Lock(&raw, &maxLength, nullptr));

    UINT64 ptsUs = 0;
    bool isLive = false;
    frames_.FillFrame(raw, stride, &ptsUs, &isLive);

    RETURN_IF_FAILED(buffer->Unlock());
    RETURN_IF_FAILED(buffer->SetCurrentLength(bytes));

    ComPtr<IMFSample> created;
    RETURN_IF_FAILED(MFCreateSample(&created));
    RETURN_IF_FAILED(created->AddBuffer(buffer.Get()));

    // Timestamps must be on the same timeline as the pipeline's presentation
    // clock, not a counter starting at zero. A live source that numbers its
    // frames from zero hands the pipeline samples that are hours old, and every
    // one of them is discarded as too late — which looks exactly like a camera
    // that produces nothing while cheerfully accepting every request.
    const LONGLONG duration = static_cast<LONGLONG>(kHundredNanosPerSecond / std::max(fps, 1u));
    const LONGLONG now = MFGetSystemTime();

    LONGLONG presentation;
    {
        std::lock_guard<std::mutex> guard(lock_);
        // Kept monotonic and evenly spaced: a conferencing app reads uneven
        // timestamps as stutter even when the frames themselves are fine.
        if (nextSampleTime_ == 0 || now > nextSampleTime_ + duration * 4) {
            nextSampleTime_ = now;
        }
        presentation = nextSampleTime_;
        nextSampleTime_ += duration;
    }

    RETURN_IF_FAILED(created->SetSampleTime(presentation));
    RETURN_IF_FAILED(created->SetSampleDuration(duration));
    RETURN_IF_FAILED(created->SetUINT32(MFSampleExtension_CleanPoint, TRUE));

    if (token) {
        RETURN_IF_FAILED(created->SetUnknown(MFSampleExtension_Token, token));
    }

    *sample = created.Detach();
    return S_OK;
}

// MARK: - IMFMediaStream2

IFACEMETHODIMP MediaStream::SetStreamState(MF_STREAM_STATE state) {
    std::lock_guard<std::mutex> guard(lock_);
    LogLine("MediaStream::SetStreamState(%d)", static_cast<int>(state));
    if (shutdown_) return MF_E_SHUTDOWN;
    if (state_ == state) return S_OK;

    switch (state) {
    case MF_STREAM_STATE_PAUSED:
        // Nothing is buffered, so pausing is only a state change: the next
        // request after resuming produces a fresh frame rather than a stale one.
        state_ = state;
        break;

    case MF_STREAM_STATE_RUNNING:
        frames_.Start();
        state_ = state;
        break;

    case MF_STREAM_STATE_STOPPED:
        frames_.Stop();
        state_ = state;
        frameIndex_ = 0;
        nextSampleTime_ = 0;
        break;

    default:
        return E_INVALIDARG;
    }
    return S_OK;
}

IFACEMETHODIMP MediaStream::GetStreamState(MF_STREAM_STATE* state) {
    if (!state) return E_POINTER;
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_) return MF_E_SHUTDOWN;
    *state = state_;
    return S_OK;
}

}  // namespace icam
