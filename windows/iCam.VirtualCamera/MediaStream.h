#pragma once

#include "FrameSource.h"

namespace icam {

class MediaSource;

// The one video stream `iCam Camera` exposes.
//
// Samples are produced on demand inside RequestSample. That is the shape the
// Frame Server expects, and it keeps the whole path synchronous and easy to
// reason about: a request in, a memcpy, a sample out.
class MediaStream
    // Chained for the same reason as MediaSource: the pipeline asks for
    // IMFMediaStream and for IMFMediaEventGenerator, not only for the most
    // derived interface.
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                          Microsoft::WRL::ChainInterfaces<IMFMediaStream2, IMFMediaStream,
                                                          IMFMediaEventGenerator>,
                          FtmBase> {
public:
    MediaStream() = default;

    HRESULT Initialize(MediaSource* source, UINT32 formatIndex);
    HRESULT Shutdown();

    IMFStreamDescriptor* Descriptor() const { return descriptor_.Get(); }
    FrameSource& Frames() { return frames_; }

    HRESULT SetSelectedFormat(IMFMediaType* type);

    // IMFMediaEventGenerator
    IFACEMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override;
    IFACEMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override;
    IFACEMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override;
    IFACEMETHODIMP QueueEvent(MediaEventType type, REFGUID extendedType,
                              HRESULT status, const PROPVARIANT* data) override;

    // IMFMediaStream
    IFACEMETHODIMP GetMediaSource(IMFMediaSource** source) override;
    IFACEMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** descriptor) override;
    IFACEMETHODIMP RequestSample(IUnknown* token) override;

    // IMFMediaStream2
    IFACEMETHODIMP SetStreamState(MF_STREAM_STATE state) override;
    IFACEMETHODIMP GetStreamState(MF_STREAM_STATE* state) override;

private:
    HRESULT CreateMediaType(UINT32 formatIndex, IMFMediaType** type);
    HRESULT ProduceSample(IUnknown* token, IMFSample** sample);

    std::mutex lock_;
    ComPtr<IMFMediaEventQueue> events_;
    ComPtr<IMFStreamDescriptor> descriptor_;
    MediaSource* source_ = nullptr;   // weak: the source owns this stream

    FrameSource frames_;

    MF_STREAM_STATE state_ = MF_STREAM_STATE_STOPPED;
    bool shutdown_ = false;

    UINT32 width_ = kFormats[kDefaultFormatIndex].width;
    UINT32 height_ = kFormats[kDefaultFormatIndex].height;
    UINT32 fps_ = kFormats[kDefaultFormatIndex].fps;

    UINT64 frameIndex_ = 0;
    // Next presentation time, on the pipeline's clock, in 100ns units.
    LONGLONG nextSampleTime_ = 0;
};

}  // namespace icam
