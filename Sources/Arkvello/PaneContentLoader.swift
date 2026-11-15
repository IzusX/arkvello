import ArchiveCore
import Foundation

extension CancellationFlag {
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Owns an immutable metadata snapshot and a separately locked engine handle.
/// Dropping a pane snapshot does not invalidate handles retained by other tasks.
final class PaneArchiveContent: Sendable {
    let archive: OpenArchive
    let tree: VirtualArchiveTree
    let temporaryDirectories: [PaneTemporaryDirectory]

    init(archive: OpenArchive, tree: VirtualArchiveTree, temporaryDirectories: [PaneTemporaryDirectory] = []) {
        self.archive = archive
        self.tree = tree
        self.temporaryDirectories = temporaryDirectories
    }
}

/// Tasks retain their workspace, so pane destruction cannot remove a directory
/// while extraction still writes into it. History retains successful extractions.
final class PaneTemporaryDirectory: Sendable {
    let url: URL
    let parent: PaneTemporaryDirectory?

    init(parent: PaneTemporaryDirectory? = nil) {
        self.parent = parent
        self.url = (parent?.url ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Arkvello-Nested-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        let url = url
        let parent = parent
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
            withExtendedLifetime(parent) {}
        }
    }
}

struct PaneLoadRequest: Sendable {
    let location: NavigationLocation
    let showHiddenFiles: Bool
    let isFlatView: Bool
    let isDeepSearch: Bool
    let filterText: String
    let encoding: ArchiveNameEncoding
    let password: String?
    let cachedArchive: PaneArchiveContent?
    let temporaryDirectories: [PaneTemporaryDirectory]
}

struct PaneLoadResult: Sendable {
    var items: [PaneRowItem]
    var archive: PaneArchiveContent? = nil
    var didOpenArchive = false
    var truncated = false
}

protocol PaneContentLoading: Sendable {
    func load(_ request: PaneLoadRequest, cancellation: CancellationFlag) throws -> PaneLoadResult
}

/// Blocking filesystem/7-Zip calls run on GCD workers, not the main actor or
/// Swift's cooperative executor. Cancelled slow I/O cannot queue ahead of a new location.
final class PaneLoadWorker: Sendable {
    private let queue = DispatchQueue(label: "io.github.izusx.arkvello.pane-load", qos: .userInitiated, attributes: .concurrent)

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

struct PaneContentLoader: PaneContentLoading {
    func load(_ request: PaneLoadRequest, cancellation: CancellationFlag) throws -> PaneLoadResult {
        defer { withExtendedLifetime(request.temporaryDirectories) {} }
        try cancellation.check()
        switch request.location {
        case .diskFolder(let url):
            return try loadDiskDirectory(url, request: request, cancellation: cancellation)
        case .archive(_, let layers, let subpath):
            guard let layer = layers.last else { throw ArchiveError.invalidArgument("Нет слоя архива") }
            let content: PaneArchiveContent
            let didOpen: Bool
            if let cached = request.cachedArchive,
               cached.archive.url.standardizedFileURL == layer.archiveFileURL.standardizedFileURL,
               cached.archive.encoding == request.encoding {
                content = cached
                didOpen = false
            } else {
                let password = request.password ?? KeychainPasswordStore.password(for: layer.archiveFileURL)
                try cancellation.check()
                let opened = try OpenArchive(url: layer.archiveFileURL, password: password, encoding: request.encoding,
                                             progress: { _ in !cancellation.isCancelled })
                try cancellation.check()
                let tree = try VirtualArchiveTree(entries: opened.entries, checkCancellation: cancellation.check)
                try cancellation.check()
                content = PaneArchiveContent(archive: opened, tree: tree, temporaryDirectories: request.temporaryDirectories)
                didOpen = true
            }
            let query = request.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
            var nodes: [VirtualArchiveNode]
            var truncated = false
            if request.isFlatView || (request.isDeepSearch && !query.isEmpty) {
                let matches = try content.tree.matchingNodes(under: subpath, query: query,
                    includeDirectories: !request.isFlatView, showHidden: request.showHiddenFiles,
                    limit: 8000, checkCancellation: cancellation.check)
                nodes = matches.nodes
                truncated = matches.truncated
            } else {
                nodes = content.tree.children(in: subpath)
                if !request.showHiddenFiles { nodes.removeAll { $0.name.hasPrefix(".") || $0.name == "__MACOSX" } }
            }
            var items: [PaneRowItem] = []
            for node in nodes {
                try cancellation.check()
                items.append(.archive(node))
            }
            return PaneLoadResult(items: items, archive: content, didOpenArchive: didOpen, truncated: truncated)
        }
    }

