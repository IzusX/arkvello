import AppKit
import ArchiveCore
import Foundation

@MainActor
final class PaneViewModel: ObservableObject {
    let side: PaneSide

    @Published private(set) var location: NavigationLocation
    @Published private(set) var rows: [PaneRowItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var sortField: SortField = .name {
        didSet { rebuildDisplayedRows() }
    }
    @Published var sortAscending: Bool = true {
        didSet { rebuildDisplayedRows() }
    }
    @Published var showHiddenFiles: Bool = false {
        didSet { reloadCurrentLocation() }
    }
    @Published var filterText: String = "" {
        didSet { rebuildDisplayedRows() }
    }
    @Published private(set) var errorBanner: String?
    @Published private(set) var openArchive: OpenArchive?
    @Published private(set) var archiveTree: VirtualArchiveTree?

    private var rawItems: [PaneRowItem] = []
    private var backStack: [NavigationLocation] = []
    private var forwardStack: [NavigationLocation] = []
    private var cachedArchiveURL: URL?
    private var passwordsByPath: [String: String] = [:]
    private let nestedCacheRoot: URL

    var onRequestPassword: ((URL, Bool, @escaping (String?) -> Void) -> Void)?
    var onArchiveOpened: ((URL) -> Void)?

    init(side: PaneSide, initialFolder: URL) {
        self.side = side
        self.location = .diskFolder(initialFolder.standardizedFileURL)
        self.nestedCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipMac-Nested-\(UUID().uuidString)", isDirectory: true)
        reloadCurrentLocation()
    }

    deinit {
        try? FileManager.default.removeItem(at: nestedCacheRoot)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { location.goingUp() != nil }

    var activeArchiveSummary: ArchiveSummary? {
        guard location.isInsideArchive else { return nil }
        return openArchive?.summary
    }

    var currentArchivePassword: String? {
        guard let url = location.activeArchiveLayer?.archiveFileURL else { return nil }
        return passwordsByPath[url.path]
    }

    func storePassword(_ password: String, for archiveURL: URL) {
        passwordsByPath[archiveURL.standardizedFileURL.path] = password
    }

    var selectedActionableRows: [PaneRowItem] {
        rows.filter { !$0.isParentRow && selectedIDs.contains($0.id) }
    }

    var statusSummaryText: String {
        let actionable = rows.filter { !$0.isParentRow }
        let folderCount = actionable.filter(\.isDirectory).count
        let fileCount = actionable.count - folderCount
        let totalSize = actionable.reduce(UInt64(0)) { $0 &+ ($1.size ?? 0) }

        let selected = selectedActionableRows
        if selected.isEmpty {
            return "Папок: \(folderCount) · Файлов: \(fileCount) · \(ByteFormatting.string(for: totalSize))"
        } else {
            let selBytes = selected.reduce(UInt64(0)) { $0 &+ ($1.size ?? 0) }
            return "Выбрано: \(selected.count) из \(actionable.count) (\(ByteFormatting.string(for: selBytes)))"
        }
    }

    func navigate(to newLocation: NavigationLocation, highlightItemNamed highlightName: String? = nil, recordHistory: Bool = true) {
        if recordHistory && newLocation != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = newLocation
        errorBanner = nil
        loadLocation(highlightName: highlightName)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(location)
        location = prev
        loadLocation(highlightName: nil)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        location = next
        loadLocation(highlightName: nil)
    }

    func goUp() {
        guard let (dest, highlight) = location.goingUp() else { return }
        navigate(to: dest, highlightItemNamed: highlight)
    }

    func reloadCurrentLocation(forceReopenArchive: Bool = false) {
        if forceReopenArchive {
            openArchive?.close()
            openArchive = nil
            archiveTree = nil
            cachedArchiveURL = nil
        }
        loadLocation(highlightName: nil)
    }

    func openArchiveFile(_ archiveURL: URL) {
        let target = location.enteringArchiveOnDisk(archiveURL)
        navigate(to: target)
    }

    func enterNestedArchive(node: VirtualArchiveNode) {
        guard let arc = openArchive, let entry = node.entry, !node.isDirectory else { return }
        do {
            let slot = nestedCacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            try arc.extract(
                indices: [entry.index],
                to: slot,
                stripPrefix: nil,
                fullPaths: false,
                overwrite: .overwriteAll,
                password: currentArchivePassword
            )
            let extractedURL = slot.appendingPathComponent(entry.name)
            guard FileManager.default.fileExists(atPath: extractedURL.path) else {
                errorBanner = "Не удалось извлечь вложенный архив \(entry.name)"
                return
            }
            let nextLoc = location.enteringNestedArchive(extractedTempURL: extractedURL, displayName: entry.name)
            navigate(to: nextLoc)
        } catch let err as ArchiveError where err == .passwordRequired || err == .wrongPassword {
            requestPasswordForCurrentArchive(wrongAttempt: err == .wrongPassword) { [weak self] ok in
                if ok { self?.enterNestedArchive(node: node) }
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func requestPasswordForCurrentArchive(wrongAttempt: Bool, completion: @escaping (Bool) -> Void) {
        guard let arcURL = location.activeArchiveLayer?.archiveFileURL else {
            completion(false)
            return
        }
        onRequestPassword?(arcURL, wrongAttempt) { [weak self] supplied in
            guard let self else { return }
            if let supplied, !supplied.isEmpty {
                self.storePassword(supplied, for: arcURL)
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    func toggleSort(by field: SortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = (field == .name || field == .attributes || field == .method || field == .crc)
        }
    }

    // MARK: - Loading

    private func loadLocation(highlightName: String?) {
        switch location {
        case .diskFolder(let dirURL):
            openArchive?.close()
            openArchive = nil
            archiveTree = nil
            cachedArchiveURL = nil
            loadDiskDirectory(dirURL, highlightName: highlightName)

        case .archive(_, let layers, let subpath):
            guard let activeLayer = layers.last else { return }
            loadArchiveDirectory(layer: activeLayer, subpath: subpath, highlightName: highlightName)
        }
    }

    private func loadDiskDirectory(_ folderURL: URL, highlightName: String?) {
        do {
            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
            let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: options
            )

            var items: [PaneRowItem] = []
            items.reserveCapacity(contents.count)

            for url in contents {
                let vals = try? url.resourceValues(forKeys: Set(keys))
                let isLink = vals?.isSymbolicLink ?? false
                var isDirObj: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObj)
                let isDir = exists ? isDirObj.boolValue : (vals?.isDirectory ?? false)

                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let posixNum = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? (isDir ? 0o755 : 0o644)
                let permStr = ByteFormatting.posixPermissionString(mode: posixNum, isDir: isDir, isLink: isLink)

                let info = DiskEntryInfo(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    isArchiveContainer: !isDir && SevenZipEngine.isBrowsableArchive(url: url),
                    size: isDir ? nil : vals?.fileSize.map { UInt64(max(0, $0)) },
                    modifiedDate: vals?.contentModificationDate,
                    posixAttributes: permStr
                )
                items.append(.disk(info))
            }

            rawItems = items
            errorBanner = nil
            rebuildDisplayedRows(highlightName: highlightName)
        } catch {
            rawItems = []
            rows = canGoUp ? [.parentDirectory] : []
            errorBanner = "Нет доступа к папке «\(folderURL.lastPathComponent)»: \(error.localizedDescription)"
        }
    }

    private func loadArchiveDirectory(layer: ArchiveLayer, subpath: String, highlightName: String?) {
        let arcURL = layer.archiveFileURL.standardizedFileURL

        if cachedArchiveURL != arcURL || openArchive == nil || archiveTree == nil {
            let pwd = passwordsByPath[arcURL.path]
            do {
                let opened = try OpenArchive(url: arcURL, password: pwd)
                openArchive?.close()
                openArchive = opened
                archiveTree = VirtualArchiveTree(entries: opened.entries)
                cachedArchiveURL = arcURL
                if !layer.isTemporaryNestedFile {
                    onArchiveOpened?(arcURL)
                }
            } catch let err as ArchiveError where err == .passwordRequired || err == .wrongPassword {
                onRequestPassword?(arcURL, err == .wrongPassword) { [weak self] supplied in
                    guard let self else { return }
                    if let supplied, !supplied.isEmpty {
                        self.storePassword(supplied, for: arcURL)
                        self.loadArchiveDirectory(layer: layer, subpath: subpath, highlightName: highlightName)
                    } else if let prev = self.backStack.popLast() {
                        self.location = prev
                        self.loadLocation(highlightName: arcURL.lastPathComponent)
                    } else {
                        self.location = .diskFolder(arcURL.deletingLastPathComponent())
                        self.loadLocation(highlightName: arcURL.lastPathComponent)
                    }
                }
                return
            } catch {
                errorBanner = error.localizedDescription
                rawItems = []
                rows = canGoUp ? [.parentDirectory] : []
                return
            }
        }

        guard let tree = archiveTree else { return }
        let nodes = tree.children(in: subpath)
        let filteredHidden = showHiddenFiles ? nodes : nodes.filter { !$0.name.hasPrefix(".") }
        rawItems = filteredHidden.map { .archive($0) }
        errorBanner = nil
        rebuildDisplayedRows(highlightName: highlightName)
    }

    private func rebuildDisplayedRows(highlightName: String? = nil) {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var working = rawItems
        if !query.isEmpty {
            working = working.filter { $0.name.lowercased().contains(query) }
        }

        working.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let cmp = compareItems(lhs, rhs, by: sortField)
            if cmp == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }

        var finalRows: [PaneRowItem] = []
        if canGoUp {
            finalRows.append(.parentDirectory)
        }
        finalRows.append(contentsOf: working)
        rows = finalRows

        if let highlightName,
           let matched = finalRows.first(where: { !$0.isParentRow && $0.name == highlightName }) {
            selectedIDs = [matched.id]
        } else {
            selectedIDs = selectedIDs.intersection(Set(finalRows.map(\.id)))
        }
    }

    private func compareItems(_ a: PaneRowItem, _ b: PaneRowItem, by field: SortField) -> ComparisonResult {
        switch field {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .size:
            let sa = a.size ?? 0
            let sb = b.size ?? 0
            return sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
        case .packedSize:
            let pa = a.packedSize ?? 0
            let pb = b.packedSize ?? 0
            return pa == pb ? .orderedSame : (pa < pb ? .orderedAscending : .orderedDescending)
        case .modified:
            let da = a.modifiedDate ?? .distantPast
            let db = b.modifiedDate ?? .distantPast
            return da == db ? .orderedSame : (da < db ? .orderedAscending : .orderedDescending)
        case .attributes:
            return a.attributes.compare(b.attributes)
        case .crc:
            return a.crcHex.compare(b.crcHex)
        case .method:
            return a.method.localizedStandardCompare(b.method)
        }
    }
}
