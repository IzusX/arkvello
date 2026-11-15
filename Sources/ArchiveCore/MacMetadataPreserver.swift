import Darwin
import Foundation

/// Preserves and restores macOS extended attributes (`xattr`, Finder tags, custom icons, ACLs)
/// using Apple's native `<copyfile.h>` AppleDouble (`COPYFILE_PACK` / `COPYFILE_UNPACK`) format.
public enum MacMetadataPreserver {
    private static let appleDoubleMagic: [UInt8] = [0x00, 0x05, 0x16, 0x07]

    /// Returns true if `url` has at least one packable user/Finder extended attribute.
    public static func hasPackableExtendedAttributes(at url: URL) -> Bool {
        let size = url.path.withCString { cPath in
            listxattr(cPath, nil, 0, XATTR_NOFOLLOW)
        }
        guard size > 0 else { return false }

        var nameBuf = [CChar](repeating: 0, count: size)
        let readBytes = url.path.withCString { cPath in
            listxattr(cPath, &nameBuf, size, XATTR_NOFOLLOW)
        }
        guard readBytes > 0 else { return false }

        // Split NUL-delimited attribute names and ignore kernel-internal provenance marker
        let names = nameBuf.prefix(readBytes)
            .split(separator: 0)
            .compactMap { String(bytes: $0.map { UInt8(bitPattern: $0) }, encoding: .utf8) }

        let meaningful = names.filter { name in
            name != "com.apple.provenance" && name != "com.apple.macl"
        }
        return !meaningful.isEmpty
    }

    /// Creates a lightweight APFS CoW staging directory containing copies of `inputPaths` plus synthesized
    /// `._<name>` AppleDouble metadata files for any item carrying macOS extended attributes.
    public static func prepareStagingWithAppleDouble(
        inputPaths: [String],
        baseDirectory: URL?
    ) throws -> (stagingRoot: URL, relativeInputPaths: [String]) {
        let fm = FileManager.default
        guard let tempPath = realpath(fm.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(tempPath) }
        let stageRoot = URL(fileURLWithPath: String(cString: tempPath), isDirectory: true)
            .appendingPathComponent("Arkvello-XattrStage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        var completed = false
        defer {
            if !completed {
                do { try fm.removeItem(at: stageRoot) } catch { /* Preserve the original staging error. */ }
            }
        }
        var stagedRelPaths: [String] = []

        for rawInput in inputPaths {
            let sourceURL: URL
            let relPath: String
            if let baseDirectory {
                guard let cleanRel = safeRelativePath(rawInput) else {
                    throw ArchiveError.invalidArgument("Unsafe metadata input path: \(rawInput)")
                }
                sourceURL = baseDirectory.appendingPathComponent(cleanRel)
                relPath = cleanRel
            } else {
                sourceURL = URL(fileURLWithPath: rawInput)
                relPath = sourceURL.lastPathComponent
            }

            let stagedTarget = stageRoot.appendingPathComponent(relPath)
            try fm.createDirectory(
                at: stagedTarget.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: sourceURL, to: stagedTarget)
            stagedRelPaths.append(relPath)

            // Generate `._` AppleDouble sidecars recursively inside staged tree
            let topSidecar = try writeAppleDoubleIfNeeded(for: sourceURL, stagedCounterpart: stagedTarget)
            if let topSidecar {
                let parentRel = VirtualArchiveTree.parentPath(of: relPath) ?? ""
                let sidecarRel = parentRel.isEmpty ? topSidecar : "\(parentRel)/\(topSidecar)"
                stagedRelPaths.append(sidecarRel)
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: stagedTarget.path, isDirectory: &isDir), isDir.boolValue {
                try packDirectoryTreeXattrs(sourceRoot: sourceURL, stagedRoot: stagedTarget)
            }
        }

        completed = true
        return (stageRoot, stagedRelPaths)
    }

    private static func packDirectoryTreeXattrs(sourceRoot: URL, stagedRoot: URL) throws {
        let fm = FileManager.default
        let relSubpaths = try fm.subpathsOfDirectory(atPath: sourceRoot.path)

        for subRel in relSubpaths {
            let name = (subRel as NSString).lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" || subRel.hasPrefix("__MACOSX/") {
                continue
            }
            let srcItem = sourceRoot.appendingPathComponent(subRel)
            let stagedItem = stagedRoot.appendingPathComponent(subRel)
            _ = try writeAppleDoubleIfNeeded(for: srcItem, stagedCounterpart: stagedItem)
        }
    }

