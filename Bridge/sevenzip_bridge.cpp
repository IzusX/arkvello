// sevenzip_bridge.cpp
// In-process C ABI bridge over 7-Zip 26.06 C++ interfaces (LGPL-2.1+).
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (c) 2026 IzusX
// This bridge is free software under GNU LGPL version 2.1 or later.
// It is provided without warranty; see Vendor/7zip/DOC/copying.txt.

#include "Common/Common.h"
#include "Common/MyWindows.h"
#include "Common/MyInitGuid.h"

#include "../Sources/CSevenZip/include/sevenzip_bridge.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "Common/IntToString.h"
#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Common/UTFConvert.h"
#include "Common/Wildcard.h"

#include "Windows/ErrorMsg.h"
#include "Windows/FileDir.h"
#include "Windows/FileFind.h"
#include "Windows/FileName.h"
#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"
#include "Windows/TimeUtils.h"

#include "7zip/Archive/IArchive.h"
#include "7zip/Common/FileStreams.h"
#include "7zip/Common/StreamObjects.h"
#include "7zip/IPassword.h"

#include "7zip/UI/Common/ArchiveExtractCallback.h"
#include "7zip/UI/Common/ArchiveOpenCallback.h"
#include "7zip/UI/Common/EnumDirItems.h"
#include "7zip/UI/Common/Extract.h"
#include "7zip/UI/Common/HashCalc.h"
#include "7zip/UI/Common/LoadCodecs.h"
#include "7zip/UI/Common/OpenArchive.h"
#include "7zip/UI/Common/PropIDUtils.h"
#include "7zip/UI/Common/SetProperties.h"
#include "7zip/UI/Common/Update.h"
#include "7zip/UI/Common/UpdateAction.h"
#include "7zip/UI/Common/UpdateCallback.h"

#include "C/7zVersion.h"

using namespace NWindows;
using namespace NCOM;

namespace {

static void SecureZeroString(char *p, size_t n) {
    if (!p || n == 0) return;
    volatile char *vp = p;
    while (n--) *vp++ = 0;
}

static void SecureZeroUString(UString &s) {
    if (s.IsEmpty()) return;
    wchar_t *p = s.Ptr_non_const();
    size_t len = s.Len();
    volatile wchar_t *vp = p;
    while (len--) *vp++ = 0;
    s.Empty();
}

static UString Utf8ToUString(const char *utf8) {
    UString out;
    if (!utf8 || !*utf8) return out;
    AString src(utf8);
    ConvertUTF8ToUnicode_Flags(
        src,
        out,
        Z7_UTF_FLAG_FROM_UTF8_SURROGATE_ERROR | Z7_UTF_FLAG_FROM_UTF8_USE_ESCAPE
    );
    return out;
}

static std::string UStringToStdUtf8(const UString &u) {
    if (u.IsEmpty()) return std::string();
    AString utf8;
    ConvertUnicodeToUTF8_Flags(u, utf8, Z7_UTF_FLAG_TO_UTF8_SURROGATE_ERROR);
    return std::string(utf8.Ptr(), utf8.Len());
}

static char *DupString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return out;
}

static char *UStringToHeapUtf8(const UString &u) {
    return DupString(UStringToStdUtf8(u));
}

static void SetError(char **out_error, const std::string &msg) {
    if (!out_error) return;
    *out_error = DupString(msg);
}

static CCodecs *GetGlobalCodecs(HRESULT *outRes = nullptr) {
    static std::once_flag flag;
    static CCodecs *s_codecs = nullptr;
    static CMyComPtr<IUnknown> s_codecsRef;
    static HRESULT s_loadRes = S_OK;

    std::call_once(flag, []() {
        g_Unicode_To_UTF8_Flags = Z7_UTF_FLAG_TO_UTF8_SURROGATE_ERROR;
        s_codecs = new CCodecs();
        s_codecsRef = s_codecs;
        s_loadRes = s_codecs->Load();
    });

    if (outRes) *outRes = s_loadRes;
    return s_codecs;
}

class CBridgeOpenCallback Z7_final : public IOpenCallbackUI {
public:
    UString Password;
    bool PasswordIsDefined;
    bool PasswordWasRequested;
    bool PasswordWasMissing;
    bool Cancelled;
    sz_password_cb PasswordCb;
    sz_progress_cb ProgressCb;
    void *UserData;

    CBridgeOpenCallback(
        const char *password,
        sz_password_cb passwordCb,
        sz_progress_cb progressCb,
        void *userData
    )
        : PasswordIsDefined(password != nullptr && password[0] != '\0'),
          PasswordWasRequested(false),
          PasswordWasMissing(false),
          Cancelled(false),
          PasswordCb(passwordCb),
          ProgressCb(progressCb),
          UserData(userData) {
        if (PasswordIsDefined) {
            Password = Utf8ToUString(password);
        }
    }

    ~CBridgeOpenCallback() {
        SecureZeroUString(Password);
    }

    HRESULT Open_CheckBreak() Z7_override {
        if (ProgressCb && !ProgressCb(0, 0, nullptr, UserData)) {
            Cancelled = true;
            return E_ABORT;
        }
        return S_OK;
    }

    HRESULT Open_SetTotal(const UInt64 * /*files*/, const UInt64 * /*bytes*/) Z7_override {
        return Open_CheckBreak();
    }

    HRESULT Open_SetCompleted(const UInt64 * /*files*/, const UInt64 *bytes) Z7_override {
        if (ProgressCb) {
            const uint64_t done = bytes ? static_cast<uint64_t>(*bytes) : 0;
            if (!ProgressCb(done, 0, nullptr, UserData)) {
                Cancelled = true;
                return E_ABORT;
            }
        }
        return S_OK;
    }

    HRESULT Open_Finished() Z7_override {
        return S_OK;
    }

#ifndef Z7_NO_CRYPTO
    HRESULT Open_CryptoGetTextPassword(BSTR *password) Z7_override {
        PasswordWasRequested = true;
        if (!PasswordIsDefined && PasswordCb) {
            char *dynamicPwd = PasswordCb(UserData);
            if (dynamicPwd) {
                Password = Utf8ToUString(dynamicPwd);
                PasswordIsDefined = true;
                SecureZeroString(dynamicPwd, std::strlen(dynamicPwd));
                std::free(dynamicPwd);
            }
        }
        if (!PasswordIsDefined) {
            PasswordWasMissing = true;
            return E_ABORT;
        }
        return StringToBstr(Password, password);
    }
#endif
};

class CBridgeExtractCallback Z7_final :
    public IFolderArchiveExtractCallback,
    public IFolderArchiveExtractCallback2,
#ifndef Z7_NO_CRYPTO
    public ICryptoGetTextPassword,
#endif
    public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
    Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
#ifndef Z7_NO_CRYPTO
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
#endif
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE

