import CSevenZip
import Foundation

private final class CallbackContext {
    let progressHandler: ((ArchiveProgress) -> Bool)?
    let passwordProvider: (() -> String?)?

    init(
        progressHandler: ((ArchiveProgress) -> Bool)? = nil,
        passwordProvider: (() -> String?)? = nil
    ) {
        self.progressHandler = progressHandler
        self.passwordProvider = passwordProvider
    }
}

private let cProgressBridge: sz_progress_cb = { completed, total, currentItemPtr, userData in
    guard let userData else { return true }
    let ctx = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
    guard let handler = ctx.progressHandler else { return true }
    let item = currentItemPtr.map { String(cString: $0) }
    return handler(ArchiveProgress(completedBytes: completed, totalBytes: total, currentItem: item))
}

private let cPasswordBridge: sz_password_cb = { userData in
    guard let userData else { return nil }
    let ctx = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
    guard let pwd = ctx.passwordProvider?(), !pwd.isEmpty else { return nil }
    return strdup(pwd)
}

public enum SevenZipEngine {
    public static var version: String {
        guard let ptr = sz_version_string() else { return "7-Zip" }
        return String(cString: ptr)
    }

    public static func supportedFormats() throws -> [ArchiveFormatInfo] {
        var rawPtr: UnsafeMutablePointer<sz_format_info_t>?
        var count: UInt32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?

        let status = sz_get_supported_formats(&rawPtr, &count, &errPtr)
        guard status == SZ_STATUS_OK else {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
        defer {
            if let rawPtr {
                sz_free_formats(rawPtr, count)
            }
        }

        guard let rawPtr, count > 0 else { return [] }
        let buffer = UnsafeBufferPointer(start: rawPtr, count: Int(count))
        return buffer.map { item in
            let name = item.name.map { String(cString: $0) } ?? ""
            let extRaw = item.extensions.map { String(cString: $0) } ?? ""
            let exts = extRaw
                .split(separator: " ")
                .map { String($0).lowercased() }
            return ArchiveFormatInfo(
                name: name,
                extensions: exts,
                isUpdatable: item.updatable,
                keepsStreamName: item.keep_name
            )
        }
    }

    /// Extensions appropriate for opening as an archive container on double-click in the file manager.
    public static let browsableArchiveExtensions: Set<String> = [
        "7z", "zip", "zipx", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz",
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "zst", "zstd", "cab", "iso", "dmg",
        "wim", "swm", "esd", "xar", "pkg", "rpm", "deb", "cpio", "ar", "arj", "lzh", "lha",
        "chm", "nsis", "squashfs", "udf", "vhd", "vhdx", "vmdk", "vdi", "qcow2",
        "cbz", "cbr", "jar", "war", "ear", "apk", "ipa", "xpi", "001"
    ]

    public static func isBrowsableArchive(url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return false
        }
        let ext = url.pathExtension.lowercased()
        return browsableArchiveExtensions.contains(ext)
    }