    @discardableResult
    private static func writeAppleDoubleIfNeeded(for sourceURL: URL, stagedCounterpart: URL) throws -> String? {
        // Never pack metadata through a symbolic link, including an ancestor.
        guard noSymlinkComponents(sourceURL), noSymlinkComponents(stagedCounterpart),
              hasPackableExtendedAttributes(at: sourceURL) else { return nil }
        let sidecarName = "._\(stagedCounterpart.lastPathComponent)"
        let sidecarURL = stagedCounterpart.deletingLastPathComponent().appendingPathComponent(sidecarName)

        let sourceSidecar = sourceURL.deletingLastPathComponent().appendingPathComponent(sidecarName)
        guard !existsWithoutFollowingLinks(sidecarURL), !existsWithoutFollowingLinks(sourceSidecar) else {
            throw ArchiveError.invalidArgument("AppleDouble sidecar collision: \(sidecarName)")
        }
        let rc = sourceURL.path.withCString { srcC in
            sidecarURL.path.withCString { dstC in
                copyfile(srcC, dstC, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_METADATA | COPYFILE_EXCL | COPYFILE_NOFOLLOW))
            }
        }
        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return sidecarName
    }

    struct FileSignature: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            mode = info.st_mode
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// A pre-extraction allowlist, not a recursive snapshot of the destination.
    struct RestorationPlan {
        let paths: Set<String>
        let absentBefore: Set<String>
    }

    static func prepareRestoration(in root: URL, relativePaths: [String]) -> RestorationPlan {
        let paths = Set(relativePaths.compactMap(safeRelativePath))
        let absent = paths.filter { path in
            let url = root.appendingPathComponent(path)
            // ENOENT alone is safe; permission errors and symlinks are not absence.
            guard noSymlinkComponents(url) else { return false }
            var info = stat()
            return lstat(url.path, &info) != 0 && errno == ENOENT
        }
        return RestorationPlan(paths: paths, absentBefore: Set(absent))
    }

    /// Restore only selected outputs that did not exist before extraction. Existing pairs are
    /// deliberately skipped even if overwritten: an overwrite/rename callback is not write proof.
    static func restoreAppleDoubleMetadata(in root: URL, plan: RestorationPlan) {
        let after = Dictionary(uniqueKeysWithValues: plan.absentBefore.compactMap { path in
            signature(root.appendingPathComponent(path)).map { (path, $0) }
        })
        for sidecarPath in plan.paths.sorted() {
            let name = (sidecarPath as NSString).lastPathComponent
            guard name.hasPrefix("._"), name.count > 2 else { continue }
            var companion = (sidecarPath as NSString).deletingLastPathComponent
            companion = companion.isEmpty ? String(name.dropFirst(2)) : companion + "/" + name.dropFirst(2)
            if companion.hasPrefix("__MACOSX/") { companion.removeFirst("__MACOSX/".count) }
            guard plan.paths.contains(companion), let sideSignature = after[sidecarPath],
                  let targetSignature = after[companion], sideSignature.mode & S_IFMT == S_IFREG,
                  targetSignature.mode & S_IFMT == S_IFREG || targetSignature.mode & S_IFMT == S_IFDIR else { continue }
            let sidecar = root.appendingPathComponent(sidecarPath)
            let target = root.appendingPathComponent(companion)
            guard signature(sidecar) == sideSignature, signature(target) == targetSignature else { continue }
            let sourceFD = openWithoutFollowingLinks(sidecar)
            guard sourceFD >= 0 else { continue }
            defer { close(sourceFD) }
            let targetFD = openWithoutFollowingLinks(target)
            guard targetFD >= 0 else { continue }
            defer { close(targetFD) }
            var sourceInfo = stat()
            var targetInfo = stat()
            guard fstat(sourceFD, &sourceInfo) == 0, fstat(targetFD, &targetInfo) == 0,
                  FileSignature(sourceInfo) == sideSignature, FileSignature(targetInfo) == targetSignature,
                  noSymlinkComponents(sidecar), noSymlinkComponents(target) else { continue }
            var magic = [UInt8](repeating: 0, count: 4)
            guard pread(sourceFD, &magic, 4, 0) == 4, magic == appleDoubleMagic else { continue }
            guard fcopyfile(sourceFD, targetFD, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_METADATA)) == 0 else { continue }
            if signature(sidecar) == sideSignature {
                _ = unlink(sidecar.path)
                // rmdir is nonrecursive and cannot remove user files, even in __MACOSX.
                var parent = sidecar.deletingLastPathComponent()
                while parent.path != root.path, parent.path.hasPrefix(root.path + "/"), noSymlinkComponents(parent) {
                    guard rmdir(parent.path) == 0 else { break }
                    parent.deleteLastPathComponent()
                }
            }
        }
    }

    static func safeRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }

    private static func existsWithoutFollowingLinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }

    private static func signature(_ url: URL) -> FileSignature? {
        guard noSymlinkComponents(url) else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        return FileSignature(info)
    }

    /// Walk every ancestor with openat: O_NOFOLLOW on the leaf alone is insufficient.
    private static func openWithoutFollowingLinks(_ url: URL) -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return -1 }
        let parts = Array(url.pathComponents.dropFirst())
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | (index < parts.count - 1 ? O_DIRECTORY : 0)
            let next = openat(descriptor, part, flags)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func noSymlinkComponents(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.pathComponents.dropFirst() {
            current.appendPathComponent(part)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFLNK { return false }
            } else if errno == ENOENT {
                return true
            } else {
                return false
            }
        }
        return true
    }
}