public:
    UString Password;
    bool PasswordIsDefined;
    bool PasswordWasRequested;
    bool PasswordWasMissing;
    bool HadWrongPassword;
    bool HadCorruptData;
    bool HadUnsupportedMethod;
    bool Cancelled;
    sz_overwrite_mode_t OverwriteMode;
    sz_overwrite_cb OverwriteCb;
    sz_password_cb PasswordCb;
    sz_progress_cb ProgressCb;
    void *UserData;
    uint64_t TotalBytes;
    std::string CurrentItem;
    std::string ErrorLog;

    CBridgeExtractCallback(
        const char *password,
        sz_overwrite_mode_t overwriteMode,
        sz_overwrite_cb overwriteCb,
        sz_password_cb passwordCb,
        sz_progress_cb progressCb,
        void *userData
    )
        : PasswordIsDefined(password != nullptr && password[0] != '\0'),
          PasswordWasRequested(false),
          PasswordWasMissing(false),
          HadWrongPassword(false),
          HadCorruptData(false),
          HadUnsupportedMethod(false),
          Cancelled(false),
          OverwriteMode(overwriteMode),
          OverwriteCb(overwriteCb),
          PasswordCb(passwordCb),
          ProgressCb(progressCb),
          UserData(userData),
          TotalBytes(0) {
        if (PasswordIsDefined) {
            Password = Utf8ToUString(password);
        }
    }

    ~CBridgeExtractCallback() {
        SecureZeroUString(Password);
    }

    // IProgress
    STDMETHOD(SetTotal)(UInt64 total) throw() Z7_override {
        TotalBytes = static_cast<uint64_t>(total);
        if (ProgressCb && !ProgressCb(0, TotalBytes, CurrentItem.empty() ? nullptr : CurrentItem.c_str(), UserData)) {
            Cancelled = true;
            return E_ABORT;
        }
        return S_OK;
    }

    STDMETHOD(SetCompleted)(const UInt64 *completeValue) throw() Z7_override {
        if (ProgressCb) {
            const uint64_t done = completeValue ? static_cast<uint64_t>(*completeValue) : 0;
            if (!ProgressCb(done, TotalBytes, CurrentItem.empty() ? nullptr : CurrentItem.c_str(), UserData)) {
                Cancelled = true;
                return E_ABORT;
            }
        }
        return S_OK;
    }

    // IFolderArchiveExtractCallback
    STDMETHOD(AskOverwrite)(
        const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
        const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
        Int32 *answer
    ) throw() Z7_override {
        if (OverwriteMode == SZ_OVERWRITE_ASK && OverwriteCb != nullptr) {
            try {
                const std::string existUtf8 = existName ? UStringToStdUtf8(UString(existName)) : std::string();
                const std::string newUtf8 = newName ? UStringToStdUtf8(UString(newName)) : std::string();

                sz_overwrite_prompt_t prompt;
                std::memset(&prompt, 0, sizeof(prompt));
                prompt.existing_path = existUtf8.c_str();
                if (existSize) {
                    prompt.existing_size = static_cast<uint64_t>(*existSize);
                    prompt.has_existing_size = true;
                }
                if (existTime && !FILETIME_IsZero(*existTime)) {
                    CFiTime ts;
                    if (FILETIME_To_timespec(*existTime, ts)) {
                        prompt.existing_mtime_sec = static_cast<int64_t>(ts.tv_sec);
                        prompt.has_existing_mtime = true;
                    }
                }
                prompt.new_path = newUtf8.c_str();
                if (newSize) {
                    prompt.new_size = static_cast<uint64_t>(*newSize);
                    prompt.has_new_size = true;
                }
                if (newTime && !FILETIME_IsZero(*newTime)) {
                    CFiTime ts;
                    if (FILETIME_To_timespec(*newTime, ts)) {
                        prompt.new_mtime_sec = static_cast<int64_t>(ts.tv_sec);
                        prompt.has_new_mtime = true;
                    }
                }

                const sz_overwrite_answer_t userAns = OverwriteCb(&prompt, UserData);
                switch (userAns) {
                    case SZ_OW_ANSWER_YES:
                        *answer = NOverwriteAnswer::kYes;
                        break;
                    case SZ_OW_ANSWER_YES_TO_ALL:
                        *answer = NOverwriteAnswer::kYesToAll;
                        break;
                    case SZ_OW_ANSWER_NO:
                        *answer = NOverwriteAnswer::kNo;
                        break;
                    case SZ_OW_ANSWER_NO_TO_ALL:
                        *answer = NOverwriteAnswer::kNoToAll;
                        break;
                    case SZ_OW_ANSWER_AUTO_RENAME:
                        *answer = NOverwriteAnswer::kAutoRename;
                        break;
                    case SZ_OW_ANSWER_CANCEL:
                        *answer = NOverwriteAnswer::kCancel;
                        Cancelled = true;
                        return E_ABORT;
                }
                return S_OK;
            } catch (...) {
                *answer = NOverwriteAnswer::kCancel;
                Cancelled = true;
                return E_ABORT;
            }
        }

        switch (OverwriteMode) {
            case SZ_OVERWRITE_ALL:
            case SZ_OVERWRITE_ASK:
                *answer = NOverwriteAnswer::kYesToAll;
                break;
            case SZ_OVERWRITE_SKIP:
                *answer = NOverwriteAnswer::kNoToAll;
                break;
            case SZ_OVERWRITE_AUTO_RENAME:
            case SZ_OVERWRITE_AUTO_RENAME_EXISTING:
                *answer = NOverwriteAnswer::kAutoRename;
                break;
        }
        return S_OK;
    }

    STDMETHOD(PrepareOperation)(
        const wchar_t *name,
        Int32 /*isFolder*/,
        Int32 /*askExtractMode*/,
        const UInt64 * /*position*/
    ) throw() Z7_override {
        try {
            CurrentItem = name ? UStringToStdUtf8(UString(name)) : std::string();
        } catch (...) {
            CurrentItem.clear();
        }
        if (ProgressCb && !ProgressCb(0, TotalBytes, CurrentItem.empty() ? nullptr : CurrentItem.c_str(), UserData)) {
            Cancelled = true;
            return E_ABORT;
        }
        return S_OK;
    }

    STDMETHOD(MessageError)(const wchar_t *message) throw() Z7_override {
        try {
            if (message) {
                if (!ErrorLog.empty()) ErrorLog += "\n";
                ErrorLog += UStringToStdUtf8(UString(message));
            }
        } catch (...) {}
        return S_OK;
    }

    void RecordOpRes(Int32 opRes, Int32 encrypted) throw() {
        using namespace NArchive::NExtract::NOperationResult;
        if (opRes == kOK) return;
        if (opRes == kWrongPassword) {
            HadWrongPassword = true;
        } else if (opRes == kUnsupportedMethod) {
            HadUnsupportedMethod = true;
        } else if (opRes == kDataError || opRes == kCRCError || opRes == kHeadersError) {
            if (encrypted != 0) {
                if (!PasswordIsDefined) PasswordWasMissing = true;
                else HadWrongPassword = true;
            } else {
                HadCorruptData = true;
            }
        } else {
            HadCorruptData = true;
        }
    }

    STDMETHOD(SetOperationResult)(Int32 opRes, Int32 encrypted) throw() Z7_override {
        RecordOpRes(opRes, encrypted);
        return S_OK;
    }

    // IFolderArchiveExtractCallback2
    STDMETHOD(ReportExtractResult)(Int32 opRes, Int32 encrypted, const wchar_t *name) throw() Z7_override {
        RecordOpRes(opRes, encrypted);
        try {
            if (opRes != NArchive::NExtract::NOperationResult::kOK && name) {
                if (!ErrorLog.empty()) ErrorLog += "\n";
                ErrorLog += UStringToStdUtf8(UString(name));
            }
        } catch (...) {}
        return S_OK;
    }

#ifndef Z7_NO_CRYPTO
    STDMETHOD(CryptoGetTextPassword)(BSTR *password) throw() Z7_override {
        PasswordWasRequested = true;
        try {
            if (!PasswordIsDefined && PasswordCb) {
                char *dynamicPwd = PasswordCb(UserData);
                if (dynamicPwd) {
                    Password = Utf8ToUString(dynamicPwd);
                    PasswordIsDefined = true;
                    SecureZeroString(dynamicPwd, std::strlen(dynamicPwd));
                    std::free(dynamicPwd);
                }
            }
            if (!PasswordIsDefined) {
                PasswordWasMissing = true;
                return E_ABORT;
            }
            return StringToBstr(Password, password);
        } catch (...) {
            return E_OUTOFMEMORY;
        }
    }
#endif
};

class CMemBoundedOutStream Z7_final :
    public ISequentialOutStream,
    public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_1(ISequentialOutStream)
public:
    std::vector<uint8_t> Buffer;
    uint64_t MaxBytes;
    bool ExceededLimit;

    explicit CMemBoundedOutStream(uint64_t maxBytes)
        : MaxBytes(maxBytes), ExceededLimit(false) {}

    STDMETHOD(Write)(const void *data, UInt32 size, UInt32 *processedSize) throw() Z7_override {
        if (processedSize) *processedSize = 0;
        if (size == 0) return S_OK;
        if (MaxBytes > 0 && Buffer.size() + size > MaxBytes) {
            ExceededLimit = true;
            return E_ABORT;
        }
        try {
            const uint8_t *bytes = static_cast<const uint8_t *>(data);
            Buffer.insert(Buffer.end(), bytes, bytes + size);
        } catch (...) {
            return E_OUTOFMEMORY;
        }
        if (processedSize) *processedSize = size;
        return S_OK;
    }
};

class CHashStreamingOutStream Z7_final :
    public ISequentialOutStream,
    public CMyUnknownImp {
    Z7_COM_UNKNOWN_IMP_1(ISequentialOutStream)
public:
    CHashBundle *Bundle;
    uint64_t TotalSize;
    uint64_t Processed;
    sz_progress_cb ProgressCb;
    void *UserData;
    bool Cancelled;

    CHashStreamingOutStream(
        CHashBundle *bundle,
        uint64_t totalSize,
        sz_progress_cb progressCb,
        void *userData
    )
        : Bundle(bundle),
          TotalSize(totalSize),
          Processed(0),
          ProgressCb(progressCb),
          UserData(userData),
          Cancelled(false) {}

    STDMETHOD(Write)(const void *data, UInt32 size, UInt32 *processedSize) throw() Z7_override {
        if (processedSize) *processedSize = 0;
        if (size == 0) return S_OK;
        Bundle->Update(data, size);
        Processed += size;
        if (ProgressCb && !ProgressCb(Processed, TotalSize, nullptr, UserData)) {
            Cancelled = true;
            return E_ABORT;
        }
        if (processedSize) *processedSize = size;
        return S_OK;
    }
};

class CSingleStreamExtractCallback Z7_final :
    public IArchiveExtractCallback,
#ifndef Z7_NO_CRYPTO
    public ICryptoGetTextPassword,