    static func extractNested(entry: ArchiveEntry, content: PaneArchiveContent, workspace: PaneTemporaryDirectory,
                              password: String?, cancellation: CancellationFlag) throws -> URL {
        try cancellation.check()
        try FileManager.default.createDirectory(at: workspace.url, withIntermediateDirectories: true)
        try content.archive.extract(indices: [entry.index], to: workspace.url, fullPaths: false,
                                    overwrite: .overwriteAll, password: password,
                                    progress: { _ in !cancellation.isCancelled })
        try cancellation.check()
        let url = workspace.url.appendingPathComponent(entry.name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveError.ioError("Не удалось извлечь вложенный архив \(entry.name)")
        }
        return url
    }
    private func loadDiskDirectory(_ folderURL: URL, request: PaneLoadRequest, cancellation: CancellationFlag) throws -> PaneLoadResult {
        do {
            try cancellation.check()
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            let keySet = Set(keys)
            let trimmedQuery = request.filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if request.isFlatView || (request.isDeepSearch && !trimmedQuery.isEmpty) {
                var items: [PaneRowItem] = []
                let opts: FileManager.DirectoryEnumerationOptions = request.showHiddenFiles ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]
                var enumerationError: Error?
                var truncated = false
                guard let enumerator = FileManager.default.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: keys,
                    options: opts,
                    errorHandler: { _, error in enumerationError = error; return false }
                ) else { throw ArchiveError.ioError("Не удалось прочитать папку") }
                do {
                    let prefixPath = folderURL.resolvingSymlinksInPath().path + "/"
                    for case let url as URL in enumerator {
                        try cancellation.check()
                        let vals = try? url.resourceValues(forKeys: keySet)
                        let isDir = vals?.isDirectory ?? false
                        if request.isFlatView && isDir { continue }

                        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
                        let fullResolved = resolvedParent.appendingPathComponent(url.lastPathComponent).path
                        let rel = fullResolved.hasPrefix(prefixPath)
                            ? String(fullResolved.dropFirst(prefixPath.count))
                            : url.lastPathComponent

                        if !trimmedQuery.isEmpty && !rel.lowercased().contains(trimmedQuery) {
                            continue
                        }
                        if items.count >= 8000 { truncated = true; break }
                        items.append(.disk(makeDiskEntryInfo(url: url, vals: vals, relativeDisplayPath: rel)))
                    }
                }
                if let enumerationError { throw enumerationError }
                return PaneLoadResult(items: items, truncated: truncated)
            }

            let options: FileManager.DirectoryEnumerationOptions = request.showHiddenFiles ? [] : [.skipsHiddenFiles]
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: options
            )

            var items: [PaneRowItem] = []
            items.reserveCapacity(contents.count)

            for url in contents {
                try cancellation.check()
                let vals = try? url.resourceValues(forKeys: keySet)
                items.append(.disk(makeDiskEntryInfo(url: url, vals: vals, relativeDisplayPath: nil)))
            }

            return PaneLoadResult(items: items)
        } catch {
            try cancellation.check()
            throw ArchiveError.ioError("Нет доступа к папке «\(folderURL.lastPathComponent)»: \(error.localizedDescription)")
        }
    }

    private func makeDiskEntryInfo(url: URL, vals: URLResourceValues?, relativeDisplayPath: String?) -> DiskEntryInfo {
        let isLink = vals?.isSymbolicLink ?? false
        var isDirObj: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObj)
        let isDir = exists ? isDirObj.boolValue : (vals?.isDirectory ?? false)

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let posixNum = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? (isDir ? 0o755 : 0o644)
        let permStr = ByteFormatting.posixPermissionString(mode: posixNum, isDir: isDir, isLink: isLink)

        return DiskEntryInfo(
            url: url,
            name: url.lastPathComponent,
            relativeDisplayPath: relativeDisplayPath,
            isDirectory: isDir,
            isSymlink: isLink,
            isArchiveContainer: !isDir && SevenZipEngine.isBrowsableArchive(url: url),
            size: isDir ? nil : vals?.fileSize.map { UInt64(max(0, $0)) },
            modifiedDate: vals?.contentModificationDate,
            posixAttributes: permStr
        )
    }
}
