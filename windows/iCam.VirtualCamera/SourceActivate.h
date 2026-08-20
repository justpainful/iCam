#pragma once

#include "MediaSource.h"

namespace icam {

// What the registered CLSID actually is.
//
// This was the one thing the documentation does not say plainly, and the only
// symptom of getting it wrong is `MFCreateVirtualCamera` succeeding and the
// camera never appearing. The Frame Server creates the CLSID and immediately
// asks for `IMFActivate` — not `IMFMediaSource`. The registered class is an
// *activator*; the media source is what its ActivateObject hands back.
//
// IMFActivate derives from IMFAttributes, so all thirty attribute methods have
// to exist. They are delegated to a real attribute store rather than stubbed:
// the Frame Server does read and write attributes here, and a stub would fail
// in a way that is even harder to see than this was.
class SourceActivate
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IMFActivate, FtmBase> {
public:
    SourceActivate() = default;

    HRESULT Initialize();

    IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override;

    // IMFActivate
    IFACEMETHODIMP ActivateObject(REFIID riid, void** object) override;
    IFACEMETHODIMP DetachObject() override;
    IFACEMETHODIMP ShutdownObject() override;

    // IMFAttributes — delegated to `store_`.
    IFACEMETHODIMP GetItem(REFGUID key, PROPVARIANT* value) override;
    IFACEMETHODIMP GetItemType(REFGUID key, MF_ATTRIBUTE_TYPE* type) override;
    IFACEMETHODIMP CompareItem(REFGUID key, REFPROPVARIANT value, BOOL* result) override;
    IFACEMETHODIMP Compare(IMFAttributes* other, MF_ATTRIBUTES_MATCH_TYPE type,
                           BOOL* result) override;
    IFACEMETHODIMP GetUINT32(REFGUID key, UINT32* value) override;
    IFACEMETHODIMP GetUINT64(REFGUID key, UINT64* value) override;
    IFACEMETHODIMP GetDouble(REFGUID key, double* value) override;
    IFACEMETHODIMP GetGUID(REFGUID key, GUID* value) override;
    IFACEMETHODIMP GetStringLength(REFGUID key, UINT32* length) override;
    IFACEMETHODIMP GetString(REFGUID key, LPWSTR value, UINT32 size,
                             UINT32* length) override;
    IFACEMETHODIMP GetAllocatedString(REFGUID key, LPWSTR* value, UINT32* length) override;
    IFACEMETHODIMP GetBlobSize(REFGUID key, UINT32* size) override;
    IFACEMETHODIMP GetBlob(REFGUID key, UINT8* buffer, UINT32 size, UINT32* written) override;
    IFACEMETHODIMP GetAllocatedBlob(REFGUID key, UINT8** buffer, UINT32* size) override;
    IFACEMETHODIMP GetUnknown(REFGUID key, REFIID riid, LPVOID* value) override;
    IFACEMETHODIMP SetItem(REFGUID key, REFPROPVARIANT value) override;
    IFACEMETHODIMP DeleteItem(REFGUID key) override;
    IFACEMETHODIMP DeleteAllItems() override;
    IFACEMETHODIMP SetUINT32(REFGUID key, UINT32 value) override;
    IFACEMETHODIMP SetUINT64(REFGUID key, UINT64 value) override;
    IFACEMETHODIMP SetDouble(REFGUID key, double value) override;
    IFACEMETHODIMP SetGUID(REFGUID key, REFGUID value) override;
    IFACEMETHODIMP SetString(REFGUID key, LPCWSTR value) override;
    IFACEMETHODIMP SetBlob(REFGUID key, const UINT8* buffer, UINT32 size) override;
    IFACEMETHODIMP SetUnknown(REFGUID key, IUnknown* value) override;
    IFACEMETHODIMP LockStore() override;
    IFACEMETHODIMP UnlockStore() override;
    IFACEMETHODIMP GetCount(UINT32* count) override;
    IFACEMETHODIMP GetItemByIndex(UINT32 index, GUID* key, PROPVARIANT* value) override;
    IFACEMETHODIMP CopyAllItems(IMFAttributes* destination) override;

private:
    std::mutex lock_;
    ComPtr<IMFAttributes> store_;
    ComPtr<MediaSource> source_;
};

}  // namespace icam