#endif
    public CMyUnknownImp {
    Z7_COM_QI_BEGIN2(IArchiveExtractCallback)
#ifndef Z7_NO_CRYPTO
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
#endif
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE

public:
    UInt32 TargetIndex;
    bool IsEncryptedItem;
    CMyComPtr<ISequentialOutStream> TargetStreamRef;
    UString Password;
    bool PasswordIsDefined;
    bool PasswordWasMissing;
    bool HadWrongPassword;
    bool HadCorruptData;
    sz_password_cb PasswordCb;
    void *UserData;
    bool ActiveTarget;

    CSingleStreamExtractCallback(
        UInt32 targetIndex,
        bool isEncryptedItem,
        ISequentialOutStream *outStream,
        const char *password,
        sz_password_cb passwordCb,
        void *userData
    )
        : TargetIndex(targetIndex),
          IsEncryptedItem(isEncryptedItem),
          TargetStreamRef(outStream),
          PasswordIsDefined(password != nullptr && password[0] != '\0'),
          PasswordWasMissing(false),
          HadWrongPassword(false),
          HadCorruptData(false),
          PasswordCb(passwordCb),
          UserData(userData),
          ActiveTarget(false) {
        if (PasswordIsDefined) {
            Password = Utf8ToUString(password);
        }
    }

    ~CSingleStreamExtractCallback() {
        SecureZeroUString(Password);
    }

    STDMETHOD(SetTotal)(UInt64 /*total*/) throw() Z7_override { return S_OK; }
    STDMETHOD(SetCompleted)(const UInt64 * /*completeValue*/) throw() Z7_override { return S_OK; }

    STDMETHOD(GetStream)(UInt32 index, ISequentialOutStream **outStream, Int32 askExtractMode) throw() Z7_override {
        *outStream = nullptr;
        ActiveTarget = false;
        if (index != TargetIndex || askExtractMode != NArchive::NExtract::NAskMode::kExtract) {
            return S_OK;
        }
        ActiveTarget = true;
        CMyComPtr<ISequentialOutStream> ref = TargetStreamRef;
        *outStream = ref.Detach();
        return S_OK;
    }

    STDMETHOD(PrepareOperation)(Int32 /*askExtractMode*/) throw() Z7_override {
        return S_OK;
    }

    STDMETHOD(SetOperationResult)(Int32 opRes) throw() Z7_override {
        using namespace NArchive::NExtract::NOperationResult;
        if (!ActiveTarget && opRes == kOK) return S_OK;
        if (opRes == kOK) return S_OK;
        if (opRes == kWrongPassword) {
            HadWrongPassword = true;
        } else if (opRes == kDataError || opRes == kCRCError) {
            if (IsEncryptedItem) {
                if (!PasswordIsDefined) PasswordWasMissing = true;
                else HadWrongPassword = true;
            } else {
                HadCorruptData = true;
            }
        } else {
            HadCorruptData = true;
        }
        return S_OK;
    }

#ifndef Z7_NO_CRYPTO
    STDMETHOD(CryptoGetTextPassword)(BSTR *password) throw() Z7_override {
        try {
            if (!PasswordIsDefined && PasswordCb) {
                char *dynamicPwd = PasswordCb(UserData);
                if (dynamicPwd) {
                    Password = Utf8ToUString(dynamicPwd);
                    PasswordIsDefined = true;
                    SecureZeroString(dynamicPwd, std::strlen(dynamicPwd));
                    std::free(dynamicPwd);
                }
            }
            if (!PasswordIsDefined) {
                PasswordWasMissing = true;
                return E_ABORT;
            }
            return StringToBstr(Password, password);
        } catch (...) {
            return E_OUTOFMEMORY;
        }
    }
#endif
};

class CBridgeUpdateCallback Z7_final : public IUpdateCallbackUI2 {
public:
    UString Password;
    bool PasswordIsDefined;
    bool Cancelled;
    bool OpenFailed;
    bool PasswordWasMissing;
    bool HadWrongPassword;
    sz_progress_cb ProgressCb;
    void *UserData;
    uint64_t TotalBytes;
    std::string CurrentItem;
    std::string ErrorLog;

    CBridgeUpdateCallback(const char *password, sz_progress_cb progressCb, void *userData)
        : PasswordIsDefined(password != nullptr && password[0] != '\0'),
          Cancelled(false),
          OpenFailed(false),
          PasswordWasMissing(false),
          HadWrongPassword(false),
          ProgressCb(progressCb),
          UserData(userData),
          TotalBytes(0) {
        if (PasswordIsDefined) {
            Password = Utf8ToUString(password);
        }
    }

    ~CBridgeUpdateCallback() {
        SecureZeroUString(Password);
    }

    HRESULT CheckBreak() Z7_override {
        if (ProgressCb && !ProgressCb(0, TotalBytes, CurrentItem.empty() ? nullptr : CurrentItem.c_str(), UserData)) {
            Cancelled = true;
            return E_ABORT;
        }
        return S_OK;
    }

    // IDirItemsCallback
    HRESULT ScanError(const FString &path, DWORD /*systemError*/) Z7_override {
        if (!ErrorLog.empty()) ErrorLog += "\n";
        ErrorLog += "Scan error: " + UStringToStdUtf8(fs2us(path));
        return S_OK;
    }

    HRESULT ScanProgress(const CDirItemsStat & /*st*/, const FString &path, bool /*isDir*/) Z7_override {
        CurrentItem = UStringToStdUtf8(fs2us(path));
        return CheckBreak();
    }

    // IUpdateCallbackUI
    HRESULT WriteSfx(const wchar_t * /*name*/, UInt64 /*size*/) Z7_override { return S_OK; }

    HRESULT SetTotal(UInt64 size) Z7_override {
        TotalBytes = static_cast<uint64_t>(size);
        if (ProgressCb && !ProgressCb(0, TotalBytes, CurrentItem.empty() ? nullptr : CurrentItem.c_str(), UserData)) {
            Cancelled = true;
            return E_ABORT;
        }
        return S_OK;
    }

    HRESULT SetCompleted(const UInt64 *completeValue) Z7_override {
        if (ProgressCb) {
            const uint64_t done = completeValue ? static_cast<uint64_t>(*completeValue) : 0;
            if (!ProgressCb(done, TotalBytes, CurrentItem.empty() ? nullptr : CurrentItem.c_str(), UserData)) {
                Cancelled = true;
                return E_ABORT;
            }
        }
        return S_OK;
    }

    HRESULT SetRatioInfo(const UInt64 * /*inSize*/, const UInt64 * /*outSize*/) Z7_override { return S_OK; }
    HRESULT SetNumItems(const CArcToDoStat & /*stat*/) Z7_override { return S_OK; }

    HRESULT GetStream(const wchar_t *name, bool /*isDir*/, bool /*isAnti*/, UInt32 /*mode*/) Z7_override {
        CurrentItem = name ? UStringToStdUtf8(UString(name)) : std::string();
        return CheckBreak();
    }

    HRESULT OpenFileError(const FString &path, DWORD /*systemError*/) Z7_override {
        if (!ErrorLog.empty()) ErrorLog += "\n";
        ErrorLog += "Cannot open file: " + UStringToStdUtf8(fs2us(path));
        return S_FALSE;
    }

    HRESULT ReadingFileError(const FString &path, DWORD /*systemError*/) Z7_override {
        if (!ErrorLog.empty()) ErrorLog += "\n";
        ErrorLog += "Read error: " + UStringToStdUtf8(fs2us(path));
        return E_FAIL;
    }

    HRESULT SetOperationResult(Int32 /*opRes*/) Z7_override { return S_OK; }

    HRESULT ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t *name) Z7_override {
        if (opRes == NArchive::NExtract::NOperationResult::kWrongPassword ||
            (isEncrypted && (opRes == NArchive::NExtract::NOperationResult::kCRCError ||
                             opRes == NArchive::NExtract::NOperationResult::kDataError))) {
            if (PasswordIsDefined) HadWrongPassword = true;
            else PasswordWasMissing = true;
        }
        if (opRes != NArchive::NExtract::NOperationResult::kOK && name) {
            if (!ErrorLog.empty()) ErrorLog += "\n";
            ErrorLog += "Extract error during update: " + UStringToStdUtf8(UString(name));
        }
        return S_OK;
    }

    HRESULT ReportUpdateOperation(UInt32 /*op*/, const wchar_t * /*name*/, bool /*isDir*/) Z7_override {
        return S_OK;
    }

    HRESULT CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password) Z7_override {
        *password = nullptr;
        *passwordIsDefined = BoolToInt(PasswordIsDefined);
        if (!PasswordIsDefined) return S_OK;
        return StringToBstr(Password, password);
    }

    HRESULT CryptoGetTextPassword(BSTR *password) Z7_override {
        if (!PasswordIsDefined) { PasswordWasMissing = true; return E_ABORT; }
        return StringToBstr(Password, password);
    }

    HRESULT ShowDeleteFile(const wchar_t * /*name*/, bool /*isDir*/) Z7_override { return S_OK; }

    // IUpdateCallbackUI2
    HRESULT OpenResult(const CCodecs * /*codecs*/, const CArchiveLink & /*arcLink*/, const wchar_t * /*name*/, HRESULT result) Z7_override {
        OpenFailed = result != S_OK;
        return result;
    }
    HRESULT StartScanning() Z7_override { return CheckBreak(); }
    HRESULT FinishScanning(const CDirItemsStat & /*st*/) Z7_override { return CheckBreak(); }
    HRESULT StartOpenArchive(const wchar_t * /*name*/) Z7_override { return CheckBreak(); }
    HRESULT StartArchive(const wchar_t * /*name*/, bool /*updating*/) Z7_override { return CheckBreak(); }
    HRESULT FinishArchive(const CFinishArchiveStat & /*st*/) Z7_override { return S_OK; }
    HRESULT DeletingAfterArchiving(const FString & /*path*/, bool /*isDir*/) Z7_override { return S_OK; }
    HRESULT FinishDeletingAfterArchiving() Z7_override { return S_OK; }
    HRESULT MoveArc_Start(const wchar_t * /*srcTempPath*/, const wchar_t * /*destFinalPath*/, UInt64 /*size*/, Int32 /*updateMode*/) Z7_override { return S_OK; }
    HRESULT MoveArc_Progress(UInt64 /*total*/, UInt64 /*current*/) Z7_override { return S_OK; }
    HRESULT MoveArc_Finish() Z7_override { return S_OK; }
};

static void SplitRelativePathParts(const char *relPath, UStringVector &parts) {
    parts.Clear();
    if (!relPath) return;
    UString u = Utf8ToUString(relPath);
    UString current;
    for (unsigned i = 0; i < u.Len(); i++) {
        const wchar_t c = u[i];
        if (c == L'/' || c == L'\\') {
            if (!current.IsEmpty()) {
                parts.Add(current);
                current.Empty();
            }
        } else {
            current += c;
        }
    }
    if (!current.IsEmpty()) {
        parts.Add(current);
    }
}

