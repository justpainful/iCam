#include "SourceActivate.h"

namespace icam {

HRESULT SourceActivate::Initialize() {
    LogLine("SourceActivate::Initialize");
    return MFCreateAttributes(&store_, 4);
}

IFACEMETHODIMP SourceActivate::QueryInterface(REFIID riid, void** object) {
    const HRESULT result = RuntimeClass::QueryInterface(riid, object);
    LogInterface("SourceActivate::QueryInterface", riid, result);
    return result;
}

IFACEMETHODIMP SourceActivate::ActivateObject(REFIID riid, void** object) {
    if (!object) return E_POINTER;
    *object = nullptr;

    LogInterface("SourceActivate::ActivateObject", riid, S_OK);

    std::lock_guard<std::mutex> guard(lock_);
    if (!source_) {
        auto source = Microsoft::WRL::Make<MediaSource>();
        if (!source) return E_OUTOFMEMORY;
        RETURN_IF_FAILED(source->Initialize());
        source_ = source;
    }

    const HRESULT result = source_.CopyTo(riid, object);
    LogInterface("SourceActivate::ActivateObject result", riid, result);
    return result;
}

IFACEMETHODIMP SourceActivate::DetachObject() {
    std::lock_guard<std::mutex> guard(lock_);
    // Detach hands ownership back without tearing anything down; only
    // ShutdownObject ends the source.
    source_.Reset();
    return S_OK;
}

IFACEMETHODIMP SourceActivate::ShutdownObject() {
    std::lock_guard<std::mutex> guard(lock_);
    if (source_) {
        source_->Shutdown();
        source_.Reset();
    }
    return S_OK;
}

// MARK: - IMFAttributes, delegated

IFACEMETHODIMP SourceActivate::GetItem(REFGUID key, PROPVARIANT* value) {
    return store_->GetItem(key, value);
}
IFACEMETHODIMP SourceActivate::GetItemType(REFGUID key, MF_ATTRIBUTE_TYPE* type) {
    return store_->GetItemType(key, type);
}
IFACEMETHODIMP SourceActivate::CompareItem(REFGUID key, REFPROPVARIANT value, BOOL* result) {
    return store_->CompareItem(key, value, result);
}
IFACEMETHODIMP SourceActivate::Compare(IMFAttributes* other, MF_ATTRIBUTES_MATCH_TYPE type,
                                       BOOL* result) {
    return store_->Compare(other, type, result);
}
IFACEMETHODIMP SourceActivate::GetUINT32(REFGUID key, UINT32* value) {
    return store_->GetUINT32(key, value);
}
IFACEMETHODIMP SourceActivate::GetUINT64(REFGUID key, UINT64* value) {
    return store_->GetUINT64(key, value);
}
IFACEMETHODIMP SourceActivate::GetDouble(REFGUID key, double* value) {
    return store_->GetDouble(key, value);
}
IFACEMETHODIMP SourceActivate::GetGUID(REFGUID key, GUID* value) {
    return store_->GetGUID(key, value);
}
IFACEMETHODIMP SourceActivate::GetStringLength(REFGUID key, UINT32* length) {
    return store_->GetStringLength(key, length);
}
IFACEMETHODIMP SourceActivate::GetString(REFGUID key, LPWSTR value, UINT32 size,
                                         UINT32* length) {
    return store_->GetString(key, value, size, length);
}
IFACEMETHODIMP SourceActivate::GetAllocatedString(REFGUID key, LPWSTR* value, UINT32* length) {
    return store_->GetAllocatedString(key, value, length);
}
IFACEMETHODIMP SourceActivate::GetBlobSize(REFGUID key, UINT32* size) {
    return store_->GetBlobSize(key, size);
}
IFACEMETHODIMP SourceActivate::GetBlob(REFGUID key, UINT8* buffer, UINT32 size,
                                       UINT32* written) {
    return store_->GetBlob(key, buffer, size, written);
}
IFACEMETHODIMP SourceActivate::GetAllocatedBlob(REFGUID key, UINT8** buffer, UINT32* size) {
    return store_->GetAllocatedBlob(key, buffer, size);
}
IFACEMETHODIMP SourceActivate::GetUnknown(REFGUID key, REFIID riid, LPVOID* value) {
    return store_->GetUnknown(key, riid, value);
}
IFACEMETHODIMP SourceActivate::SetItem(REFGUID key, REFPROPVARIANT value) {
    return store_->SetItem(key, value);
}
IFACEMETHODIMP SourceActivate::DeleteItem(REFGUID key) {
    return store_->DeleteItem(key);
}
IFACEMETHODIMP SourceActivate::DeleteAllItems() {
    return store_->DeleteAllItems();
}
IFACEMETHODIMP SourceActivate::SetUINT32(REFGUID key, UINT32 value) {
    return store_->SetUINT32(key, value);
}
IFACEMETHODIMP SourceActivate::SetUINT64(REFGUID key, UINT64 value) {
    return store_->SetUINT64(key, value);
}
IFACEMETHODIMP SourceActivate::SetDouble(REFGUID key, double value) {
    return store_->SetDouble(key, value);
}
IFACEMETHODIMP SourceActivate::SetGUID(REFGUID key, REFGUID value) {
    return store_->SetGUID(key, value);
}
IFACEMETHODIMP SourceActivate::SetString(REFGUID key, LPCWSTR value) {
    return store_->SetString(key, value);
}
IFACEMETHODIMP SourceActivate::SetBlob(REFGUID key, const UINT8* buffer, UINT32 size) {
    return store_->SetBlob(key, buffer, size);
}
IFACEMETHODIMP SourceActivate::SetUnknown(REFGUID key, IUnknown* value) {
    return store_->SetUnknown(key, value);
}
IFACEMETHODIMP SourceActivate::LockStore() {
    return store_->LockStore();
}
IFACEMETHODIMP SourceActivate::UnlockStore() {
    return store_->UnlockStore();
}
IFACEMETHODIMP SourceActivate::GetCount(UINT32* count) {
    return store_->GetCount(count);
}
IFACEMETHODIMP SourceActivate::GetItemByIndex(UINT32 index, GUID* key, PROPVARIANT* value) {
    return store_->GetItemByIndex(index, key, value);
}
IFACEMETHODIMP SourceActivate::CopyAllItems(IMFAttributes* destination) {
    return store_->CopyAllItems(destination);
}

}  // namespace icam
