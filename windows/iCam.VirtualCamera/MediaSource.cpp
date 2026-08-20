#include "MediaSource.h"

namespace icam {

IFACEMETHODIMP MediaSource::QueryInterface(REFIID riid, void** object) {
    const HRESULT result = RuntimeClass::QueryInterface(riid, object);
    LogInterface("MediaSource::QueryInterface", riid, result);
    return result;
}

HRESULT MediaSource::Initialize() {
    LogLine("MediaSource::Initialize");
    RETURN_IF_FAILED(MFCreateEventQueue(&events_));

    RETURN_IF_FAILED(MFCreateAttributes(&attributes_, 4));
    // Marks the source as a camera rather than a file or a network source.
    // Without it, applications enumerating webcams will not list iCam.
    RETURN_IF_FAILED(attributes_->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES,
                                            MFFrameSourceTypes_Color));
    RETURN_IF_FAILED(attributes_->SetUINT32(MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES,
                                            1));

    stream_ = Microsoft::WRL::Make<MediaStream>();
    if (!stream_) return E_OUTOFMEMORY;
    RETURN_IF_FAILED(stream_->Initialize(this, kDefaultFormatIndex));

    IMFStreamDescriptor* descriptors[] = {stream_->Descriptor()};
    RETURN_IF_FAILED(MFCreatePresentationDescriptor(1, descriptors, &presentation_));
    RETURN_IF_FAILED(presentation_->SelectStream(0));

    return S_OK;
}

// MARK: - IMFMediaEventGenerator

IFACEMETHODIMP MediaSource::BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) {
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());
    return events_->BeginGetEvent(callback, state);
}

IFACEMETHODIMP MediaSource::EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) {
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());
    return events_->EndGetEvent(result, event);
}

IFACEMETHODIMP MediaSource::GetEvent(DWORD flags, IMFMediaEvent** event) {
    ComPtr<IMFMediaEventQueue> queue;
    {
        std::lock_guard<std::mutex> guard(lock_);
        RETURN_IF_FAILED(CheckShutdown());
        queue = events_;
    }
    // Outside the lock: GetEvent blocks until an event arrives, and holding the
    // lock across it would deadlock whoever is trying to queue one.
    return queue->GetEvent(flags, event);
}

IFACEMETHODIMP MediaSource::QueueEvent(MediaEventType type, REFGUID extendedType,
                                       HRESULT status, const PROPVARIANT* data) {
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());
    return events_->QueueEventParamVar(type, extendedType, status, data);
}

// MARK: - IMFMediaSource

IFACEMETHODIMP MediaSource::CreatePresentationDescriptor(
    IMFPresentationDescriptor** descriptor) {
    if (!descriptor) return E_POINTER;
    LogLine("MediaSource::CreatePresentationDescriptor");
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());

    // A clone, not the original: the caller may select and deselect streams,
    // and those edits must not reach the source's own copy.
    return presentation_->Clone(descriptor);
}

IFACEMETHODIMP MediaSource::GetCharacteristics(DWORD* characteristics) {
    if (!characteristics) return E_POINTER;
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());

    // Live, not seekable, no duration. A webcam has no past to rewind to.
    *characteristics = MFMEDIASOURCE_IS_LIVE;
    LogLine("MediaSource::GetCharacteristics -> IS_LIVE");
    return S_OK;
}

IFACEMETHODIMP MediaSource::Start(IMFPresentationDescriptor* descriptor,
                                  const GUID* timeFormat,
                                  const PROPVARIANT* startPosition) {
    LogLine("MediaSource::Start");
    if (!descriptor) return E_INVALIDARG;
    if (timeFormat && *timeFormat != GUID_NULL) return MF_E_UNSUPPORTED_TIME_FORMAT;

    // A live source has nowhere to seek to, so the requested position is read
    // and deliberately ignored rather than silently dropped from the signature.
    UNREFERENCED_PARAMETER(startPosition);

    ComPtr<MediaStream> stream;
    ComPtr<IMFMediaEventQueue> queue;
    bool wasStarted;
    {
        std::lock_guard<std::mutex> guard(lock_);
        RETURN_IF_FAILED(CheckShutdown());
        stream = stream_;
        queue = events_;
        wasStarted = started_;
        started_ = true;
    }

    // Adopt whatever media type the caller selected, so the application is
    // asked for exactly the size the consumer negotiated.
    DWORD count = 0;
    RETURN_IF_FAILED(descriptor->GetStreamDescriptorCount(&count));
    for (DWORD i = 0; i < count; ++i) {
        BOOL selected = FALSE;
        ComPtr<IMFStreamDescriptor> streamDescriptor;
        RETURN_IF_FAILED(descriptor->GetStreamDescriptorByIndex(i, &selected,
                                                                &streamDescriptor));
        LogLine("  stream %lu selected=%d", i, selected ? 1 : 0);
        if (!selected) continue;

        ComPtr<IMFMediaTypeHandler> handler;
        RETURN_IF_FAILED(streamDescriptor->GetMediaTypeHandler(&handler));
        ComPtr<IMFMediaType> type;
        if (SUCCEEDED(handler->GetCurrentMediaType(&type))) {
            RETURN_IF_FAILED(stream->SetSelectedFormat(type.Get()));
        }

        PROPVARIANT start;
        PropVariantInit(&start);
        start.vt = VT_I8;
        start.hVal.QuadPart = 0;
        RETURN_IF_FAILED(stream->QueueEvent(MEStreamStarted, GUID_NULL, S_OK, &start));
        PropVariantClear(&start);

        RETURN_IF_FAILED(stream->SetStreamState(MF_STREAM_STATE_RUNNING));

        if (!wasStarted) {
            // The Frame Server expects to be handed the stream object once,
            // the first time the source starts.
            ComPtr<IUnknown> streamUnknown;
            RETURN_IF_FAILED(stream.As(&streamUnknown));
            RETURN_IF_FAILED(queue->QueueEventParamUnk(MENewStream, GUID_NULL, S_OK,
                                                       streamUnknown.Get()));
        }
    }

    PROPVARIANT start;
    PropVariantInit(&start);
    start.vt = VT_I8;
    start.hVal.QuadPart = 0;
    const HRESULT hr = queue->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &start);
    PropVariantClear(&start);
    return hr;
}