static NExtract::NOverwriteMode::EEnum MapOverwriteMode(sz_overwrite_mode_t mode, bool hasAskCallback) {
    switch (mode) {
        case SZ_OVERWRITE_ASK:
            return hasAskCallback ? NExtract::NOverwriteMode::kAsk : NExtract::NOverwriteMode::kOverwrite;
        case SZ_OVERWRITE_ALL:
            return NExtract::NOverwriteMode::kOverwrite;
        case SZ_OVERWRITE_SKIP:
            return NExtract::NOverwriteMode::kSkip;
        case SZ_OVERWRITE_AUTO_RENAME:
            return NExtract::NOverwriteMode::kRename;
        case SZ_OVERWRITE_AUTO_RENAME_EXISTING:
            return NExtract::NOverwriteMode::kRenameExisting;
    }
    return NExtract::NOverwriteMode::kOverwrite;
}

static void AddMethodProperty(CObjectVector<CProperty> &props, const char *name, const UString &value) {
    CProperty p;
    p.Name = Utf8ToUString(name);
    p.Value = value;
    props.Add(p);
}

static void AddRecursiveWildcardExclude(NWildcard::CCensorNode &head, const char *pattern) {
    NWildcard::CItem item;
    item.PathParts.Add(Utf8ToUString(pattern));
    item.ForFile = true;
    item.ForDir = true;
    item.Recursive = true;
    item.WildcardMatching = true;
    head.AddItem(false, item, -1);
}

static HRESULT InitStandardHashBundle(CCodecs *codecs, CHashBundle &hb) {
    UStringVector methods;
    methods.Add(UString("*"));
#ifdef Z7_EXTERNAL_CODECS
    CExternalCodecs extCodecs;
    extCodecs.GetCodecs = codecs;
    extCodecs.GetHashers = codecs;
    const CExternalCodecs *__externalCodecs = &extCodecs;
#else
    (void)codecs;
#endif
    return hb.SetMethods(EXTERNAL_CODECS_LOC_VARS methods);
}

static sz_status_t ExportHashDigests(
    const CHashBundle &hb,
    sz_hash_digest_t **out_digests,
    uint32_t *out_count,
    char **out_error
) {
    const unsigned count = hb.Hashers.Size();
    sz_hash_digest_t *arr = static_cast<sz_hash_digest_t *>(
        std::calloc(count, sizeof(sz_hash_digest_t))
    );
    if (!arr && count > 0) {
        SetError(out_error, "Out of memory allocating hash digests");
        return SZ_STATUS_ERR_INTERNAL;
    }

    for (unsigned i = 0; i < count; i++) {
        const CHasherState &h = hb.Hashers[i];
        char hexBuf[k_HashCalc_DigestSize_Max * 2 + 64];
        hexBuf[0] = '\0';
        h.WriteToString(k_HashCalc_Index_Current, hexBuf);
        arr[i].algorithm = DupString(std::string(h.Name.Ptr(), h.Name.Len()));
        arr[i].hex = DupString(hexBuf);
    }

    *out_digests = arr;
    *out_count = static_cast<uint32_t>(count);
    return SZ_STATUS_OK;
}

} // namespace

struct sz_archive {
    CCodecs *codecs;
    CArchiveLink link;
    std::string path;
    bool headers_encrypted;
};