    public static func createOrUpdateArchive(
        at archiveURL: URL,
        inputPaths: [String],
        baseDirectory: URL? = nil,
        options: CompressionOptions = CompressionOptions(),
        password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        guard !inputPaths.isEmpty else {
            throw ArchiveError.invalidArgument("Список входных файлов пуст")
        }

        let ctx = CallbackContext(progressHandler: progress)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let status: sz_status_t = withCStrings(inputPaths) { cInputArray in
            let formatC = options.format.flatMap { $0.isEmpty ? nil : strdup($0) }
            let methodC = options.method.flatMap { $0.isEmpty ? nil : strdup($0) }
            defer {
                if let formatC { free(formatC) }
                if let methodC { free(methodC) }
            }

            var cOpts = sz_update_options_t(
                format_name: formatC,
                method: methodC,
                compression_level: Int32(options.level),
                dictionary_size_kb: options.dictionarySizeKB,
                num_threads: Int32(options.threads),
                solid_block_bytes: options.solidBlockBytes,
                volume_bytes: options.splitVolumeBytes,
                encrypt_headers: options.encryptHeaders,
                store_symlinks: options.storeSymlinks
            )

            return archiveURL.path.withCString { arcPathC in
                if let basePath = baseDirectory?.path {
                    return basePath.withCString { baseC in
                        if let password, !password.isEmpty {
                            return password.withCString { pwdC in
                                sz_archive_update(
                                    arcPathC,
                                    cInputArray,
                                    UInt32(inputPaths.count),
                                    baseC,
                                    &cOpts,
                                    pwdC,
                                    progress == nil ? nil : cProgressBridge,
                                    userData,
                                    &errPtr
                                )
                            }
                        } else {
                            return sz_archive_update(
                                arcPathC,
                                cInputArray,
                                UInt32(inputPaths.count),
                                baseC,
                                &cOpts,
                                nil,
                                progress == nil ? nil : cProgressBridge,
                                userData,
                                &errPtr
                            )
                        }
                    }
                } else {
                    if let password, !password.isEmpty {
                        return password.withCString { pwdC in
                            sz_archive_update(
                                arcPathC,
                                cInputArray,
                                UInt32(inputPaths.count),
                                nil,
                                &cOpts,
                                pwdC,
                                progress == nil ? nil : cProgressBridge,
                                userData,
                                &errPtr
                            )
                        }
                    } else {
                        return sz_archive_update(
                            arcPathC,
                            cInputArray,
                            UInt32(inputPaths.count),
                            nil,
                            &cOpts,
                            nil,
                            progress == nil ? nil : cProgressBridge,
                            userData,
                            &errPtr
                        )
                    }
                }
            }
        }

        if status != SZ_STATUS_OK {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
    }

    public static func deleteItems(
        in archiveURL: URL,
        archivePaths: [String],
        password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        guard !archivePaths.isEmpty else { return }
        let ctx = CallbackContext(progressHandler: progress)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let status = withCStrings(archivePaths) { cPaths in
            archiveURL.path.withCString { arcC in
                if let password, !password.isEmpty {
                    return password.withCString { pwdC in
                        sz_archive_delete_items(
                            arcC,
                            cPaths,
                            UInt32(archivePaths.count),
                            pwdC,
                            progress == nil ? nil : cProgressBridge,
                            userData,
                            &errPtr
                        )
                    }
                } else {
                    return sz_archive_delete_items(
                        arcC,
                        cPaths,
                        UInt32(archivePaths.count),
                        nil,
                        progress == nil ? nil : cProgressBridge,
                        userData,
                        &errPtr
                    )
                }
            }
        }

        if status != SZ_STATUS_OK {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
    }

    public static func renameItems(
        in archiveURL: URL,
        pairs: [(oldPath: String, newPath: String)],
        password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        guard !pairs.isEmpty else { return }
        let ctx = CallbackContext(progressHandler: progress)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let oldPaths = pairs.map(\.oldPath)
        let newPaths = pairs.map(\.newPath)

        let status = withCStrings(oldPaths) { cOld in
            withCStrings(newPaths) { cNew in
                archiveURL.path.withCString { arcC in
                    if let password, !password.isEmpty {
                        return password.withCString { pwdC in
                            sz_archive_rename_items(
                                arcC,
                                cOld,
                                cNew,
                                UInt32(pairs.count),
                                pwdC,
                                progress == nil ? nil : cProgressBridge,
                                userData,
                                &errPtr
                            )
                        }
                    } else {
                        return sz_archive_rename_items(
                            arcC,
                            cOld,
                            cNew,
                            UInt32(pairs.count),
                            nil,
                            progress == nil ? nil : cProgressBridge,
                            userData,
                            &errPtr
                        )
                    }
                }
            }
        }

        if status != SZ_STATUS_OK {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
    }
}

public final class OpenArchive: @unchecked Sendable {
    public let url: URL
    public let summary: ArchiveSummary
    public let entries: [ArchiveEntry]

    private let lock = NSLock()
    private var handle: OpaquePointer?

    public init(
        url: URL,
        password: String? = nil,
        passwordProvider: (() -> String?)? = nil
    ) throws {
        self.url = url
        let ctx = CallbackContext(passwordProvider: passwordProvider)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()

        var rawHandle: OpaquePointer?
        var errPtr: UnsafeMutablePointer<CChar>?

        let openStatus: sz_status_t = url.path.withCString { pathC in
            if let password, !password.isEmpty {
                return password.withCString { pwdC in
                    sz_archive_open(
                        pathC,
                        pwdC,
                        passwordProvider == nil ? nil : cPasswordBridge,
                        userData,
                        &rawHandle,
                        &errPtr
                    )
                }
            } else {
                return sz_archive_open(
                    pathC,
                    nil,
                    passwordProvider == nil ? nil : cPasswordBridge,
                    userData,
                    &rawHandle,
                    &errPtr
                )
            }
        }

        guard openStatus == SZ_STATUS_OK, let rawHandle else {
            throw ArchiveError.from(status: openStatus, errorPointer: errPtr)
        }
        self.handle = rawHandle

        do {
            self.summary = try Self.readSummary(handle: rawHandle)
            self.entries = try Self.readEntries(handle: rawHandle)
        } catch {
            sz_archive_close(rawHandle)
            self.handle = nil
            throw error
        }
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle {
            sz_archive_close(h)
            handle = nil
        }
    }

    public func extract(
        indices: [UInt32]? = nil,
        to destinationDirectory: URL,
        stripPrefix: String? = nil,
        fullPaths: Bool = true,
        overwrite: OverwriteMode = .overwriteAll,
        password: String? = nil,
        passwordProvider: (() -> String?)? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw ArchiveError.invalidArgument("Архив уже закрыт")
        }

        let ctx = CallbackContext(progressHandler: progress, passwordProvider: passwordProvider)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let cleanStrip = stripPrefix?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let stripToPass = (cleanStrip?.isEmpty == false) ? cleanStrip : nil

        let status: sz_status_t = destinationDirectory.path.withCString { destC in
            withOptionalCString(stripToPass) { stripC in
                withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
                    if let indices, !indices.isEmpty {
                        return indices.withUnsafeBufferPointer { idxBuf in
                            sz_archive_extract(
                                h,
                                idxBuf.baseAddress,
                                UInt32(idxBuf.count),
                                destC,
                                stripC,
                                fullPaths,
                                overwrite.cValue,
                                pwdC,
                                passwordProvider == nil ? nil : cPasswordBridge,
                                progress == nil ? nil : cProgressBridge,
                                userData,
                                &errPtr
                            )
                        }
                    } else {
                        return sz_archive_extract(
                            h,
                            nil,
                            0,
                            destC,
                            stripC,
                            fullPaths,
                            overwrite.cValue,
                            pwdC,
                            passwordProvider == nil ? nil : cPasswordBridge,
                            progress == nil ? nil : cProgressBridge,
                            userData,
                            &errPtr
                        )
                    }
                }
            }
        }

        if status != SZ_STATUS_OK {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
    }

    public func test(
        indices: [UInt32]? = nil,
        password: String? = nil,
        passwordProvider: (() -> String?)? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw ArchiveError.invalidArgument("Архив уже закрыт")
        }

        let ctx = CallbackContext(progressHandler: progress, passwordProvider: passwordProvider)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let status: sz_status_t = withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
            if let indices, !indices.isEmpty {
                return indices.withUnsafeBufferPointer { idxBuf in
                    sz_archive_test(
                        h,
                        idxBuf.baseAddress,
                        UInt32(idxBuf.count),
                        pwdC,
                        passwordProvider == nil ? nil : cPasswordBridge,
                        progress == nil ? nil : cProgressBridge,
                        userData,
                        &errPtr
                    )
                }
            } else {
                return sz_archive_test(
                    h,
                    nil,
                    0,
                    pwdC,
                    passwordProvider == nil ? nil : cPasswordBridge,
                    progress == nil ? nil : cProgressBridge,
                    userData,
                    &errPtr
                )
            }
        }

        if status != SZ_STATUS_OK {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
    }

    public func extractData(
        for index: UInt32,
        maxBytes: UInt64 = 64 * 1024 * 1024,
        password: String? = nil,
        passwordProvider: (() -> String?)? = nil
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw ArchiveError.invalidArgument("Архив уже закрыт")
        }

        let ctx = CallbackContext(passwordProvider: passwordProvider)
        var rawData: UnsafeMutablePointer<UInt8>?
        var rawSize: Int = 0
        var errPtr: UnsafeMutablePointer<CChar>?

        let status: sz_status_t = withExtendedLifetime(ctx) {
            withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
                sz_archive_extract_to_memory(
                    h,
                    index,
                    maxBytes,
                    pwdC,
                    passwordProvider == nil ? nil : cPasswordBridge,
                    &rawData,
                    &rawSize,
                    &errPtr
                )
            }
        }