IFACEMETHODIMP MediaSource::Stop() {
    LogLine("MediaSource::Stop");
    ComPtr<MediaStream> stream;
    ComPtr<IMFMediaEventQueue> queue;
    {
        std::lock_guard<std::mutex> guard(lock_);
        RETURN_IF_FAILED(CheckShutdown());
        stream = stream_;
        queue = events_;
        started_ = false;
    }

    if (stream) {
        stream->SetStreamState(MF_STREAM_STATE_STOPPED);
        stream->QueueEvent(MEStreamStopped, GUID_NULL, S_OK, nullptr);
    }
    return queue->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, nullptr);
}

IFACEMETHODIMP MediaSource::Pause() {
    ComPtr<MediaStream> stream;
    ComPtr<IMFMediaEventQueue> queue;
    {
        std::lock_guard<std::mutex> guard(lock_);
        RETURN_IF_FAILED(CheckShutdown());
        stream = stream_;
        queue = events_;
    }

    if (stream) {
        stream->SetStreamState(MF_STREAM_STATE_PAUSED);
        stream->QueueEvent(MEStreamPaused, GUID_NULL, S_OK, nullptr);
    }
    return queue->QueueEventParamVar(MESourcePaused, GUID_NULL, S_OK, nullptr);
}

IFACEMETHODIMP MediaSource::Shutdown() {
    LogLine("MediaSource::Shutdown");
    std::lock_guard<std::mutex> guard(lock_);
    if (shutdown_) return S_OK;
    shutdown_ = true;

    if (stream_) {
        stream_->Shutdown();
        stream_.Reset();
    }
    if (events_) {
        events_->Shutdown();
        events_.Reset();
    }
    presentation_.Reset();
    attributes_.Reset();
    return S_OK;
}

// MARK: - IMFMediaSourceEx

IFACEMETHODIMP MediaSource::GetSourceAttributes(IMFAttributes** attributes) {
    if (!attributes) return E_POINTER;
    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());
    return attributes_.CopyTo(attributes);
}

IFACEMETHODIMP MediaSource::GetStreamAttributes(DWORD streamId, IMFAttributes** attributes) {
    LogLine("MediaSource::GetStreamAttributes(%lu)", streamId);
    if (!attributes) return E_POINTER;
    if (streamId != 0) return MF_E_INVALIDSTREAMNUMBER;

    std::lock_guard<std::mutex> guard(lock_);
    RETURN_IF_FAILED(CheckShutdown());
    if (!stream_ || !stream_->Descriptor()) return MF_E_SHUTDOWN;
    return stream_->Descriptor()->QueryInterface(IID_PPV_ARGS(attributes));
}

IFACEMETHODIMP MediaSource::SetD3DManager(IUnknown*) {
    // Frames are produced on the CPU and handed over as system memory. There is
    // nothing useful to do with a device manager, and claiming otherwise would
    // make the Frame Server expect textures this source cannot supply.
    return E_NOTIMPL;
}

// MARK: - IMFGetService

IFACEMETHODIMP MediaSource::GetService(REFGUID service, REFIID riid, LPVOID* object) {
    if (!object) return E_POINTER;
    *object = nullptr;
    LogInterface("MediaSource::GetService service", service, S_OK);
    // Serving any interface this object genuinely implements is correct here;
    // the service GUID is advisory for a source this simple.
    return QueryInterface(riid, object);
}

// MARK: - IKsControl

IFACEMETHODIMP MediaSource::KsProperty(PKSPROPERTY, ULONG, PVOID, ULONG,
                                       ULONG* bytesReturned) {
    // iCam Camera exposes no KS properties: brightness, pan and the rest belong
    // to the iPhone and are set there rather than emulated here. Saying so
    // plainly is what makes a consumer hide those controls instead of showing
    // sliders that do nothing.
    if (bytesReturned) *bytesReturned = 0;
    return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
}

IFACEMETHODIMP MediaSource::KsMethod(PKSMETHOD, ULONG, PVOID, ULONG,
                                     ULONG* bytesReturned) {
    if (bytesReturned) *bytesReturned = 0;
    return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
}

IFACEMETHODIMP MediaSource::KsEvent(PKSEVENT, ULONG, PVOID, ULONG,
                                    ULONG* bytesReturned) {
    if (bytesReturned) *bytesReturned = 0;
    return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
}

}  // namespace icam
