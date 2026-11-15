import AppKit
import ArchiveCore
import Foundation

@MainActor
final class PaneViewModel: ObservableObject {
    let side: PaneSide

    @Published private(set) var location: NavigationLocation
    @Published private(set) var tabs: [PaneTabItem]
    @Published private(set) var activeTabID: UUID
    @Published private(set) var rows: [PaneRowItem] = [] { didSet { rowsRevision &+= 1 } }
    private(set) var rowsRevision: UInt64 = 0
    private var presentation: PanePresentation?
    @Published private(set) var resultsTruncated = false
    private var displayTask: Task<Void, Never>?
    private var displayCancellation: CancellationFlag?
    private var displayID = UUID()
    @Published var selectedIDs: Set<String> = [] { didSet { updateSelectionSummary() } }
    private var selectedCount = 0
    private var selectedBytes: UInt64 = 0
    @Published var sortField: SortField = .name {
        didSet { rebuildDisplayedRows() }
    }
    @Published var sortAscending: Bool = true {
        didSet { rebuildDisplayedRows() }
    }
    @Published var showHiddenFiles: Bool = false {
        didSet { if oldValue != showHiddenFiles { reloadCurrentLocation() } }
    }
    @Published var isFlatView: Bool = false {
        didSet { if oldValue != isFlatView { reloadCurrentLocation() } }
    }
    @Published var isDeepSearch: Bool = true {
        didSet { if oldValue != isDeepSearch { reloadCurrentLocation() } }
    }
    @Published var filterText: String = "" {
        didSet {
            guard oldValue != filterText else { return }
            scheduleSearch()
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
    @Published private(set) var isLoading = false
    @Published private var archiveContent: PaneArchiveContent?
    var retainedArchiveContent: PaneArchiveContent? { archiveContent }
    var rowIndexByID: [String: Int] { presentation?.indexByID ?? [:] }
    var openArchive: OpenArchive? { isLoading ? nil : archiveContent?.archive }
    var archiveTree: VirtualArchiveTree? { isLoading ? nil : archiveContent?.tree }

    private var rawItems: [PaneRowItem] = []
    private var backStack: [NavigationLocation] = []
    private var forwardStack: [NavigationLocation] = []
    private var passwordsByPath: [String: String] = [:]
    private let nestedWorkspace = PaneTemporaryDirectory()
    private var nestedFiles: [URL: PaneTemporaryDirectory] = [:]
    private let loader: any PaneContentLoading
    private let worker = PaneLoadWorker()
    private(set) var loadingTask: Task<Void, Never>?
    private var loadCancellation: CancellationFlag?
    private var loadID = UUID()
    private var pendingPasswordURL: URL?
    var onCancelPasswordRequest: ((URL) -> Void)?

    var onRequestPassword: ((URL, Bool, @escaping (String?) -> Void) -> Void)?
    var onArchiveOpened: ((URL) -> Void)?
    var onLocationChanged: (() -> Void)?

    init(side: PaneSide, initialFolder: URL, loader: any PaneContentLoading = PaneContentLoader()) {
        self.loader = loader
        self.side = side
        let startLoc = NavigationLocation.diskFolder(initialFolder.standardizedFileURL)
        self.location = startLoc
        let firstTab = PaneTabItem(id: UUID(), location: startLoc, backStack: [], forwardStack: [])
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
        reloadCurrentLocation()
    }

    deinit {
        loadCancellation?.cancel()
        loadingTask?.cancel()
        displayTask?.cancel()
        displayCancellation?.cancel()
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

    var isNestedArchive: Bool {
        if case .archive(_, let layers, _) = location { return layers.count > 1 }
        return false
    }

    var canModifyArchive: Bool { !isNestedArchive && activeArchiveSummary?.isUpdatable == true }

    var currentArchivePassword: String? {
        guard let url = location.activeArchiveLayer?.archiveFileURL else { return nil }
        return password(for: url)
    }

    func password(for archiveURL: URL) -> String? {
        let url = archiveURL.standardizedFileURL
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
        selectedIDs.compactMap { presentation?.byID[$0] }.sorted { (rowIndexByID[$0.id] ?? 0) < (rowIndexByID[$1.id] ?? 0) }
    }

    var statusSummaryText: String {
        if isLoading { return "Загрузка…" }
        guard let presentation else { return "Нет объектов" }
        let suffix = resultsTruncated ? " · Показаны первые 8000 совпадений; уточните поиск" : ""
        if selectedCount == 0 {
            return "Папок: \(presentation.folderCount) · Файлов: \(presentation.fileCount) · \(ByteFormatting.string(for: presentation.totalSize))" + suffix
        }
        return "Выбрано: \(selectedCount) из \(presentation.byID.count) (\(ByteFormatting.string(for: selectedBytes)))" + suffix
    }

    private func updateSelectionSummary() {
        selectedCount = 0
        selectedBytes = 0
        for id in selectedIDs {
            if let item = presentation?.byID[id] {
                selectedCount += 1
                selectedBytes &+= item.size ?? 0
            }
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
        pruneNestedFiles()
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

    func reloadCurrentLocation(forceReopenArchive: Bool = false, highlightItemNamed: String? = nil) {
        if forceReopenArchive { archiveContent = nil }
        loadLocation(highlightName: highlightItemNamed)
    }

    func openArchiveFile(_ archiveURL: URL) {
        navigate(to: location.enteringArchiveOnDisk(archiveURL))
    }

    func enterNestedArchive(node: VirtualArchiveNode) {
        guard let content = archiveContent, let entry = node.entry, !node.isDirectory else { return }
        let origin = location
        let password = passwordsByPath[content.archive.url.standardizedFileURL.path]
        let slot = PaneTemporaryDirectory(parent: nestedWorkspace)
        let (id, cancellation) = beginLoading()
        let worker = worker
        loadingTask = Task { [weak self] in
            do {
                let url = try await worker.run {
                    let password = password ?? KeychainPasswordStore.password(for: content.archive.url)
                    return try PaneContentLoader.extractNested(entry: entry, content: content, workspace: slot,
                                                               password: password, cancellation: cancellation)
                }
                guard let self, self.loadID == id, !cancellation.isCancelled else { return }
                self.nestedFiles[url] = slot
                self.isLoading = false
                self.navigate(to: origin.enteringNestedArchive(extractedTempURL: url, displayName: entry.name))
            } catch {
                guard let self, self.loadID == id, !cancellation.isCancelled else { return }
                self.isLoading = false
                // Restore the outer listing after an extraction failure or password dismissal.
                self.rebuildDisplayedRows()
                if let error = error as? ArchiveError, error == .passwordRequired || error == .wrongPassword {
                    self.requestLoadPassword(url: content.archive.url, wrongAttempt: error == .wrongPassword, id: id) { [weak self] supplied in
                        guard let self, self.loadID == id else { return }
                        if supplied != nil { self.enterNestedArchive(node: node) }
                        else { self.loadLocation(highlightName: entry.name) }
                    }
                } else if !(error is CancellationError) {
                    self.loadLocation(highlightName: entry.name)
                    self.errorBanner = error.localizedDescription
                }
            }
        }
    }

    func requestPasswordForCurrentArchive(wrongAttempt: Bool, completion: @escaping (Bool) -> Void) {
        guard let arcURL = location.activeArchiveLayer?.archiveFileURL.standardizedFileURL else {
            completion(false)
            return
        }
        let origin = location
        if wrongAttempt {
            passwordsByPath.removeValue(forKey: arcURL.path)
            KeychainPasswordStore.removePassword(for: arcURL)
        }
        onRequestPassword?(arcURL, wrongAttempt) { [weak self] supplied in
            guard let self, self.location == origin else { completion(false); return }
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

    /// A generation changes for every request, including tab switches and password retries.
    /// Cancellation is cooperative; the generation also rejects uninterruptible stale I/O.
    private func beginLoading() -> (UUID, CancellationFlag) {
        loadCancellation?.cancel()
        loadingTask?.cancel()
        displayCancellation?.cancel()
        displayTask?.cancel()
        displayID = UUID()
        if let url = pendingPasswordURL {
            pendingPasswordURL = nil
            onCancelPasswordRequest?(url)
        }
        loadID = UUID()
        let cancellation = CancellationFlag()
        loadCancellation = cancellation
        isLoading = true
        errorBanner = nil
        presentation = nil
        resultsTruncated = false
        rows = canGoUp ? [.parentDirectory] : []
        return (loadID, cancellation)
    }

    func cancelLoading() {
        loadCancellation?.cancel()
        loadingTask?.cancel()
        loadID = UUID()
        displayID = UUID()
        displayCancellation?.cancel()
        displayTask?.cancel()
        presentation = nil
        isLoading = false
        archiveContent = nil
        rawItems = []
        rows = canGoUp ? [.parentDirectory] : []
        selectedIDs = []
        errorBanner = "Загрузка отменена"
    }

    private func loadLocation(highlightName: String?) {
        syncActiveTabSnapshot()
        pruneNestedFiles()
        let target = location
        if archiveContent?.archive.url.standardizedFileURL != target.activeArchiveLayer?.archiveFileURL.standardizedFileURL {
            archiveContent = nil
        }
        let directories: [PaneTemporaryDirectory]
        if case .archive(_, let layers, _) = target {
            directories = layers.compactMap { nestedFiles[$0.archiveFileURL] }
        } else {
            directories = []
        }
        let request = PaneLoadRequest(location: target, showHiddenFiles: showHiddenFiles, isFlatView: isFlatView,
                                      isDeepSearch: isDeepSearch, filterText: filterText, encoding: archiveEncoding,
                                      password: target.activeArchiveLayer.flatMap { passwordsByPath[$0.archiveFileURL.standardizedFileURL.path] },
                                      cachedArchive: archiveContent, temporaryDirectories: directories)
        rawItems = []
        let (id, cancellation) = beginLoading()
        let loader = loader
        let worker = worker
        loadingTask = Task { [weak self] in
            do {
                let result = try await worker.run { try loader.load(request, cancellation: cancellation) }
                guard let self, self.loadID == id, !cancellation.isCancelled else { return }
                self.archiveContent = result.archive
                self.rawItems = result.items
                self.resultsTruncated = result.truncated
                self.isLoading = false
                self.rebuildDisplayedRows(highlightName: highlightName)
                await self.displayTask?.value
                guard self.loadID == id, !cancellation.isCancelled else { return }
                if result.didOpenArchive, let layer = target.activeArchiveLayer, !layer.isTemporaryNestedFile {
                    self.onArchiveOpened?(layer.archiveFileURL)
                }
            } catch {
                guard let self, self.loadID == id, !cancellation.isCancelled else { return }
                self.isLoading = false
                if let error = error as? ArchiveError,
                   error == .passwordRequired || error == .wrongPassword,
                   let url = target.activeArchiveLayer?.archiveFileURL {
                    self.requestLoadPassword(url: url, wrongAttempt: error == .wrongPassword, id: id) { [weak self] supplied in
                        guard let self, self.loadID == id else { return }
                        if supplied != nil {
                            self.loadLocation(highlightName: highlightName)
                        } else if let previous = self.backStack.popLast() {
                            self.navigate(to: previous, highlightItemNamed: url.lastPathComponent, recordHistory: false)
                        } else if let (parent, highlight) = target.goingUp() {
                            self.navigate(to: parent, highlightItemNamed: highlight, recordHistory: false)
                        }
                    }
                } else if !(error is CancellationError) {
                    self.errorBanner = error.localizedDescription
                }
            }
        }
    }

    private func requestLoadPassword(url: URL, wrongAttempt: Bool, id: UUID, completion: @escaping (String?) -> Void) {
        if wrongAttempt { passwordsByPath.removeValue(forKey: url.standardizedFileURL.path) }
        let worker = worker
        loadingTask = Task { [weak self] in
            if wrongAttempt {
                _ = try? await worker.run { KeychainPasswordStore.removePassword(for: url) }
            }
            guard let self, self.loadID == id else { return }
            self.pendingPasswordURL = url
            self.onRequestPassword?(url, wrongAttempt) { [weak self] supplied in
                guard let self, self.loadID == id else { return }
                self.pendingPasswordURL = nil
                if let supplied, !supplied.isEmpty { self.passwordsByPath[url.standardizedFileURL.path] = supplied }
                completion(supplied?.isEmpty == false ? supplied : nil)
            }
        }
    }

    private func pruneNestedFiles() {
        let locations = tabs.flatMap { [$0.location] + $0.backStack + $0.forwardStack }
        let retained = Set(locations.flatMap { location -> [URL] in
            guard case .archive(_, let layers, _) = location else { return [] }
            return layers.map(\.archiveFileURL)
        })
        nestedFiles = nestedFiles.filter { retained.contains($0.key) }
    }

    private var displayOptions: PaneDisplayOptions {
        PaneDisplayOptions(query: filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                           deepSearch: isDeepSearch || isFlatView, sortField: sortField, ascending: sortAscending,
                           relativePaths: isShowingFlattenedPaths, stripPrefix: location.archiveSubpath, hasParent: canGoUp)
    }

    private func scheduleSearch() {
        let (id, _) = beginLoading()
        loadingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.loadID == id else { return }
            if self.isDeepSearch || self.isFlatView || self.rawItems.isEmpty {
                self.loadLocation(highlightName: nil)
                await self.loadingTask?.value
            } else {
                self.rebuildDisplayedRows()
                await self.displayTask?.value
            }
        }
    }

    private func rebuildDisplayedRows(highlightName: String? = nil) {
        // A sort change during I/O is picked up by the eventual load result.
        guard !rawItems.isEmpty || !isLoading else { return }
        displayCancellation?.cancel()
        displayTask?.cancel()
        let id = UUID()
        displayID = id
        let cancellation = CancellationFlag()
        displayCancellation = cancellation
        let options = displayOptions
        let items = rawItems
        let worker = worker
        isLoading = true
        displayTask = Task { [weak self] in
            do {
                let result = try await worker.run { try PanePresentation.build(items: items, options: options, cancellation: cancellation) }
                guard let self, self.displayID == id, !cancellation.isCancelled else { return }
                self.presentation = result
                self.rows = result.rows
                if let highlightName, let matched = result.rows.first(where: { !$0.isParentRow && $0.name == highlightName }) {
                    self.selectedIDs = [matched.id]
                } else {
                    self.selectedIDs.formIntersection(result.ids)
                }
                self.isLoading = false
            } catch { /* A newer presentation owns the pane. */ }
        }
    }
}