extern "C" {

const char *sz_version_string(void) {
    return "7-Zip " MY_VERSION_NUMBERS;
}

sz_status_t sz_get_supported_formats(
    sz_format_info_t **out_formats,
    uint32_t *out_count,
    char **out_error
) {
    if (!out_formats || !out_count) {
        SetError(out_error, "Invalid output pointer");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    *out_formats = nullptr;
    *out_count = 0;

    HRESULT loadRes = S_OK;
    CCodecs *codecs = GetGlobalCodecs(&loadRes);
    if (loadRes != S_OK || !codecs) {
        SetError(out_error, "Failed to initialize 7-Zip codecs");
        return SZ_STATUS_ERR_INTERNAL;
    }

    const unsigned count = codecs->Formats.Size();
    sz_format_info_t *arr = static_cast<sz_format_info_t *>(
        std::calloc(count, sizeof(sz_format_info_t))
    );
    if (!arr && count > 0) {
        SetError(out_error, "Out of memory");
        return SZ_STATUS_ERR_INTERNAL;
    }

    for (unsigned i = 0; i < count; i++) {
        const CArcInfoEx &fmt = codecs->Formats[i];
        arr[i].name = UStringToHeapUtf8(fmt.Name);
        UString allExts;
        for (unsigned eIdx = 0; eIdx < fmt.Exts.Size(); eIdx++) {
            if (eIdx > 0) allExts.Add_Space();
            allExts += fmt.Exts[eIdx].Ext;
        }
        arr[i].extensions = UStringToHeapUtf8(allExts);
        arr[i].updatable = fmt.UpdateEnabled;
        arr[i].keep_name = fmt.Flags_KeepName();
    }

    *out_formats = arr;
    *out_count = static_cast<uint32_t>(count);
    return SZ_STATUS_OK;
}

void sz_free_formats(sz_format_info_t *formats, uint32_t count) {
    if (!formats) return;
    for (uint32_t i = 0; i < count; i++) {
        std::free(formats[i].name);
        std::free(formats[i].extensions);
    }
    std::free(formats);
}

sz_status_t sz_archive_open_with_progress(
    const char *path,
    const char *password,
    uint32_t code_page,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    sz_archive_t **out_archive,
    char **out_error
) {
    if (!path || !*path || !out_archive) {
        SetError(out_error, "Archive path is empty");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    *out_archive = nullptr;
    if (progress_cb && !progress_cb(0, 0, nullptr, user_data)) {
        SetError(out_error, "Archive open cancelled");
        return SZ_STATUS_ERR_CANCELLED;
    }

    try {
        HRESULT loadRes = S_OK;
        CCodecs *codecs = GetGlobalCodecs(&loadRes);
        if (loadRes != S_OK || !codecs) {
            SetError(out_error, "Failed to initialize 7-Zip codecs");
            return SZ_STATUS_ERR_INTERNAL;
        }

        sz_archive_t *holder = new sz_archive_t();
        holder->codecs = codecs;
        holder->path = path;
        holder->headers_encrypted = false;

        CObjectVector<COpenType> types;
        CIntVector excludedFormats;
        CObjectVector<CProperty> props;
        if (code_page > 0) {
            char cpBuf[32];
            ConvertUInt32ToString(static_cast<UInt32>(code_page), cpBuf);
            AddMethodProperty(props, "cp", Utf8ToUString(cpBuf));
        }

        COpenOptions op;
        op.codecs = codecs;
        op.types = &types;
        op.excludedFormats = &excludedFormats;
        op.stdInMode = false;
        op.stream = nullptr;
        op.filePath = Utf8ToUString(path);
#ifndef Z7_SFX
        op.props = &props;
#endif

        CBridgeOpenCallback openCb(password, password_cb, progress_cb, user_data);
        const HRESULT hr = holder->link.Open3(op, &openCb);
        holder->headers_encrypted = openCb.PasswordWasRequested || holder->link.PasswordWasAsked;

        if (hr != S_OK || !holder->link.IsOpen || holder->link.Arcs.IsEmpty()) {
            const UInt32 errFlags = holder->link.NonOpen_ErrorInfo.GetErrorFlags();
            const bool isEncryptedHdrErr = (errFlags & kpv_ErrorFlags_EncryptedHeadersError) != 0;
            const bool missingPwd = openCb.PasswordWasMissing;
            const bool requestedPwd = openCb.PasswordWasRequested;

            delete holder;

            if (openCb.Cancelled) {
                SetError(out_error, "Archive open cancelled");
                return SZ_STATUS_ERR_CANCELLED;
            }
            if (missingPwd || (isEncryptedHdrErr && (!password || !*password))) {
                SetError(out_error, "Archive headers are encrypted; password required");
                return SZ_STATUS_ERR_PASSWORD_REQUIRED;
            }
            if (isEncryptedHdrErr || (requestedPwd && hr != S_OK)) {
                SetError(out_error, "Wrong password for encrypted archive headers");
                return SZ_STATUS_ERR_WRONG_PASSWORD;
            }
            if (hr == E_ABORT) {
                SetError(out_error, "Archive open cancelled");
                return SZ_STATUS_ERR_CANCELLED;
            }
            SetError(out_error, "Cannot open file as archive");
            return SZ_STATUS_ERR_OPEN;
        }

        *out_archive = holder;
        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception while opening archive");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_archive_open_with_options(
    const char *path, const char *password, uint32_t code_page,
    sz_password_cb password_cb, void *user_data,
    sz_archive_t **out_archive, char **out_error
) {
    return sz_archive_open_with_progress(path, password, code_page, password_cb,
                                        nullptr, user_data, out_archive, out_error);
}

sz_status_t sz_archive_open(
    const char *path,
    const char *password,
    sz_password_cb password_cb,
    void *user_data,
    sz_archive_t **out_archive,
    char **out_error
) {
    return sz_archive_open_with_options(
        path,
        password,
        0,
        password_cb,
        user_data,
        out_archive,
        out_error
    );
}

void sz_archive_close(sz_archive_t *archive) {
    if (!archive) return;
    archive->link.Close();
    archive->link.Release();
    delete archive;
}

sz_status_t sz_archive_get_summary(
    const sz_archive_t *archive,
    sz_archive_summary_t *out_summary,
    char **out_error
) {
    if (!archive || !out_summary || !archive->link.IsOpen || archive->link.Arcs.IsEmpty()) {
        SetError(out_error, "Archive is not open");
        return SZ_STATUS_ERR_INVALID_ARG;
    }

    std::memset(out_summary, 0, sizeof(*out_summary));

    try {
        const CArc &mainArc = archive->link.Arcs.Back();
        IInArchive *inArc = mainArc.Archive;

        if (mainArc.FormatIndex >= 0 && static_cast<unsigned>(mainArc.FormatIndex) < archive->codecs->Formats.Size()) {
            const CArcInfoEx &fmt = archive->codecs->Formats[static_cast<unsigned>(mainArc.FormatIndex)];
            out_summary->format_name = UStringToHeapUtf8(fmt.Name);
            const bool singleLayer = (archive->link.Arcs.Size() == 1);
            const bool multiVol = (archive->link.VolumePaths.Size() > 1);
            out_summary->is_updatable = singleLayer && !multiVol && fmt.UpdateEnabled && !mainArc.IsReadOnly;
        } else {
            out_summary->format_name = DupString("Unknown");
            out_summary->is_updatable = false;
        }

        if (archive->link.Arcs.Size() > 1) {
            const CArc &outerArc = archive->link.Arcs[0];
            if (outerArc.FormatIndex >= 0 && static_cast<unsigned>(outerArc.FormatIndex) < archive->codecs->Formats.Size()) {
                out_summary->outer_format_name = UStringToHeapUtf8(
                    archive->codecs->Formats[static_cast<unsigned>(outerArc.FormatIndex)].Name
                );
            }
        }

        out_summary->physical_size = static_cast<uint64_t>(
            archive->link.VolumesSize > 0 ? archive->link.VolumesSize : mainArc.GetEstmatedPhySize()
        );

        {
            CPropVariant prop;
            if (inArc->GetArchiveProperty(kpidHeadersSize, &prop) == S_OK && prop.vt == VT_UI8) {
                out_summary->headers_size = static_cast<uint64_t>(prop.uhVal.QuadPart);
            }
        }
        {
            CPropVariant prop;
            if (inArc->GetArchiveProperty(kpidSolid, &prop) == S_OK && prop.vt == VT_BOOL) {
                out_summary->is_solid = VARIANT_BOOLToBool(prop.boolVal);
            }
        }
        {
            CPropVariant prop;
            if (inArc->GetArchiveProperty(kpidComment, &prop) == S_OK && prop.vt == VT_BSTR && prop.bstrVal) {
                out_summary->comment = UStringToHeapUtf8(UString(prop.bstrVal));
            }
        }

        UInt32 numItems = 0;
        if (inArc->GetNumberOfItems(&numItems) == S_OK) {
            out_summary->item_count = static_cast<uint32_t>(numItems);
        }

        const unsigned numVols = archive->link.VolumePaths.Size();
        out_summary->num_volumes = numVols > 0 ? static_cast<uint32_t>(numVols) : 1;
        out_summary->is_multi_volume = (numVols > 1);
        out_summary->headers_encrypted = archive->headers_encrypted;

        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception while reading archive summary");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

void sz_free_summary(sz_archive_summary_t *summary) {
    if (!summary) return;
    std::free(summary->format_name);
    std::free(summary->outer_format_name);
    std::free(summary->comment);
    std::memset(summary, 0, sizeof(*summary));
}

sz_status_t sz_archive_get_items(
    const sz_archive_t *archive,
    sz_item_info_t **out_items,
    uint32_t *out_count,
    char **out_error
) {
    if (!archive || !out_items || !out_count || !archive->link.IsOpen || archive->link.Arcs.IsEmpty()) {
        SetError(out_error, "Invalid arguments to sz_archive_get_items");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    *out_items = nullptr;
    *out_count = 0;

    try {
        const CArc &arc = archive->link.Arcs.Back();
        IInArchive *inArc = arc.Archive;

        UInt32 numItems = 0;
        const HRESULT hrCount = inArc->GetNumberOfItems(&numItems);
        if (hrCount != S_OK) {
            SetError(out_error, "Failed to query archive item count");
            return SZ_STATUS_ERR_CORRUPT;
        }
        if (numItems == 0) {
            return SZ_STATUS_OK;
        }

        sz_item_info_t *items = static_cast<sz_item_info_t *>(
            std::calloc(numItems, sizeof(sz_item_info_t))
        );
        if (!items) {
            SetError(out_error, "Out of memory allocating item list");
            return SZ_STATUS_ERR_INTERNAL;
        }

        for (UInt32 i = 0; i < numItems; i++) {
            sz_item_info_t &dst = items[i];
            dst.index = static_cast<uint32_t>(i);

            UString uPath;
            if (arc.GetItem_Path(i, uPath) != S_OK || uPath.IsEmpty()) {
                arc.GetItem_DefaultPath(i, uPath);
            }
            for (unsigned cIdx = 0; cIdx < uPath.Len(); cIdx++) {
                if (uPath[cIdx] == L'\\') {
                    uPath.ReplaceOneCharAtPos(cIdx, L'/');
                }
            }
            while (!uPath.IsEmpty() && uPath[0] == L'/') {
                uPath.DeleteFrontal(1);
            }
            while (uPath.Len() > 1 && uPath.Back() == L'/') {
                uPath.DeleteBack();
            }
            dst.path = UStringToHeapUtf8(uPath);

            bool isDir = false;
            Archive_IsItem_Dir(inArc, i, isDir);
            dst.is_dir = isDir;

            UInt64 size = 0;
            bool sizeDefined = false;
            if (arc.GetItem_Size(i, size, sizeDefined) == S_OK && sizeDefined) {
                dst.size = static_cast<uint64_t>(size);
                dst.has_size = true;
            }

            {
                CPropVariant prop;
                if (inArc->GetProperty(i, kpidPackSize, &prop) == S_OK) {
                    if (prop.vt == VT_UI8) {
                        dst.packed_size = static_cast<uint64_t>(prop.uhVal.QuadPart);
                        dst.has_packed_size = true;
                    } else if (prop.vt == VT_UI4) {
                        dst.packed_size = static_cast<uint64_t>(prop.ulVal);
                        dst.has_packed_size = true;
                    }
                }
            }

            {
                CArcTime at;
                if (arc.GetItem_MTime(i, at) == S_OK && at.Def && !FILETIME_IsZero(at.FT)) {
                    CFiTime ts;
                    if (FILETIME_To_timespec(at.FT, ts)) {
                        dst.mtime_sec = static_cast<int64_t>(ts.tv_sec);
                        dst.mtime_nsec = static_cast<int32_t>(ts.tv_nsec);
                        dst.has_mtime = true;
                    }
                }
            }

            {
                CPropVariant prop;
                if (inArc->GetProperty(i, kpidPosixAttrib, &prop) == S_OK && prop.vt == VT_UI4) {
                    dst.posix_mode = static_cast<uint32_t>(prop.ulVal);
                }
            }

            {
                CPropVariant prop;
                if (inArc->GetProperty(i, kpidAttrib, &prop) == S_OK && prop.vt == VT_UI4) {
                    const UInt32 rawAttr = prop.ulVal;
                    if (dst.posix_mode == 0 && (rawAttr & FILE_ATTRIBUTE_UNIX_EXTENSION) != 0) {
                        dst.posix_mode = static_cast<uint32_t>(rawAttr >> 16);
                    }
                    char attrBuf[64];
                    attrBuf[0] = '\0';
                    ConvertPropertyToShortString2(attrBuf, prop, kpidAttrib, 0);
                    if (attrBuf[0] != '\0') {
                        dst.attributes = DupString(attrBuf);
                    }
                }
            }

            if ((dst.posix_mode & 0170000) == 0120000) {
                dst.is_symlink = true;
            }

            {
                CPropVariant prop;
                if (inArc->GetProperty(i, kpidSymLink, &prop) == S_OK && prop.vt == VT_BSTR && prop.bstrVal) {
                    dst.symlink_target = UStringToHeapUtf8(UString(prop.bstrVal));
                    dst.is_symlink = true;
                }
            }

            {
                CPropVariant prop;
                if (inArc->GetProperty(i, kpidCRC, &prop) == S_OK && prop.vt == VT_UI4) {
                    dst.crc32 = static_cast<uint32_t>(prop.ulVal);
                    dst.has_crc32 = true;
                }
            }

            {
                CPropVariant prop;
                if (inArc->GetProperty(i, kpidMethod, &prop) == S_OK && prop.vt != VT_EMPTY) {
                    UString methodStr;
                    ConvertPropertyToString2(methodStr, prop, kpidMethod, 0);
                    if (!methodStr.IsEmpty()) {
                        dst.method = UStringToHeapUtf8(methodStr);
                    }
                }
            }

            bool encrypted = false;
            if (Archive_GetItemBoolProp(inArc, i, kpidEncrypted, encrypted) == S_OK) {
                dst.is_encrypted = encrypted;
            }
        }

        *out_items = items;
        *out_count = static_cast<uint32_t>(numItems);
        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception while enumerating archive items");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

void sz_free_items(sz_item_info_t *items, uint32_t count) {
    if (!items) return;
    for (uint32_t i = 0; i < count; i++) {
        std::free(items[i].path);
        std::free(items[i].attributes);
        std::free(items[i].method);
        std::free(items[i].symlink_target);
    }
    std::free(items);
}

static sz_status_t RunExtractOrTest(
    sz_archive_t *archive,
    const uint32_t *indices,
    uint32_t index_count,
    const char *dest_dir,
    const char *strip_prefix,
    bool full_paths,
    sz_overwrite_mode_t overwrite_mode,
    sz_overwrite_cb overwrite_cb,
    bool test_mode,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    if (!archive || !archive->link.IsOpen || archive->link.Arcs.IsEmpty()) {
        SetError(out_error, "Archive is not open");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    if (!test_mode && (!dest_dir || !*dest_dir)) {
        SetError(out_error, "Destination directory is required for extraction");
        return SZ_STATUS_ERR_INVALID_ARG;
    }

    try {
        const CArc &arc = archive->link.Arcs.Back();
        IInArchive *inArc = arc.Archive;

        CRecordVector<UInt32> sortedIndices;
        if (indices != nullptr && index_count > 0) {
            std::vector<uint32_t> tmp(indices, indices + index_count);
            std::sort(tmp.begin(), tmp.end());
            tmp.erase(std::unique(tmp.begin(), tmp.end()), tmp.end());
            for (uint32_t idx : tmp) {
                sortedIndices.Add(static_cast<UInt32>(idx));
            }
        }

        FString outDirFs;
        if (!test_mode) {
            outDirFs = us2fs(Utf8ToUString(dest_dir));
            NFile::NName::NormalizeDirPathPrefix(outDirFs);
            NFile::NDir::CreateComplexDir(outDirFs);
        }

        UStringVector removePathParts;
        SplitRelativePathParts(strip_prefix, removePathParts);

        NExtract::NPathMode::EEnum pathMode = full_paths
            ? NExtract::NPathMode::kFullPaths
            : NExtract::NPathMode::kNoPaths;

        CExtractNtOptions ntOptions;
        ntOptions.SymLinks.Val = true;
        ntOptions.HardLinks.Val = true;

        CBridgeExtractCallback *bridgeCbSpec = new CBridgeExtractCallback(
            password,
            overwrite_mode,
            overwrite_cb,
            password_cb,
            progress_cb,
            user_data
        );
        CMyComPtr<IFolderArchiveExtractCallback> bridgeCb(bridgeCbSpec);

        CArchiveExtractCallback *ecsSpec = new CArchiveExtractCallback();
        CMyComPtr<IArchiveExtractCallback> ecs(ecsSpec);

        ecsSpec->InitForMulti(
            false,
            pathMode,
            MapOverwriteMode(overwrite_mode, overwrite_cb != nullptr),
            NExtract::NZoneIdMode::kNone,
            false
        );

        ecsSpec->Init(
            ntOptions,
            nullptr,
            &arc,
            bridgeCb,
            false,
            test_mode,
            outDirFs,
            removePathParts,
            false,
            arc.GetEstmatedPhySize()
        );

#ifdef SUPPORT_LINKS
        if (!test_mode) {
            const HRESULT hlRes = ecsSpec->PrepareHardLinks(
                sortedIndices.IsEmpty() ? nullptr : &sortedIndices
            );
            if (hlRes != S_OK) {
                SetError(out_error, "Failed preparing archive links");
                return SZ_STATUS_ERR_IO;
            }
        }
#endif

        CArchiveExtractCallback_Closer closer(ecsSpec);

        const UInt32 *idxPtr = sortedIndices.IsEmpty() ? nullptr : &sortedIndices[0];
        const UInt32 idxCount = sortedIndices.IsEmpty()
            ? static_cast<UInt32>(static_cast<Int32>(-1))
            : static_cast<UInt32>(sortedIndices.Size());

        const HRESULT hr = inArc->Extract(idxPtr, idxCount, BoolToInt(test_mode), ecs);
        const HRESULT closeHr = closer.Close();

        if (bridgeCbSpec->Cancelled) {
            SetError(out_error, "Operation cancelled");
            return SZ_STATUS_ERR_CANCELLED;
        }
        if (bridgeCbSpec->PasswordWasMissing) {
            SetError(out_error, "Password is required to decrypt archive contents");
            return SZ_STATUS_ERR_PASSWORD_REQUIRED;
        }
        if (bridgeCbSpec->HadWrongPassword) {
            SetError(out_error, "Incorrect password");
            return SZ_STATUS_ERR_WRONG_PASSWORD;
        }
        if (bridgeCbSpec->HadUnsupportedMethod) {
            SetError(out_error, "Unsupported compression method");
            return SZ_STATUS_ERR_UNSUPPORTED;
        }
        if (bridgeCbSpec->HadCorruptData || hr != S_OK || closeHr != S_OK) {
            std::string msg = bridgeCbSpec->ErrorLog.empty()
                ? "Archive extraction or integrity check failed"
                : bridgeCbSpec->ErrorLog;
            SetError(out_error, msg);
            return SZ_STATUS_ERR_CORRUPT;
        }

        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception during archive extraction");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_archive_extract_ex(
    sz_archive_t *archive,
    const uint32_t *indices,
    uint32_t index_count,
    const char *dest_dir,
    const char *strip_prefix,
    bool full_paths,
    sz_overwrite_mode_t overwrite_mode,
    sz_overwrite_cb overwrite_cb,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    return RunExtractOrTest(
        archive,
        indices,
        index_count,
        dest_dir,
        strip_prefix,
        full_paths,
        overwrite_mode,
        overwrite_cb,
        false,
        password,
        password_cb,
        progress_cb,
        user_data,
        out_error
    );
}

sz_status_t sz_archive_extract(
    sz_archive_t *archive,
    const uint32_t *indices,
    uint32_t index_count,
    const char *dest_dir,
    const char *strip_prefix,
    bool full_paths,
    sz_overwrite_mode_t overwrite_mode,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    return RunExtractOrTest(
        archive,
        indices,
        index_count,
        dest_dir,
        strip_prefix,
        full_paths,
        overwrite_mode,
        nullptr,
        false,
        password,
        password_cb,
        progress_cb,
        user_data,
        out_error
    );
}

sz_status_t sz_archive_test(
    sz_archive_t *archive,
    const uint32_t *indices,
    uint32_t index_count,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    return RunExtractOrTest(
        archive,
        indices,
        index_count,
        nullptr,
        nullptr,
        true,
        SZ_OVERWRITE_SKIP,
        nullptr,
        true,
        password,
        password_cb,
        progress_cb,
        user_data,
        out_error
    );
}

sz_status_t sz_archive_extract_to_memory(
    sz_archive_t *archive,
    uint32_t index,
    uint64_t max_bytes,
    const char *password,
    sz_password_cb password_cb,
    uint8_t **out_data,
    size_t *out_size,
    char **out_error
) {
    if (!archive || !out_data || !out_size || !archive->link.IsOpen || archive->link.Arcs.IsEmpty()) {
        SetError(out_error, "Invalid arguments to sz_archive_extract_to_memory");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    *out_data = nullptr;
    *out_size = 0;

    try {
        const CArc &arc = archive->link.Arcs.Back();
        IInArchive *inArc = arc.Archive;

        bool isEncrypted = false;
        Archive_GetItemBoolProp(inArc, static_cast<UInt32>(index), kpidEncrypted, isEncrypted);

        CMemBoundedOutStream *memSpec = new CMemBoundedOutStream(max_bytes);
        CSingleStreamExtractCallback *cbSpec = new CSingleStreamExtractCallback(
            static_cast<UInt32>(index),
            isEncrypted,
            memSpec,
            password,
            password_cb,
            nullptr
        );
        CMyComPtr<IArchiveExtractCallback> cb(cbSpec);

        const UInt32 target = static_cast<UInt32>(index);
        const HRESULT hr = inArc->Extract(&target, 1, 0, cb);

        if (memSpec->ExceededLimit) {
            SetError(out_error, "Item exceeds maximum preview size limit");
            return SZ_STATUS_ERR_IO;
        }
        if (cbSpec->PasswordWasMissing) {
            SetError(out_error, "Password required");
            return SZ_STATUS_ERR_PASSWORD_REQUIRED;
        }
        if (cbSpec->HadWrongPassword) {
            SetError(out_error, "Incorrect password");
            return SZ_STATUS_ERR_WRONG_PASSWORD;
        }
        if (cbSpec->HadCorruptData || hr != S_OK) {
            SetError(out_error, "Failed extracting item into memory");
            return SZ_STATUS_ERR_CORRUPT;
        }

        const size_t sz = memSpec->Buffer.size();
        uint8_t *raw = static_cast<uint8_t *>(std::malloc(sz > 0 ? sz : 1));
        if (!raw) {
            SetError(out_error, "Out of memory");
            return SZ_STATUS_ERR_INTERNAL;
        }
        if (sz > 0) {
            std::memcpy(raw, memSpec->Buffer.data(), sz);
        }
        *out_data = raw;
        *out_size = sz;
        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception while extracting item to memory");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_archive_update(
    const char *archive_path,
    const char * const *input_paths,
    uint32_t input_count,
    const char *base_dir,
    const sz_update_options_t *options,
    const char *password,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    if (!archive_path || !*archive_path || (!input_paths && input_count > 0) || input_count == 0) {
        SetError(out_error, "Invalid archive path or empty input list");
        return SZ_STATUS_ERR_INVALID_ARG;
    }

    try {
        HRESULT loadRes = S_OK;
        CCodecs *codecs = GetGlobalCodecs(&loadRes);
        if (loadRes != S_OK || !codecs) {
            SetError(out_error, "Failed to initialize 7-Zip codecs");
            return SZ_STATUS_ERR_INTERNAL;
        }

        CObjectVector<COpenType> types;
        std::string fmtLower;
        if (options && options->format_name && options->format_name[0] != '\0') {
            UString fmtU = Utf8ToUString(options->format_name);
            if (!ParseOpenTypes(*codecs, fmtU, types)) {
                SetError(out_error, std::string("Unsupported archive format: ") + options->format_name);
                return SZ_STATUS_ERR_UNSUPPORTED;
            }
            fmtLower = options->format_name;
            std::transform(fmtLower.begin(), fmtLower.end(), fmtLower.begin(), ::tolower);
        } else {
            const char *dot = std::strrchr(archive_path, '.');
            if (dot && dot[1]) {
                fmtLower = dot + 1;
                std::transform(fmtLower.begin(), fmtLower.end(), fmtLower.begin(), ::tolower);
            }
        }

        CUpdateOptions uo;
        uo.ArcNameMode = k_ArcNameMode_Exact;
        uo.PathMode = NWildcard::k_RelatPath;
        uo.SymLinks.Val = (options == nullptr) ? true : options->store_symlinks;
        uo.SymLinks.Def = true;
        uo.HardLinks.Val = false;
        uo.SetActionCommand_Add();

        const bool hasPassword = (password != nullptr && password[0] != '\0');
        const bool is7z = (fmtLower == "7z");
        const bool isZip = (fmtLower == "zip");
        const bool excludeMacJunk = (options != nullptr && options->exclude_macos_metadata);

        if (options) {
            if (options->compression_level >= 0 && options->compression_level <= 9) {
                char buf[16];
                ConvertUInt32ToString(static_cast<UInt32>(options->compression_level), buf);
                AddMethodProperty(uo.MethodMode.Properties, "x", Utf8ToUString(buf));
            }
            if (options->method && options->method[0] != '\0') {
                if (is7z) {
                    AddMethodProperty(uo.MethodMode.Properties, "0", Utf8ToUString(options->method));
                } else if (isZip) {
                    AddMethodProperty(uo.MethodMode.Properties, "m", Utf8ToUString(options->method));
                }
            }
            if (options->dictionary_size_kb > 0 && is7z) {
                std::string dictStr = std::to_string(options->dictionary_size_kb) + "k";
                AddMethodProperty(uo.MethodMode.Properties, "d", Utf8ToUString(dictStr.c_str()));
            }
            if (options->num_threads > 0) {
                std::string mtStr = std::to_string(options->num_threads);
                AddMethodProperty(uo.MethodMode.Properties, "mt", Utf8ToUString(mtStr.c_str()));
            }
            if (is7z) {
                if (options->solid_block_bytes == 0) {
                    AddMethodProperty(uo.MethodMode.Properties, "s", UString("off"));
                } else if (options->solid_block_bytes > 0) {
                    std::string solidStr = std::to_string(options->solid_block_bytes) + "b";
                    AddMethodProperty(uo.MethodMode.Properties, "s", Utf8ToUString(solidStr.c_str()));
                }
                if (hasPassword && options->encrypt_headers) {
                    AddMethodProperty(uo.MethodMode.Properties, "he", UString("on"));
                }
            }
            if (options->volume_bytes > 0) {
                uo.VolumesSizes.Add(static_cast<UInt64>(options->volume_bytes));
            }
        }

        if (hasPassword && isZip) {
            AddMethodProperty(uo.MethodMode.Properties, "em", UString("AES256"));
        }

        NWildcard::CCensor censor;
        if (base_dir && base_dir[0] != '\0') {
            UString prefix = Utf8ToUString(base_dir);
            if (!prefix.IsEmpty() && prefix.Back() != L'/') {
                prefix.Add_PathSepar();
            }
            NWildcard::CPair &pair = censor.Pairs.AddNew();
            pair.Prefix = prefix;

            for (uint32_t i = 0; i < input_count; i++) {
                UStringVector parts;
                SplitRelativePathParts(input_paths[i], parts);
                if (parts.IsEmpty()) continue;

                FString probePath = us2fs(prefix);
                for (unsigned pIdx = 0; pIdx < parts.Size(); pIdx++) {
                    if (pIdx > 0) probePath += FCHAR_PATH_SEPARATOR;
                    probePath += us2fs(parts[pIdx]);
                }
                NFile::NFind::CFileInfo fi;
                const bool isDirOnDisk = fi.Find(probePath, false) && fi.IsDir();

                NWildcard::CItem item;
                item.PathParts = parts;
                item.ForFile = true;
                item.ForDir = true;
                item.Recursive = isDirOnDisk;
                item.WildcardMatching = false;
                pair.Head.AddItem(true, item, -1);
            }

            if (excludeMacJunk) {
                AddRecursiveWildcardExclude(pair.Head, ".DS_Store");
                AddRecursiveWildcardExclude(pair.Head, "._*");
                AddRecursiveWildcardExclude(pair.Head, "__MACOSX");
            }
        } else {
            for (uint32_t i = 0; i < input_count; i++) {
                UString uPath = Utf8ToUString(input_paths[i]);
                while (uPath.Len() > 1 && uPath.Back() == L'/') {
                    uPath.DeleteBack();
                }
                censor.AddPreItem_NoWildcard(uPath);
            }
            if (excludeMacJunk) {
                NWildcard::CCensorPathProps exProps;
                exProps.Recursive = true;
                exProps.WildcardMatching = true;
                censor.AddPreItem(false, UString(".DS_Store"), exProps);
                censor.AddPreItem(false, UString("._*"), exProps);
                censor.AddPreItem(false, UString("__MACOSX"), exProps);
            }
        }

        CBridgeOpenCallback openCb(password, nullptr, progress_cb, user_data);
        CBridgeUpdateCallback updateCb(password, progress_cb, user_data);
        CUpdateErrorInfo errorInfo;

        const UString uArcPath = Utf8ToUString(archive_path);
        const HRESULT hr = UpdateArchive(
            codecs,
            types,
            uArcPath,
            censor,
            uo,
            errorInfo,
            &openCb,
            &updateCb,
            true
        );

        if (openCb.Cancelled || updateCb.Cancelled) {
            SetError(out_error, "Archive modification cancelled");
            return SZ_STATUS_ERR_CANCELLED;
        }
        if (openCb.PasswordWasMissing || updateCb.PasswordWasMissing) {
            SetError(out_error, "Password required to modify encrypted archive");
            return SZ_STATUS_ERR_PASSWORD_REQUIRED;
        }
        if (updateCb.HadWrongPassword || (updateCb.OpenFailed && openCb.PasswordWasRequested)) {
            SetError(out_error, "Wrong password for encrypted archive");
            return SZ_STATUS_ERR_WRONG_PASSWORD;
        }
        if (hr == E_ABORT) {
            SetError(out_error, "Archive update cancelled");
            return SZ_STATUS_ERR_CANCELLED;
        }
        if (hr == E_NOTIMPL) {
            std::string msg = errorInfo.Message.IsEmpty()
                ? "Archive format does not support creating or updating"
                : std::string(errorInfo.Message.Ptr());
            SetError(out_error, msg);
            return SZ_STATUS_ERR_UNSUPPORTED;
        }
        if (hr != S_OK) {
            std::string msg;
            if (!errorInfo.Message.IsEmpty()) {
                msg = errorInfo.Message.Ptr();
            } else if (!updateCb.ErrorLog.empty()) {
                msg = updateCb.ErrorLog;
            } else {
                msg = "Failed to create or update archive";
            }
            SetError(out_error, msg);
            return SZ_STATUS_ERR_IO;
        }

        return SZ_STATUS_OK;
    } catch (const CMessagePathException &e) {
        SetError(out_error, UStringToStdUtf8(e));
        return SZ_STATUS_ERR_IO;
    } catch (const UString &e) {
        SetError(out_error, UStringToStdUtf8(e));
        return SZ_STATUS_ERR_IO;
    } catch (const char *e) {
        SetError(out_error, e ? e : "Archive update error");
        return SZ_STATUS_ERR_IO;
    } catch (...) {
        SetError(out_error, "Internal exception while updating archive");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_archive_delete_items(
    const char *archive_path,
    const char * const *archive_item_paths,
    uint32_t path_count,
    const char *password,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    if (!archive_path || !*archive_path || !archive_item_paths || path_count == 0) {
        SetError(out_error, "Invalid arguments to sz_archive_delete_items");
        return SZ_STATUS_ERR_INVALID_ARG;
    }

    try {
        HRESULT loadRes = S_OK;
        CCodecs *codecs = GetGlobalCodecs(&loadRes);
        if (loadRes != S_OK || !codecs) {
            SetError(out_error, "Failed to initialize 7-Zip codecs");
            return SZ_STATUS_ERR_INTERNAL;
        }

        CObjectVector<COpenType> types;
        CUpdateOptions uo;
        uo.ArcNameMode = k_ArcNameMode_Exact;
        uo.PathMode = NWildcard::k_RelatPath;
        uo.Commands.Clear();
        {
            CUpdateArchiveCommand cmd;
            cmd.ActionSet = NUpdateArchive::k_ActionSet_Delete;
            uo.Commands.Add(cmd);
        }

        NWildcard::CCensor censor;
        NWildcard::CPair &pair = censor.Pairs.AddNew();
        for (uint32_t i = 0; i < path_count; i++) {
            UStringVector parts;
            SplitRelativePathParts(archive_item_paths[i], parts);
            if (parts.IsEmpty()) continue;
            NWildcard::CItem item;
            item.PathParts = parts;
            item.ForFile = true;
            item.ForDir = true;
            item.Recursive = true;
            item.WildcardMatching = false;
            pair.Head.AddItem(true, item, -1);
        }

        CBridgeOpenCallback openCb(password, nullptr, progress_cb, user_data);
        CBridgeUpdateCallback updateCb(password, progress_cb, user_data);
        CUpdateErrorInfo errorInfo;

        const HRESULT hr = UpdateArchive(
            codecs,
            types,
            Utf8ToUString(archive_path),
            censor,
            uo,
            errorInfo,
            &openCb,
            &updateCb,
            true
        );

        if (openCb.Cancelled || updateCb.Cancelled) {
            SetError(out_error, "Archive modification cancelled");
            return SZ_STATUS_ERR_CANCELLED;
        }
        if (openCb.PasswordWasMissing || updateCb.PasswordWasMissing) {
            SetError(out_error, "Password required to modify encrypted archive");
            return SZ_STATUS_ERR_PASSWORD_REQUIRED;
        }
        if (updateCb.HadWrongPassword || (updateCb.OpenFailed && openCb.PasswordWasRequested)) {
            SetError(out_error, "Wrong password for encrypted archive");
            return SZ_STATUS_ERR_WRONG_PASSWORD;
        }
        if (hr == E_NOTIMPL) {
            SetError(out_error, "Archive format does not support item deletion");
            return SZ_STATUS_ERR_UNSUPPORTED;
        }
        if (hr != S_OK) {
            SetError(out_error, errorInfo.Message.IsEmpty() ? "Failed deleting items from archive" : errorInfo.Message.Ptr());
            return SZ_STATUS_ERR_IO;
        }
        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception while deleting items from archive");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_archive_rename_items(
    const char *archive_path,
    const char * const *old_paths,
    const char * const *new_paths,
    uint32_t pair_count,
    const char *password,
    sz_progress_cb progress_cb,
    void *user_data,
    char **out_error
) {
    if (!archive_path || !*archive_path || !old_paths || !new_paths || pair_count == 0) {
        SetError(out_error, "Invalid arguments to sz_archive_rename_items");
        return SZ_STATUS_ERR_INVALID_ARG;
    }

    try {
        HRESULT loadRes = S_OK;
        CCodecs *codecs = GetGlobalCodecs(&loadRes);
        if (loadRes != S_OK || !codecs) {
            SetError(out_error, "Failed to initialize 7-Zip codecs");
            return SZ_STATUS_ERR_INTERNAL;
        }

        CObjectVector<COpenType> types;
        CUpdateOptions uo;
        uo.ArcNameMode = k_ArcNameMode_Exact;
        uo.RenameMode = true;
        uo.SetActionCommand_Add();

        for (uint32_t i = 0; i < pair_count; i++) {
            CRenamePair rp;
            rp.OldName = Utf8ToUString(old_paths[i]);
            rp.NewName = Utf8ToUString(new_paths[i]);
            rp.WildcardParsing = false;
            rp.RecursedType = NRecursedType::kNonRecursed;
            if (!rp.Prepare()) {
                SetError(out_error, "Invalid rename path pair");
                return SZ_STATUS_ERR_INVALID_ARG;
            }
            uo.RenamePairs.Add(rp);
        }

        NWildcard::CCensor censor;
        censor.AddPreItem_Wildcard();

        CBridgeOpenCallback openCb(password, nullptr, progress_cb, user_data);
        CBridgeUpdateCallback updateCb(password, progress_cb, user_data);
        CUpdateErrorInfo errorInfo;

        const HRESULT hr = UpdateArchive(
            codecs,
            types,
            Utf8ToUString(archive_path),
            censor,
            uo,
            errorInfo,
            &openCb,
            &updateCb,
            true
        );

        if (openCb.Cancelled || updateCb.Cancelled) {
            SetError(out_error, "Archive modification cancelled");
            return SZ_STATUS_ERR_CANCELLED;
        }
        if (openCb.PasswordWasMissing || updateCb.PasswordWasMissing) {
            SetError(out_error, "Password required to modify encrypted archive");
            return SZ_STATUS_ERR_PASSWORD_REQUIRED;
        }
        if (updateCb.HadWrongPassword || (updateCb.OpenFailed && openCb.PasswordWasRequested)) {
            SetError(out_error, "Wrong password for encrypted archive");
            return SZ_STATUS_ERR_WRONG_PASSWORD;
        }
        if (hr == E_NOTIMPL) {
            SetError(out_error, "Archive format does not support renaming");
            return SZ_STATUS_ERR_UNSUPPORTED;
        }
        if (hr != S_OK) {
            SetError(out_error, errorInfo.Message.IsEmpty() ? "Failed renaming items in archive" : errorInfo.Message.Ptr());
            return SZ_STATUS_ERR_IO;
        }
        return SZ_STATUS_OK;
    } catch (...) {
        SetError(out_error, "Internal exception while renaming items in archive");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_compute_file_hashes(
    const char *file_path,
    sz_progress_cb progress_cb,
    void *user_data,
    sz_hash_digest_t **out_digests,
    uint32_t *out_count,
    char **out_error
) {
    if (!file_path || !*file_path || !out_digests || !out_count) {
        SetError(out_error, "Invalid arguments to sz_compute_file_hashes");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    *out_digests = nullptr;
    *out_count = 0;

    try {
        HRESULT loadRes = S_OK;
        CCodecs *codecs = GetGlobalCodecs(&loadRes);
        if (loadRes != S_OK || !codecs) {
            SetError(out_error, "Failed to initialize 7-Zip codecs");
            return SZ_STATUS_ERR_INTERNAL;
        }

        CHashBundle hb;
        if (InitStandardHashBundle(codecs, hb) != S_OK) {
            SetError(out_error, "Failed to initialize 7-Zip hash bundle");
            return SZ_STATUS_ERR_INTERNAL;
        }

        FILE *fp = std::fopen(file_path, "rb");
        if (!fp) {
            SetError(out_error, "Cannot open file for hashing");
            return SZ_STATUS_ERR_IO;
        }

        std::fseek(fp, 0, SEEK_END);
        const long endPos = std::ftell(fp);
        const uint64_t totalSize = endPos > 0 ? static_cast<uint64_t>(endPos) : 0;
        std::fseek(fp, 0, SEEK_SET);

        hb.InitForNewFile();
        std::vector<uint8_t> buf(256 * 1024);
        uint64_t done = 0;

        while (true) {
            const size_t n = std::fread(buf.data(), 1, buf.size(), fp);
            if (n > 0) {
                hb.Update(buf.data(), static_cast<UInt32>(n));
                done += n;
                if (progress_cb && !progress_cb(done, totalSize, file_path, user_data)) {
                    std::fclose(fp);
                    SetError(out_error, "Hash calculation cancelled");
                    return SZ_STATUS_ERR_CANCELLED;
                }
            }
            if (n < buf.size()) {
                if (std::ferror(fp)) {
                    std::fclose(fp);
                    SetError(out_error, "Read error while hashing file");
                    return SZ_STATUS_ERR_IO;
                }
                break;
            }
        }
        std::fclose(fp);

        hb.Final(false, false, Utf8ToUString(file_path));
        return ExportHashDigests(hb, out_digests, out_count, out_error);
    } catch (...) {
        SetError(out_error, "Internal exception while hashing file");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

sz_status_t sz_archive_compute_entry_hashes(
    sz_archive_t *archive,
    uint32_t index,
    const char *password,
    sz_password_cb password_cb,
    sz_progress_cb progress_cb,
    void *user_data,
    sz_hash_digest_t **out_digests,
    uint32_t *out_count,
    char **out_error
) {
    if (!archive || !out_digests || !out_count || !archive->link.IsOpen || archive->link.Arcs.IsEmpty()) {
        SetError(out_error, "Invalid arguments to sz_archive_compute_entry_hashes");
        return SZ_STATUS_ERR_INVALID_ARG;
    }
    *out_digests = nullptr;
    *out_count = 0;

    try {
        const CArc &arc = archive->link.Arcs.Back();
        IInArchive *inArc = arc.Archive;

        CHashBundle hb;
        if (InitStandardHashBundle(archive->codecs, hb) != S_OK) {
            SetError(out_error, "Failed to initialize 7-Zip hash bundle");
            return SZ_STATUS_ERR_INTERNAL;
        }
        hb.InitForNewFile();

        UInt64 itemSize = 0;
        bool sizeDefined = false;
        arc.GetItem_Size(static_cast<UInt32>(index), itemSize, sizeDefined);

        bool isEncrypted = false;
        Archive_GetItemBoolProp(inArc, static_cast<UInt32>(index), kpidEncrypted, isEncrypted);

        CHashStreamingOutStream *hashStreamSpec = new CHashStreamingOutStream(
            &hb,
            sizeDefined ? static_cast<uint64_t>(itemSize) : 0,
            progress_cb,
            user_data
        );
        CSingleStreamExtractCallback *cbSpec = new CSingleStreamExtractCallback(
            static_cast<UInt32>(index),
            isEncrypted,
            hashStreamSpec,
            password,
            password_cb,
            user_data
        );
        CMyComPtr<IArchiveExtractCallback> cb(cbSpec);

        const UInt32 target = static_cast<UInt32>(index);
        const HRESULT hr = inArc->Extract(&target, 1, 0, cb);

        if (hashStreamSpec->Cancelled) {
            SetError(out_error, "Hash calculation cancelled");
            return SZ_STATUS_ERR_CANCELLED;
        }
        if (cbSpec->PasswordWasMissing) {
            SetError(out_error, "Password required");
            return SZ_STATUS_ERR_PASSWORD_REQUIRED;
        }
        if (cbSpec->HadWrongPassword) {
            SetError(out_error, "Incorrect password");
            return SZ_STATUS_ERR_WRONG_PASSWORD;
        }
        if (cbSpec->HadCorruptData || hr != S_OK) {
            SetError(out_error, "Failed reading archive entry for hashing");
            return SZ_STATUS_ERR_CORRUPT;
        }

        UString itemPath;
        arc.GetItem_Path(target, itemPath);
        hb.Final(false, false, itemPath);
        return ExportHashDigests(hb, out_digests, out_count, out_error);
    } catch (...) {
        SetError(out_error, "Internal exception while hashing archive entry");
        return SZ_STATUS_ERR_INTERNAL;
    }
}

void sz_free_hashes(sz_hash_digest_t *digests, uint32_t count) {
    if (!digests) return;
    for (uint32_t i = 0; i < count; i++) {
        std::free(digests[i].algorithm);
        std::free(digests[i].hex);
    }
    std::free(digests);
}

void sz_string_free(char *str) {
    std::free(str);
}

void sz_buffer_free(uint8_t *buf) {
    std::free(buf);
}

} // extern "C"
