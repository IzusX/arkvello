import AppKit
import ArchiveCore
import Foundation

@MainActor
final class PaneViewModel: ObservableObject {
    let side: PaneSide

    @Published private(set) var location: NavigationLocation
    @Published private(set) var tabs: [PaneTabItem]
    @Published private(set) var activeTabID: UUID
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
    @Published var isFlatView: Bool = false {
        didSet { reloadCurrentLocation() }
    }
    @Published var isDeepSearch: Bool = true {
        didSet { reloadCurrentLocation() }
    }
    @Published var filterText: String = "" {
        didSet {
            if isDeepSearch && location.isInsideArchive {
                reloadCurrentLocation()
            } else if isDeepSearch && !location.isInsideArchive {
                reloadCurrentLocation()
            } else {
                rebuildDisplayedRows()
            }
        }
    }
    @Published var archiveEncoding: ArchiveNameEncoding = .auto {
        didSet {
            if oldValue != archiveEncoding && location.isInsideArchive {
                reloadCurrentLocation(forceReopenArchive: true)
            }
        }
    }
    @Published var searchFieldFocusTrigger: Int = 0
    @Published private(set) var errorBanner: String?
    @Published private(set) var openArchive: OpenArchive?
    @Published private(set) var archiveTree: VirtualArchiveTree?

    private var rawItems: [PaneRowItem] = []
    private var backStack: [NavigationLocation] = []
    private var forwardStack: [NavigationLocation] = []
    private var cachedArchiveURL: URL?
    private var cachedArchiveEncoding: ArchiveNameEncoding = .auto
    private var passwordsByPath: [String: String] = [:]
    private let nestedCacheRoot: URL

    var onRequestPassword: ((URL, Bool, @escaping (String?) -> Void) -> Void)?
    var onArchiveOpened: ((URL) -> Void)?
    var onLocationChanged: (() -> Void)?

