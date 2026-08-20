#include "SourceActivate.h"

using namespace icam;

namespace {

std::atomic<long> g_objectCount{0};
HMODULE g_module = nullptr;

// The class factory the Frame Server uses to create the source.
class SourceFactory
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IClassFactory, FtmBase> {
public:
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;

        icam::LogLine("SourceFactory::CreateInstance");
        // The registered class is the activator, not the source. The Frame
        // Server asks this object for IMFActivate and calls ActivateObject to
        // get the media source.
        auto activate = Microsoft::WRL::Make<SourceActivate>();
        if (!activate) return E_OUTOFMEMORY;
        RETURN_IF_FAILED(activate->Initialize());
        return activate.CopyTo(riid, object);
    }

    IFACEMETHODIMP LockServer(BOOL lock) override {
        if (lock) {
            ++g_objectCount;
        } else {
            --g_objectCount;
        }
        return S_OK;
    }
};

HRESULT WriteRegistryString(HKEY root, const wchar_t* subKey, const wchar_t* name,
                            const wchar_t* value) {
    HKEY key = nullptr;
    LSTATUS status = RegCreateKeyExW(root, subKey, 0, nullptr, REG_OPTION_NON_VOLATILE,
                                     KEY_WRITE, nullptr, &key, nullptr);
    if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);

    const DWORD bytes = static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t));
    status = RegSetValueExW(key, name, 0, REG_SZ,
                            reinterpret_cast<const BYTE*>(value), bytes);
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(status);
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** object) {
    if (!object) return E_POINTER;
    *object = nullptr;
    icam::LogLine("DllGetClassObject");
    if (clsid != CLSID_ICamCameraSource) return CLASS_E_CLASSNOTAVAILABLE;

    auto factory = Microsoft::WRL::Make<SourceFactory>();
    if (!factory) return E_OUTOFMEMORY;
    return factory.CopyTo(riid, object);
}

STDAPI DllCanUnloadNow() {
    return g_objectCount.load() == 0 ? S_OK : S_FALSE;
}

// Registration is per-user, under HKCU. That is the whole reason enabling
// `iCam Camera` never asks for administrator rights: nothing is written to a
// machine-wide key, and removal leaves nothing behind.
STDAPI DllRegisterServer() {
    wchar_t path[MAX_PATH]{};
    if (GetModuleFileNameW(g_module, path, ARRAYSIZE(path)) == 0) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    const std::wstring clsidKey =
        L"Software\\Classes\\CLSID\\" ICAM_CLSID_STRING;
    const std::wstring serverKey = clsidKey + L"\\InprocServer32";

    RETURN_IF_FAILED(WriteRegistryString(HKEY_CURRENT_USER, clsidKey.c_str(), nullptr,
                                         ICAM_FRIENDLY_NAME));
    RETURN_IF_FAILED(WriteRegistryString(HKEY_CURRENT_USER, serverKey.c_str(), nullptr,
                                         path));
    // Both, so the Frame Server can create the object on whichever apartment
    // it happens to be using.
    RETURN_IF_FAILED(WriteRegistryString(HKEY_CURRENT_USER, serverKey.c_str(),
                                         L"ThreadingModel", L"Both"));
    return S_OK;
}

STDAPI DllUnregisterServer() {
    const std::wstring clsidKey =
        L"Software\\Classes\\CLSID\\" ICAM_CLSID_STRING;
    RegDeleteTreeW(HKEY_CURRENT_USER, clsidKey.c_str());
    return S_OK;
}
