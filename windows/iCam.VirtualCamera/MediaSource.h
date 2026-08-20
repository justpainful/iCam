#pragma once

#include "MediaStream.h"

namespace icam {

// The media source the Windows Frame Server activates for `iCam Camera`.
//
// One video stream, no seeking, no duration — a live capture source. The Frame
// Server drives it: Start, then RequestSample on the stream, then Stop.
class MediaSource
    // ChainInterfaces, not a plain list: WRL only answers QueryInterface for
    // the interfaces named here, and IMFMediaSourceEx deriving from
    // IMFMediaSource is not enough on its own. Windows asks for the base
    // interface, and refusing it is why the camera never appeared.
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                          Microsoft::WRL::ChainInterfaces<IMFMediaSourceEx, IMFMediaSource,
                                                          IMFMediaEventGenerator>,
                          IMFGetService, IKsControlLite, FtmBase> {
public:
    MediaSource() = default;

    HRESULT Initialize();

    // Overridden purely to record what the Frame Server asks for. Every
    // refusal here is a reason the camera does not appear, and without this
    // the only symptom is an HRESULT with no context.
    IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override;

    // IMFMediaEventGenerator
    IFACEMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override;
    IFACEMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override;
    IFACEMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override;
    IFACEMETHODIMP QueueEvent(MediaEventType type, REFGUID extendedType,
                              HRESULT status, const PROPVARIANT* data) override;

    // IMFMediaSource
    IFACEMETHODIMP CreatePresentationDescriptor(
        IMFPresentationDescriptor** descriptor) override;
    IFACEMETHODIMP GetCharacteristics(DWORD* characteristics) override;
    IFACEMETHODIMP Pause() override;
    IFACEMETHODIMP Shutdown() override;
    IFACEMETHODIMP Start(IMFPresentationDescriptor* descriptor, const GUID* timeFormat,
                         const PROPVARIANT* startPosition) override;
    IFACEMETHODIMP Stop() override;

    // IMFMediaSourceEx
    IFACEMETHODIMP GetSourceAttributes(IMFAttributes** attributes) override;
    IFACEMETHODIMP GetStreamAttributes(DWORD streamId, IMFAttributes** attributes) override;
    IFACEMETHODIMP SetD3DManager(IUnknown* manager) override;

    // IMFGetService
    IFACEMETHODIMP GetService(REFGUID service, REFIID riid, LPVOID* object) override;

    // IKsControl — the camera pipeline asks every source for this, even one
    // with no controllable properties.
    IFACEMETHODIMP KsProperty(PKSPROPERTY property, ULONG propertyLength, PVOID data,
                              ULONG dataLength, ULONG* bytesReturned) override;
    IFACEMETHODIMP KsMethod(PKSMETHOD method, ULONG methodLength, PVOID data,
                            ULONG dataLength, ULONG* bytesReturned) override;
    IFACEMETHODIMP KsEvent(PKSEVENT event, ULONG eventLength, PVOID data,
                           ULONG dataLength, ULONG* bytesReturned) override;

private:
    HRESULT CheckShutdown() const {
        return shutdown_ ? MF_E_SHUTDOWN : S_OK;
    }

    mutable std::mutex lock_;
    ComPtr<IMFMediaEventQueue> events_;
    ComPtr<MediaStream> stream_;
    ComPtr<IMFAttributes> attributes_;
    ComPtr<IMFPresentationDescriptor> presentation_;

    bool shutdown_ = false;
    bool started_ = false;
};

}  // namespace icam