        guard status == SZ_STATUS_OK, let rawData else {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
        defer { sz_buffer_free(rawData) }
        return Data(bytes: rawData, count: rawSize)
    }

    private static func readSummary(handle: OpaquePointer) throws -> ArchiveSummary {
        var cSum = sz_archive_summary_t()
        var errPtr: UnsafeMutablePointer<CChar>?
        let status = sz_archive_get_summary(handle, &cSum, &errPtr)
        guard status == SZ_STATUS_OK else {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
        defer { sz_free_summary(&cSum) }

        return ArchiveSummary(
            formatName: cSum.format_name.map { String(cString: $0) } ?? "Unknown",
            outerFormatName: cSum.outer_format_name.map { String(cString: $0) },
            comment: cSum.comment.map { String(cString: $0) },
            physicalSize: cSum.physical_size,
            headersSize: cSum.headers_size,
            itemCount: cSum.item_count,
            volumeCount: cSum.num_volumes,
            isSolid: cSum.is_solid,
            isMultiVolume: cSum.is_multi_volume,
            isUpdatable: cSum.is_updatable,
            headersEncrypted: cSum.headers_encrypted
        )
    }

    private static func readEntries(handle: OpaquePointer) throws -> [ArchiveEntry] {
        var rawItems: UnsafeMutablePointer<sz_item_info_t>?
        var count: UInt32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?

        let status = sz_archive_get_items(handle, &rawItems, &count, &errPtr)
        guard status == SZ_STATUS_OK else {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
        defer {
            if let rawItems {
                sz_free_items(rawItems, count)
            }
        }

        guard let rawItems, count > 0 else { return [] }
        let buf = UnsafeBufferPointer(start: rawItems, count: Int(count))
        var result: [ArchiveEntry] = []
        result.reserveCapacity(Int(count))

        for item in buf {
            let path = item.path.map { String(cString: $0) } ?? ""
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let mtime: Date?
            if item.has_mtime {
                let ts = TimeInterval(item.mtime_sec) + TimeInterval(item.mtime_nsec) / 1_000_000_000.0
                mtime = Date(timeIntervalSince1970: ts)
            } else {
                mtime = nil
            }

            result.append(
                ArchiveEntry(
                    index: item.index,
                    path: path,
                    name: name,
                    size: item.has_size ? item.size : nil,
                    packedSize: item.has_packed_size ? item.packed_size : nil,
                    modifiedDate: mtime,
                    posixMode: item.posix_mode,
                    attributes: item.attributes.map { String(cString: $0) } ?? "",
                    crc32: item.has_crc32 ? item.crc32 : nil,
                    method: item.method.map { String(cString: $0) },
                    symlinkTarget: item.symlink_target.map { String(cString: $0) },
                    isDirectory: item.is_dir,
                    isEncrypted: item.is_encrypted,
                    isSymlink: item.is_symlink
                )
            )
        }

        return result
    }
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let string {
        return string.withCString { body($0) }
    } else {
        return body(nil)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
    let duped: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer {
        for ptr in duped {
            if let ptr { free(ptr) }
        }
    }
    let constPtrs: [UnsafePointer<CChar>?] = duped.map { $0.map { UnsafePointer($0) } }
    return constPtrs.withUnsafeBufferPointer { buf in
        body(buf.baseAddress)
    }
}
