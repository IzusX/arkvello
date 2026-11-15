import CSevenZip
import Foundation

private final class CallbackContext {
    let progressHandler: ((ArchiveProgress) -> Bool)?
    let passwordProvider: (() -> String?)?
    let overwriteHandler: ((OverwriteConflict) -> OverwriteDecision)?

    init(
        progressHandler: ((ArchiveProgress) -> Bool)? = nil,
        passwordProvider: (() -> String?)? = nil,
        overwriteHandler: ((OverwriteConflict) -> OverwriteDecision)? = nil
    ) {
        self.progressHandler = progressHandler
        self.passwordProvider = passwordProvider
        self.overwriteHandler = overwriteHandler
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

private let cOverwriteBridge: sz_overwrite_cb = { promptPtr, userData in
    guard let promptPtr, let userData else { return SZ_OW_ANSWER_YES_TO_ALL }
    let ctx = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
    guard let handler = ctx.overwriteHandler else { return SZ_OW_ANSWER_YES_TO_ALL }

    let p = promptPtr.pointee
    let conflict = OverwriteConflict(
        existingPath: p.existing_path.map { String(cString: $0) } ?? "",
        existingSize: p.has_existing_size ? p.existing_size : nil,
        existingModifiedDate: p.has_existing_mtime ? Date(timeIntervalSince1970: TimeInterval(p.existing_mtime_sec)) : nil,
        newPath: p.new_path.map { String(cString: $0) } ?? "",
        newSize: p.has_new_size ? p.new_size : nil,
        newModifiedDate: p.has_new_mtime ? Date(timeIntervalSince1970: TimeInterval(p.new_mtime_sec)) : nil
    )
    return handler(conflict).cValue
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

        var actualInputs = inputPaths
        var actualBaseDir = baseDirectory
        var effectiveOptions = options
        var xattrStagingToClean: URL?

        if options.preserveMacExtendedAttributes {
            let staged = try MacMetadataPreserver.prepareStagingWithAppleDouble(
                inputPaths: inputPaths,
                baseDirectory: baseDirectory
            )
            xattrStagingToClean = staged.stagingRoot
            actualBaseDir = staged.stagingRoot
            actualInputs = staged.relativeInputPaths
            // Keep synthesized `._*` sidecars while still excluding `.DS_Store` if needed
            effectiveOptions.excludeMacOSMetadata = false
        }
        defer {
            if let stage = xattrStagingToClean {
                try? FileManager.default.removeItem(at: stage)
            }
        }

        let ctx = CallbackContext(progressHandler: progress)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let status: sz_status_t = withCStrings(actualInputs) { cInputArray in
            let formatC = effectiveOptions.format.flatMap { $0.isEmpty ? nil : strdup($0) }
            let methodC = effectiveOptions.method.flatMap { $0.isEmpty ? nil : strdup($0) }
            defer {
                if let formatC { free(formatC) }
                if let methodC { free(methodC) }
            }

            var cOpts = sz_update_options_t(
                format_name: formatC,
                method: methodC,
                compression_level: Int32(effectiveOptions.level),
                dictionary_size_kb: effectiveOptions.dictionarySizeKB,
                num_threads: Int32(effectiveOptions.threads),
                solid_block_bytes: effectiveOptions.solidBlockBytes,
                volume_bytes: effectiveOptions.splitVolumeBytes,
                encrypt_headers: effectiveOptions.encryptHeaders,
                store_symlinks: effectiveOptions.storeSymlinks,
                exclude_macos_metadata: effectiveOptions.excludeMacOSMetadata
            )

            return archiveURL.path.withCString { arcPathC in
                withOptionalCString(actualBaseDir?.path) { baseC in
                    withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
                        sz_archive_update(
                            arcPathC,
                            cInputArray,
                            UInt32(actualInputs.count),
                            baseC,
                            &cOpts,
                            pwdC,
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
                withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
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
                    withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
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
                }
            }
        }

        if status != SZ_STATUS_OK {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
    }

    public static func computeFileHashes(
        at fileURL: URL,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws -> [ArchiveHashDigest] {
        let ctx = CallbackContext(progressHandler: progress)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var rawDigests: UnsafeMutablePointer<sz_hash_digest_t>?
        var count: UInt32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?

        let status = fileURL.path.withCString { pathC in
            sz_compute_file_hashes(
                pathC,
                progress == nil ? nil : cProgressBridge,
                userData,
                &rawDigests,
                &count,
                &errPtr
            )
        }

        guard status == SZ_STATUS_OK else {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
        defer {
            if let rawDigests {
                sz_free_hashes(rawDigests, count)
            }
        }

        return decodeHashDigests(rawDigests, count: count)
    }

    fileprivate static func decodeHashDigests(
        _ rawDigests: UnsafeMutablePointer<sz_hash_digest_t>?,
        count: UInt32
    ) -> [ArchiveHashDigest] {
        guard let rawDigests, count > 0 else { return [] }
        let buf = UnsafeBufferPointer(start: rawDigests, count: Int(count))
        return buf.map { d in
            ArchiveHashDigest(
                algorithm: d.algorithm.map { String(cString: $0) } ?? "",
                hex: d.hex.map { String(cString: $0) } ?? ""
            )
        }
    }
}

// Ownership is transferred exactly once from a deinitializing OpenArchive to GCD.
private struct RetiredArchiveHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

public final class OpenArchive: @unchecked Sendable {
    public let url: URL
    public let encoding: ArchiveNameEncoding
    public let summary: ArchiveSummary
    public let entries: [ArchiveEntry]

    private let lock = NSLock()
    private var handle: OpaquePointer?

    public init(
        url: URL,
        password: String? = nil,
        encoding: ArchiveNameEncoding = .auto,
        passwordProvider: (() -> String?)? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        self.url = url
        self.encoding = encoding
        let ctx = CallbackContext(progressHandler: progress, passwordProvider: passwordProvider)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()

        var rawHandle: OpaquePointer?
        var errPtr: UnsafeMutablePointer<CChar>?

        let openStatus: sz_status_t = url.path.withCString { pathC in
            withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
                sz_archive_open_with_progress(
                    pathC,
                    pwdC,
                    encoding.rawValue,
                    passwordProvider == nil ? nil : cPasswordBridge,
                    progress == nil ? nil : cProgressBridge,
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
            self.entries = try Self.readEntries(handle: rawHandle, progress: progress)
        } catch {
            sz_archive_close(rawHandle)
            self.handle = nil
            throw error
        }
    }

    deinit {
        // The last reference owns this handle exclusively. Native teardown may free
        // a large metadata index; schedule it off the caller (often the main actor).
        if let handle {
            let retired = RetiredArchiveHandle(pointer: handle)
            DispatchQueue.global(qos: .utility).async { sz_archive_close(retired.pointer) }
        }
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
        restoreMacMetadata: Bool = true,
        password: String? = nil,
        passwordProvider: (() -> String?)? = nil,
        overwriteHandler: ((OverwriteConflict) -> OverwriteDecision)? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw ArchiveError.invalidArgument("Архив уже закрыт")
        }

        let ctx = CallbackContext(
            progressHandler: progress,
            passwordProvider: passwordProvider,
            overwriteHandler: overwriteHandler
        )
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var errPtr: UnsafeMutablePointer<CChar>?

        let cleanStrip = stripPrefix?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let stripToPass = (cleanStrip?.isEmpty == false) ? cleanStrip : nil

        // Derive metadata candidates from selected archive entries, never from a destination scan.
        // Ambiguous output mappings (unsafe paths, flattened collisions, rename-on-conflict)
        // are intentionally not restored.
        let selectedIndices = indices.flatMap { $0.isEmpty ? nil : Set($0) }
        var outputCounts: [String: Int] = [:]
        if restoreMacMetadata {
            for entry in entries where selectedIndices == nil || selectedIndices!.contains(entry.index) {
                guard !entry.isSymlink, var path = MacMetadataPreserver.safeRelativePath(entry.path) else { continue }
                if let stripToPass {
                    guard MacMetadataPreserver.safeRelativePath(stripToPass) != nil,
                          path.hasPrefix(stripToPass + "/") else { continue }
                    path.removeFirst(stripToPass.count + 1)
                }
                if !fullPaths {
                    guard !entry.isDirectory else { continue }
                    path = (path as NSString).lastPathComponent
                }
                outputCounts[path, default: 0] += 1
            }
        }
        let metadataPlan = MacMetadataPreserver.prepareRestoration(
            in: destinationDirectory,
            relativePaths: outputCounts.filter { $0.value == 1 }.map(\.key)
        )

        let status: sz_status_t = destinationDirectory.path.withCString { destC in
            withOptionalCString(stripToPass) { stripC in
                withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
                    let owCb: sz_overwrite_cb? = (overwrite == .askInteractive && overwriteHandler != nil)
                        ? cOverwriteBridge
                        : nil
                    if let indices, !indices.isEmpty {
                        return indices.withUnsafeBufferPointer { idxBuf in
                            sz_archive_extract_ex(
                                h,
                                idxBuf.baseAddress,
                                UInt32(idxBuf.count),
                                destC,
                                stripC,
                                fullPaths,
                                overwrite.cValue,
                                owCb,
                                pwdC,
                                passwordProvider == nil ? nil : cPasswordBridge,
                                progress == nil ? nil : cProgressBridge,
                                userData,
                                &errPtr
                            )
                        }
                    } else {
                        return sz_archive_extract_ex(
                            h,
                            nil,
                            0,
                            destC,
                            stripC,
                            fullPaths,
                            overwrite.cValue,
                            owCb,
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

        if restoreMacMetadata {
            MacMetadataPreserver.restoreAppleDoubleMetadata(in: destinationDirectory, plan: metadataPlan)
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

    public func computeEntryHashes(
        for index: UInt32,
        password: String? = nil,
        passwordProvider: (() -> String?)? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws -> [ArchiveHashDigest] {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw ArchiveError.invalidArgument("Архив уже закрыт")
        }

        let ctx = CallbackContext(progressHandler: progress, passwordProvider: passwordProvider)
        let userData = Unmanaged.passUnretained(ctx).toOpaque()
        var rawDigests: UnsafeMutablePointer<sz_hash_digest_t>?
        var count: UInt32 = 0
        var errPtr: UnsafeMutablePointer<CChar>?

        let status: sz_status_t = withOptionalCString(password?.isEmpty == false ? password : nil) { pwdC in
            sz_archive_compute_entry_hashes(
                h,
                index,
                pwdC,
                passwordProvider == nil ? nil : cPasswordBridge,
                progress == nil ? nil : cProgressBridge,
                userData,
                &rawDigests,
                &count,
                &errPtr
            )
        }

        guard status == SZ_STATUS_OK else {
            throw ArchiveError.from(status: status, errorPointer: errPtr)
        }
        defer {
            if let rawDigests {
                sz_free_hashes(rawDigests, count)
            }
        }

        return SevenZipEngine.decodeHashDigests(rawDigests, count: count)
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

    private static func readEntries(handle: OpaquePointer, progress: ((ArchiveProgress) -> Bool)?) throws -> [ArchiveEntry] {
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
            if let progress, !progress(ArchiveProgress(completedBytes: UInt64(result.count), totalBytes: UInt64(count), currentItem: nil)) {
                throw ArchiveError.cancelled
            }
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