    init(side: PaneSide, initialFolder: URL) {
        self.side = side
        let startLoc = NavigationLocation.diskFolder(initialFolder.standardizedFileURL)
        self.location = startLoc
        let firstTab = PaneTabItem(id: UUID(), location: startLoc, backStack: [], forwardStack: [])
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
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

    var isShowingFlattenedPaths: Bool {
        isFlatView || (isDeepSearch && !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var activeArchiveSummary: ArchiveSummary? {
        guard location.isInsideArchive else { return nil }
        return openArchive?.summary
    }

    var currentArchivePassword: String? {
        guard let url = location.activeArchiveLayer?.archiveFileURL.standardizedFileURL else { return nil }
        if let mem = passwordsByPath[url.path], !mem.isEmpty {
            return mem
        }
        if let kc = KeychainPasswordStore.password(for: url) {
            passwordsByPath[url.path] = kc
            return kc
        }
        return nil
    }

    func storePassword(_ password: String, for archiveURL: URL, saveToKeychain: Bool = false) {
        let std = archiveURL.standardizedFileURL
        passwordsByPath[std.path] = password
        if saveToKeychain {
            KeychainPasswordStore.savePassword(password, for: std)
        }
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

    // MARK: - Tabs Management (`⌘T` / `⌘W`)

    func openNewTab(at targetLocation: NavigationLocation? = nil) {
        syncActiveTabSnapshot()
        let loc = targetLocation ?? location
        let newTab = PaneTabItem(id: UUID(), location: loc, backStack: [], forwardStack: [])
        tabs.append(newTab)
        selectTab(newTab.id)
    }

    /// Closes the specified tab (or active tab if nil). Returns true if a tab was closed, false if only 1 tab remained.
    @discardableResult
    func closeTab(id: UUID? = nil) -> Bool {
        guard tabs.count > 1 else { return false }
        let targetID = id ?? activeTabID
        guard let idx = tabs.firstIndex(where: { $0.id == targetID }) else { return false }
        let wasActive = (targetID == activeTabID)
        tabs.remove(at: idx)
        if wasActive {
            let nextIdx = min(idx, tabs.count - 1)
            let nextTab = tabs[nextIdx]
            activeTabID = nextTab.id
            location = nextTab.location
            backStack = nextTab.backStack
            forwardStack = nextTab.forwardStack
            loadLocation(highlightName: nil)
        }
        onLocationChanged?()
        return true
    }

    func selectTab(_ id: UUID) {
        guard id != activeTabID, let target = tabs.first(where: { $0.id == id }) else { return }
        syncActiveTabSnapshot()
        activeTabID = target.id
        location = target.location
        backStack = target.backStack
        forwardStack = target.forwardStack
        errorBanner = nil
        loadLocation(highlightName: nil)
        onLocationChanged?()
    }

    func restorePersistedTabs(paths: [String], activeIndex: Int) {
        let validLocations: [NavigationLocation] = paths.compactMap { raw in
            let url = URL(fileURLWithPath: raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                return .diskFolder(url.standardizedFileURL)
            } else if SevenZipEngine.isBrowsableArchive(url: url) {
                return NavigationLocation.diskFolder(url.deletingLastPathComponent()).enteringArchiveOnDisk(url)
            }
            return nil
        }
        guard !validLocations.isEmpty else { return }
        tabs = validLocations.map { PaneTabItem(id: UUID(), location: $0, backStack: [], forwardStack: []) }
        let clamped = max(0, min(activeIndex, tabs.count - 1))
        activeTabID = tabs[clamped].id
        location = tabs[clamped].location
        backStack = []
        forwardStack = []
        loadLocation(highlightName: nil)
    }

    var persistableTabPaths: (paths: [String], activeIndex: Int) {
        syncActiveTabSnapshot()
        let paths: [String] = tabs.map { tab in
            switch tab.location {
            case .diskFolder(let url):
                return url.path
            case .archive(let rootDisk, let layers, _):
                if let first = layers.first, !first.isTemporaryNestedFile {
                    return first.archiveFileURL.path
                }
                return rootDisk.path
            }
        }
        let idx = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        return (paths, idx)
    }

    private func syncActiveTabSnapshot() {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs[idx].location = location
        tabs[idx].backStack = backStack
        tabs[idx].forwardStack = forwardStack
    }

    // MARK: - Navigation

    func navigate(to newLocation: NavigationLocation, highlightItemNamed highlightName: String? = nil, recordHistory: Bool = true) {
        if recordHistory && newLocation != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = newLocation
        syncActiveTabSnapshot()
        errorBanner = nil
        loadLocation(highlightName: highlightName)
        onLocationChanged?()
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(location)
        location = prev
        syncActiveTabSnapshot()
        loadLocation(highlightName: nil)
        onLocationChanged?()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        location = next
        syncActiveTabSnapshot()
        loadLocation(highlightName: nil)
        onLocationChanged?()
    }

    func goUp() {
        guard let (dest, highlight) = location.goingUp() else { return }
        navigate(to: dest, highlightItemNamed: highlight)
    }

    func focusSearch(enableDeepSearch: Bool) {
        if enableDeepSearch {
            isDeepSearch = true
        }
        searchFieldFocusTrigger &+= 1
    }

    func revealContainingFolder(for row: PaneRowItem) {
        switch row {
        case .parentDirectory:
            break
        case .disk(let d):
            isFlatView = false
            filterText = ""
            navigate(to: .diskFolder(d.url.deletingLastPathComponent()), highlightItemNamed: d.name)
        case .archive(let node):
            isFlatView = false
            filterText = ""
            let parentSub = node.parentFolderPath
            navigate(to: location.enteringArchiveSubfolder(parentSub), highlightItemNamed: node.name)
        }
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
        guard let arcURL = location.activeArchiveLayer?.archiveFileURL.standardizedFileURL else {
            completion(false)
            return
        }
        if wrongAttempt {
            passwordsByPath.removeValue(forKey: arcURL.path)
            KeychainPasswordStore.removePassword(for: arcURL)
        }
        onRequestPassword?(arcURL, wrongAttempt) { [weak self] supplied in
            guard let self else { return }
            if let supplied, !supplied.isEmpty {
                self.passwordsByPath[arcURL.path] = supplied
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
        syncActiveTabSnapshot()
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
            let trimmedQuery = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if isFlatView || (isDeepSearch && !trimmedQuery.isEmpty) {
                var items: [PaneRowItem] = []
                let opts: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]
                if let enumerator = FileManager.default.enumerator(
                    at: folderURL,
                    includingPropertiesForKeys: keys,
                    options: opts
                ) {
                    let prefixPath = folderURL.resolvingSymlinksInPath().path + "/"
                    var count = 0
                    for case let url as URL in enumerator {
                        if count >= 8000 { break }
                        let vals = try? url.resourceValues(forKeys: Set(keys))
                        let isDir = vals?.isDirectory ?? false
                        if isFlatView && isDir { continue }

                        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
                        let fullResolved = resolvedParent.appendingPathComponent(url.lastPathComponent).path
                        let rel = fullResolved.hasPrefix(prefixPath)
                            ? String(fullResolved.dropFirst(prefixPath.count))
                            : url.lastPathComponent

                        if !trimmedQuery.isEmpty && !rel.lowercased().contains(trimmedQuery) {
                            continue
                        }
                        count += 1
                        items.append(.disk(makeDiskEntryInfo(url: url, vals: vals, relativeDisplayPath: rel)))
                    }
                }
                rawItems = items
                errorBanner = nil
                rebuildDisplayedRows(highlightName: highlightName)
                return
            }

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
                items.append(.disk(makeDiskEntryInfo(url: url, vals: vals, relativeDisplayPath: nil)))
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

    private func loadArchiveDirectory(layer: ArchiveLayer, subpath: String, highlightName: String?) {
        let arcURL = layer.archiveFileURL.standardizedFileURL

        if cachedArchiveURL != arcURL || cachedArchiveEncoding != archiveEncoding || openArchive == nil || archiveTree == nil {
            let pwd = currentArchivePassword
            do {
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: archiveEncoding)
                openArchive?.close()
                openArchive = opened
                archiveTree = VirtualArchiveTree(entries: opened.entries)
                cachedArchiveURL = arcURL
                cachedArchiveEncoding = archiveEncoding
                if !layer.isTemporaryNestedFile {
                    onArchiveOpened?(arcURL)
                }
            } catch let err as ArchiveError where err == .passwordRequired || err == .wrongPassword {
                if err == .wrongPassword {
                    passwordsByPath.removeValue(forKey: arcURL.path)
                    KeychainPasswordStore.removePassword(for: arcURL)
                }
                onRequestPassword?(arcURL, err == .wrongPassword) { [weak self] supplied in
                    guard let self else { return }
                    if let supplied, !supplied.isEmpty {
                        self.passwordsByPath[arcURL.path] = supplied
                        self.loadArchiveDirectory(layer: layer, subpath: subpath, highlightName: highlightName)
                    } else if let prev = self.backStack.popLast() {
                        self.location = prev
                        self.syncActiveTabSnapshot()
                        self.loadLocation(highlightName: arcURL.lastPathComponent)
                    } else {
                        self.location = .diskFolder(arcURL.deletingLastPathComponent())
                        self.syncActiveTabSnapshot()
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
        let trimmedQuery = filterText.trimmingCharacters(in: .whitespacesAndNewlines)

        let nodes: [VirtualArchiveNode]
        if isDeepSearch && !trimmedQuery.isEmpty {
            nodes = tree.search(query: trimmedQuery, under: subpath, includeDirectories: !isFlatView)
        } else if isFlatView {
            nodes = tree.flatNodes(under: subpath, includeDirectories: false)
        } else {
            nodes = tree.children(in: subpath)
        }

        let filteredHidden = showHiddenFiles ? nodes : nodes.filter { !$0.name.hasPrefix(".") && $0.name != "__MACOSX" }
        rawItems = filteredHidden.map { .archive($0) }
        errorBanner = nil
        rebuildDisplayedRows(highlightName: highlightName)
    }

    private func rebuildDisplayedRows(highlightName: String? = nil) {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var working = rawItems
        if !query.isEmpty && !isDeepSearch {
            working = working.filter { $0.name.lowercased().contains(query) }
        }

        let showRel = isShowingFlattenedPaths
        let stripSub = location.archiveSubpath

        working.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let cmp = compareItems(lhs, rhs, by: sortField, showRelativePath: showRel, stripPrefix: stripSub)
            if cmp == .orderedSame {
                return lhs.displayLabel(showRelativePath: showRel, stripPrefix: stripSub)
                    .localizedStandardCompare(rhs.displayLabel(showRelativePath: showRel, stripPrefix: stripSub)) == .orderedAscending
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

    private func compareItems(
        _ a: PaneRowItem,
        _ b: PaneRowItem,
        by field: SortField,
        showRelativePath: Bool,
        stripPrefix: String
    ) -> ComparisonResult {
        switch field {
        case .name:
            return a.displayLabel(showRelativePath: showRelativePath, stripPrefix: stripPrefix)
                .localizedStandardCompare(b.displayLabel(showRelativePath: showRelativePath, stripPrefix: stripPrefix))
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
