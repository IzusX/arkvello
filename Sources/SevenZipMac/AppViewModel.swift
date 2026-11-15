import AppKit
import ArchiveCore
import Foundation

struct OperationBannerState: Equatable {
    var title: String
    var detail: String
    var fraction: Double?
    var isRunning: Bool
    var isError: Bool
}

struct PasswordPromptRequest: Identifiable {
    let id = UUID()
    let archiveURL: URL
    let isRetryAfterFailure: Bool
    let completion: (String?, Bool) -> Void
}

struct CompressSheetRequest: Identifiable {
    let id = UUID()
    let inputURLs: [URL]
    let defaultDestinationFolder: URL
    let suggestedArchiveName: String
}

struct ExtractSheetRequest: Identifiable {
    let id = UUID()
    let paneSide: PaneSide
    let archiveURL: URL
    let selectedPaths: [String]
    let stripPrefix: String
    let defaultDestinationFolder: URL
}

struct RenameSheetRequest: Identifiable {
    let id = UUID()
    let paneSide: PaneSide
    let row: PaneRowItem
}

struct NewFolderSheetRequest: Identifiable {
    let id = UUID()
    let paneSide: PaneSide
}

struct PropertiesSheetRequest: Identifiable {
    let id = UUID()
    let location: NavigationLocation
    let summary: ArchiveSummary?
    let selectedRows: [PaneRowItem]
}

struct OverwriteConflictSheetRequest: Identifiable {
    let id = UUID()
    let conflict: OverwriteConflict
    let respond: (OverwriteDecision) -> Void
}

struct ChecksumSheetRequest: Identifiable {
    let id = UUID()
    let itemName: String
    let itemSize: UInt64?
    let digests: [ArchiveHashDigest]
}

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class OverwriteReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OverwriteDecision = .cancel

    func set(_ decision: OverwriteDecision) {
        lock.lock()
        value = decision
        lock.unlock()
    }

    func get() -> OverwriteDecision {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    let leftPane: PaneViewModel
    let rightPane: PaneViewModel

    @Published var isDualPane: Bool = false {
        didSet { persistSessionState() }
    }
    @Published var activeSide: PaneSide = .left
    @Published var recentArchiveURLs: [URL] = []
    @Published var operationBanner: OperationBannerState?
    @Published private(set) var modifiedEditSessions: [TempEditSession] = []

    @Published var eliminateRootDuplication: Bool = true {
        didSet { persistSessionState() }
    }
    @Published var excludeMacOSMetadataByDefault: Bool = true {
        didSet { persistSessionState() }
    }
    @Published var preserveMacXattrByDefault: Bool = false {
        didSet { persistSessionState() }
    }

    @Published var passwordPrompt: PasswordPromptRequest?
    @Published var compressSheet: CompressSheetRequest?
    @Published var extractSheet: ExtractSheetRequest?
    @Published var renameSheet: RenameSheetRequest?
    @Published var newFolderSheet: NewFolderSheetRequest?
    @Published var propertiesSheet: PropertiesSheetRequest?
    @Published var overwriteConflictSheet: OverwriteConflictSheetRequest?
    @Published var checksumSheet: ChecksumSheetRequest?
    @Published var showSettingsSheet: Bool = false

    private var allEditSessions: [TempEditSession] = []
    private var currentCancellation: CancellationFlag?
    private let quickLookTempDir: URL
    private let clipboardTempDir: URL
    private var isRestoringSession = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home

        self.leftPane = PaneViewModel(side: .left, initialFolder: downloads)
        self.rightPane = PaneViewModel(side: .right, initialFolder: desktop)
        self.quickLookTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipMac-QuickLook-\(UUID().uuidString)", isDirectory: true)
        self.clipboardTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipMac-Clipboard-\(UUID().uuidString)", isDirectory: true)

        wirePaneCallbacks(leftPane)
        wirePaneCallbacks(rightPane)
        restoreSessionIfAvailable()
    }

    deinit {
        for s in allEditSessions { s.cleanup() }
        try? FileManager.default.removeItem(at: quickLookTempDir)
        try? FileManager.default.removeItem(at: clipboardTempDir)
    }

    var activePane: PaneViewModel {
        activeSide == .left ? leftPane : rightPane
    }

    var inactivePane: PaneViewModel {
        activeSide == .left ? rightPane : leftPane
    }

    var sidebarShortcuts: [SidebarShortcut] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var list: [SidebarShortcut] = [
            SidebarShortcut(id: "home", title: "Домашняя папка", systemImage: "house", url: home)
        ]
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            list.append(SidebarShortcut(id: "desktop", title: "Рабочий стол", systemImage: "menubar.dock.rectangle", url: desktop))
        }
        if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            list.append(SidebarShortcut(id: "downloads", title: "Загрузки", systemImage: "arrow.down.circle", url: downloads))
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            list.append(SidebarShortcut(id: "docs", title: "Документы", systemImage: "doc.text", url: docs))
        }
        list.append(SidebarShortcut(id: "apps", title: "Программы", systemImage: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")))
        list.append(SidebarShortcut(id: "root", title: "Macintosh HD", systemImage: "internaldrive", url: URL(fileURLWithPath: "/")))
        return list
    }

    // MARK: - Session Persistence

    private func restoreSessionIfAvailable() {
        guard let saved = SessionStore.load() else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        isDualPane = saved.isDualPane
        eliminateRootDuplication = saved.eliminateRootDuplication
        excludeMacOSMetadataByDefault = saved.excludeMacOSMetadataByDefault
        preserveMacXattrByDefault = saved.preserveMacXattrByDefault
        leftPane.showHiddenFiles = saved.showHiddenFiles
        rightPane.showHiddenFiles = saved.showHiddenFiles

        leftPane.restorePersistedTabs(paths: saved.leftFolderPaths, activeIndex: saved.leftActiveTabIndex)
        rightPane.restorePersistedTabs(paths: saved.rightFolderPaths, activeIndex: saved.rightActiveTabIndex)

        recentArchiveURLs = saved.recentArchivePaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func persistSessionState() {
        guard !isRestoringSession else { return }
        let leftInfo = leftPane.persistableTabPaths
        let rightInfo = rightPane.persistableTabPaths
        let snap = PersistedSession(
            isDualPane: isDualPane,
            showHiddenFiles: leftPane.showHiddenFiles,
            leftFolderPaths: leftInfo.paths,
            leftActiveTabIndex: leftInfo.activeIndex,
            rightFolderPaths: rightInfo.paths,
            rightActiveTabIndex: rightInfo.activeIndex,
            recentArchivePaths: recentArchiveURLs.map(\.path),
            eliminateRootDuplication: eliminateRootDuplication,
            excludeMacOSMetadataByDefault: excludeMacOSMetadataByDefault,
            preserveMacXattrByDefault: preserveMacXattrByDefault
        )
        SessionStore.save(snap)
    }

    func toggleDualPane() {
        isDualPane.toggle()
        if !isDualPane {
            activeSide = .left
        }
    }

    func switchActivePane() {
        guard isDualPane else { return }
        activeSide = activeSide.opposite
    }

    func openNewTabInActivePane() {
        activePane.openNewTab()
    }

    /// Returns true if an inner tab was closed, false if caller should close window.
    func closeActiveTabOrAllowWindowClose() -> Bool {
        activePane.closeTab()
    }

    func cancelRunningOperation() {
        currentCancellation?.cancel()
    }

    func openExternalURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
            activePane.navigate(to: .diskFolder(first))
        } else if SevenZipEngine.isBrowsableArchive(url: first) {
            activePane.openArchiveFile(first)
        } else {
            let folder = first.deletingLastPathComponent()
            activePane.navigate(to: .diskFolder(folder), highlightItemNamed: first.lastPathComponent)
        }
    }

    func promptOpenArchiveDialog() {
        let panel = NSOpenPanel()
        panel.title = "Открыть архив или папку"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openExternalURLs([url])
        }
    }

    // MARK: - Finder Right-Click Services (`NSServices`)

    func finderServiceExtract(urls: [URL], alwaysCreateSubfolder: Bool, passwordOverride: String? = nil) {
        let archives = urls.filter { SevenZipEngine.isBrowsableArchive(url: $0) }
        guard let firstArc = archives.first else {
            openExternalURLs(urls)
            return
        }
        let elimDup = eliminateRootDuplication
        let pwd = passwordOverride ?? KeychainPasswordStore.password(for: firstArc)
        let interactiveOverwrite = makeInteractiveOverwriteBridge()

        runBackgroundOperation(title: "Извлечение (Finder)", initialDetail: firstArc.lastPathComponent) { flag, report in
            for arcURL in archives {
                if flag.isCancelled { throw ArchiveError.cancelled }
                let localPwd = KeychainPasswordStore.password(for: arcURL) ?? pwd
                let opened = try OpenArchive(url: arcURL, password: localPwd)
                defer { opened.close() }
                let tree = VirtualArchiveTree(entries: opened.entries)

                let plan: ExtractionPlan
                if alwaysCreateSubfolder {
                    plan = SmartExtractionPlanner.planDialogExtraction(
                        archiveURL: arcURL,
                        tree: tree,
                        selectedPaths: [],
                        currentStripPrefix: "",
                        baseDestination: arcURL.deletingLastPathComponent(),
                        createArchiveSubfolder: true,
                        eliminateRootDuplication: elimDup
                    )
                } else {
                    plan = SmartExtractionPlanner.planSmartExtractHere(archiveURL: arcURL, tree: tree)
                }

                try opened.extract(
                    indices: nil,
                    to: plan.finalDestinationDirectory,
                    stripPrefix: plan.effectiveStripPrefix,
                    fullPaths: true,
                    overwrite: .askInteractive,
                    password: localPwd,
                    overwriteHandler: interactiveOverwrite,
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
            }
        } onSuccess: { [weak self] in
            self?.leftPane.reloadCurrentLocation()
            if self?.isDualPane == true { self?.rightPane.reloadCurrentLocation() }
            self?.showTransientSuccess("Извлечено архивов: \(archives.count)")
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompt = PasswordPromptRequest(archiveURL: firstArc, isRetryAfterFailure: wrong) { supplied, remember in
                guard let supplied, !supplied.isEmpty else { return }
                self.leftPane.storePassword(supplied, for: firstArc, saveToKeychain: remember)
                self.finderServiceExtract(urls: urls, alwaysCreateSubfolder: alwaysCreateSubfolder, passwordOverride: supplied)
            }
        }
    }

    func finderServiceQuickCompress7z(urls: [URL]) {
        guard let first = urls.first else { return }
        let parentDir = first.deletingLastPathComponent()
        let baseName = urls.count == 1
            ? (first.deletingPathExtension().lastPathComponent.isEmpty ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent)
            : parentDir.lastPathComponent
        let targetURL = parentDir.appendingPathComponent("\(baseName).7z")
        let opts = CompressionOptions(
            format: "7z",
            method: "LZMA2",
            level: 5,
            excludeMacOSMetadata: excludeMacOSMetadataByDefault,
            preserveMacExtendedAttributes: preserveMacXattrByDefault
        )
        executeCompression(archiveURL: targetURL, inputURLs: urls, options: opts, password: nil, saveToKeychain: false)
    }

    func finderServiceOpenCompressDialog(urls: [URL]) {
        guard let first = urls.first else { return }
        let parentDir = first.deletingLastPathComponent()
        let suggested = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : parentDir.lastPathComponent
        compressSheet = CompressSheetRequest(
            inputURLs: urls,
            defaultDestinationFolder: parentDir,
            suggestedArchiveName: suggested.isEmpty ? "Archive" : suggested
        )
    }

    // MARK: - System Clipboard (`⌘C` / `⌘V`)

    func copySelectionToPasteboard() {
        let pane = activePane
        let selected = pane.selectedActionableRows
        guard !selected.isEmpty else { return }

        switch pane.location {
        case .diskFolder:
            let urls: [NSURL] = selected.compactMap {
                if case .disk(let d) = $0 { return d.url as NSURL }
                return nil
            }
            guard !urls.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls)
            showTransientSuccess("Скопировано объектов в буфер обмена: \(urls.count)")

        case .archive(_, let layers, let subpath):
            guard let topLayer = layers.last else { return }
            let arcURL = topLayer.archiveFileURL
            let selectedPaths: [String] = selected.compactMap {
                if case .archive(let n) = $0 { return n.path }
                return nil
            }
            guard !selectedPaths.isEmpty else { return }
            let stripPrefix = pane.isShowingFlattenedPaths ? "" : subpath
            let preservePaths = !pane.isShowingFlattenedPaths
            let pwd = pane.currentArchivePassword
            let enc = pane.archiveEncoding
            let stageSlot = clipboardTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)

            runBackgroundOperation(title: "Подготовка буфера обмена", initialDetail: topLayer.displayName) { flag, report in
                try FileManager.default.createDirectory(at: stageSlot, withIntermediateDirectories: true)
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: enc)
                defer { opened.close() }
                let tree = VirtualArchiveTree(entries: opened.entries)
                let indices = tree.extractionIndices(for: selectedPaths)
                try opened.extract(
                    indices: indices,
                    to: stageSlot,
                    stripPrefix: stripPrefix,
                    fullPaths: preservePaths,
                    overwrite: .overwriteAll,
                    password: pwd,
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
            } onSuccess: { [weak self] in
                guard let self else { return }
                let topItems = (try? FileManager.default.contentsOfDirectory(
                    at: stageSlot,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                guard !topItems.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(topItems.map { $0 as NSURL })
                self.showTransientSuccess("Скопировано из архива в буфер (\(topItems.count)) — можно нажать ⌘V в Finder")
            } onPasswordNeeded: { [weak self] wrong in
                pane.requestPasswordForCurrentArchive(wrongAttempt: wrong) { ok in
                    if ok { self?.copySelectionToPasteboard() }
                }
            }
        }
    }

    func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return
        }
        handleDroppedURLs(urls, into: activeSide)
    }

    // MARK: - Checksums (`CRC32 / SHA-256 / XXH64`)

    func computeChecksumsForSelection() {
        let pane = activePane
        guard let first = pane.selectedActionableRows.first, !first.isDirectory else {
            showStatusBanner(
                title: "Выберите файл",
                detail: "Выделите файл (на диске или внутри архива) для расчёта контрольных сумм.",
                isError: false
            )
            return
        }

        switch first {
        case .parentDirectory:
            return
        case .disk(let d):
            let url = d.url
            let name = d.name
            let size = d.size
            let digestsBox = Box<[ArchiveHashDigest]>([])
            runBackgroundOperation(title: "Расчёт контрольных сумм", initialDetail: name) { flag, report in
                digestsBox.value = try SevenZipEngine.computeFileHashes(at: url) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } onSuccess: { [weak self] in
                self?.checksumSheet = ChecksumSheetRequest(
                    itemName: name,
                    itemSize: size,
                    digests: digestsBox.value
                )
            }

        case .archive(let node):
            guard let entry = node.entry,
                  let arcURL = pane.location.activeArchiveLayer?.archiveFileURL else { return }
            let pwd = pane.currentArchivePassword
            let enc = pane.archiveEncoding
            let digestsBox = Box<[ArchiveHashDigest]>([])
            runBackgroundOperation(title: "Расчёт контрольных сумм", initialDetail: node.name) { flag, report in
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: enc)
                defer { opened.close() }
                digestsBox.value = try opened.computeEntryHashes(
                    for: entry.index,
                    password: pwd,
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
            } onSuccess: { [weak self] in
                self?.checksumSheet = ChecksumSheetRequest(
                    itemName: node.name,
                    itemSize: node.displaySize,
                    digests: digestsBox.value
                )
            } onPasswordNeeded: { [weak self] wrong in
                pane.requestPasswordForCurrentArchive(wrongAttempt: wrong) { ok in
                    if ok { self?.computeChecksumsForSelection() }
                }
            }
        }
    }

    // MARK: - Item Activation & Quick Look

    func activateRow(_ row: PaneRowItem, in side: PaneSide) {
        activeSide = side
        let pane = (side == .left) ? leftPane : rightPane

        switch row {
        case .parentDirectory:
            pane.goUp()

        case .disk(let d):
            if d.isDirectory {
                pane.isFlatView = false
                pane.filterText = ""
                pane.navigate(to: .diskFolder(d.url))
            } else if d.isArchiveContainer {
                pane.isFlatView = false
                pane.filterText = ""
                pane.openArchiveFile(d.url)
            } else {
                NSWorkspace.shared.open(d.url)
            }

        case .archive(let node):
            if node.isDirectory {
                pane.isFlatView = false
                pane.filterText = ""
                pane.navigate(to: pane.location.enteringArchiveSubfolder(node.path))
            } else if row.isArchiveFile {
                pane.isFlatView = false
                pane.filterText = ""
                pane.enterNestedArchive(node: node)
            } else {
                openArchiveEntryExternally(node: node, in: pane)
            }
        }
    }

    func triggerQuickLook(in side: PaneSide) {
        activeSide = side
        let pane = (side == .left) ? leftPane : rightPane
        let selected = pane.selectedActionableRows
        guard !selected.isEmpty else { return }

        switch pane.location {
        case .diskFolder:
            let urls = selected.compactMap { row -> URL? in
                if case .disk(let d) = row { return d.url }
                return nil
            }
            QuickLookCoordinator.shared.togglePreview(urls: urls)

        case .archive:
            guard let arc = pane.openArchive else { return }
            let entries: [ArchiveEntry] = selected.compactMap { row in
                if case .archive(let node) = row, !node.isDirectory {
                    return node.entry
                }
                return nil
            }
            guard !entries.isEmpty else { return }

            do {
                let slot = quickLookTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
                let indices = entries.map(\.index)
                let stripSub = pane.isShowingFlattenedPaths ? "" : pane.location.archiveSubpath
                try arc.extract(
                    indices: indices,
                    to: slot,
                    stripPrefix: stripSub,
                    fullPaths: true,
                    overwrite: .overwriteAll,
                    password: pane.currentArchivePassword
                )
                let previewURLs = entries.compactMap { entry -> URL? in
                    let rel: String
                    let cleanSub = VirtualArchiveTree.normalize(stripSub)
                    if !cleanSub.isEmpty && entry.path.hasPrefix(cleanSub + "/") {
                        rel = String(entry.path.dropFirst(cleanSub.count + 1))
                    } else {
                        rel = entry.path
                    }
                    let candidate = slot.appendingPathComponent(rel)
                    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
                }
                QuickLookCoordinator.shared.togglePreview(urls: previewURLs)
            } catch let err as ArchiveError where err == .passwordRequired || err == .wrongPassword {
                pane.requestPasswordForCurrentArchive(wrongAttempt: err == .wrongPassword) { [weak self] ok in
                    if ok { self?.triggerQuickLook(in: side) }
                }
            } catch {
                showStatusBanner(title: "Ошибка предпросмотра", detail: error.localizedDescription, isError: true)
            }
        }
    }

    private func openArchiveEntryExternally(node: VirtualArchiveNode, in pane: PaneViewModel) {
        guard let arc = pane.openArchive, let entry = node.entry else { return }
        let pwd = pane.currentArchivePassword
        do {
            let session = try TempEditSession(
                archive: arc,
                entry: entry,
                password: pwd,
                onExternalModification: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshModifiedEditSessions()
                    }
                }
            )
            allEditSessions.append(session)
            NSWorkspace.shared.open(session.extractedFileURL)
        } catch let err as ArchiveError where err == .passwordRequired || err == .wrongPassword {
            pane.requestPasswordForCurrentArchive(wrongAttempt: err == .wrongPassword) { [weak self] ok in
                if ok { self?.openArchiveEntryExternally(node: node, in: pane) }
            }
        } catch {
            showStatusBanner(title: "Не удалось открыть файл", detail: error.localizedDescription, isError: true)
        }
    }

    func refreshModifiedEditSessions() {
        modifiedEditSessions = allEditSessions.filter { $0.isArchiveUpdatable && $0.hasUncommittedChanges() }
    }

    func commitModifiedSession(_ session: TempEditSession) {
        let pwd = leftPane.currentArchivePassword ?? rightPane.currentArchivePassword
        runBackgroundOperation(title: "Обновление архива", initialDetail: session.archiveEntryPath) { flag, report in
            try session.commitChanges(password: pwd) { prog in
                report(prog)
                return !flag.isCancelled
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.refreshModifiedEditSessions()
            self.reloadPanesShowingArchive(session.archiveURL)
            self.showTransientSuccess("Файл «\(session.extractedFileURL.lastPathComponent)» обновлён в архиве")
        }
    }

    func discardModifiedSession(_ session: TempEditSession) {
        session.cleanup()
        allEditSessions.removeAll { $0 === session }
        refreshModifiedEditSessions()
    }

    // MARK: - Toolbar & 7zFM Operations

    func presentAddCompressDialog() {
        let pane = activePane
        switch pane.location {
        case .diskFolder(let currentDir):
            let selectedURLs: [URL] = pane.selectedActionableRows.compactMap {
                if case .disk(let d) = $0 { return d.url }
                return nil
            }
            guard !selectedURLs.isEmpty else {
                let openPanel = NSOpenPanel()
                openPanel.title = "Выберите файлы или папки для упаковки"
                openPanel.directoryURL = currentDir
                openPanel.canChooseFiles = true
                openPanel.canChooseDirectories = true
                openPanel.allowsMultipleSelection = true
                guard openPanel.runModal() == .OK, !openPanel.urls.isEmpty else { return }
                let baseName = openPanel.urls.count == 1
                    ? openPanel.urls[0].deletingPathExtension().lastPathComponent
                    : currentDir.lastPathComponent
                compressSheet = CompressSheetRequest(
                    inputURLs: openPanel.urls,
                    defaultDestinationFolder: currentDir,
                    suggestedArchiveName: baseName.isEmpty ? "Archive" : baseName
                )
                return
            }
            let suggested = selectedURLs.count == 1
                ? selectedURLs[0].deletingPathExtension().lastPathComponent
                : currentDir.lastPathComponent
            compressSheet = CompressSheetRequest(
                inputURLs: selectedURLs,
                defaultDestinationFolder: currentDir,
                suggestedArchiveName: suggested.isEmpty ? "Archive" : suggested
            )

        case .archive(_, let layers, _):
            guard let topLayer = layers.last, pane.activeArchiveSummary?.isUpdatable == true else {
                showStatusBanner(
                    title: "Только чтение",
                    detail: "Текущий архив не поддерживает добавление файлов напрямую.",
                    isError: true
                )
                return
            }
            let openPanel = NSOpenPanel()
            openPanel.title = "Добавить файлы в «\(topLayer.displayName)»"
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = true
            if openPanel.runModal() == .OK, !openPanel.urls.isEmpty {
                addDiskFiles(openPanel.urls, intoArchivePane: pane, deleteSourcesAfter: false)
            }
        }
    }

    func presentExtractDialog() {
        let pane = activePane
        if case .archive(let rootDiskFolder, let layers, let subpath) = pane.location,
           let topLayer = layers.last {
            let selectedPaths: [String] = pane.selectedActionableRows.compactMap {
                if case .archive(let node) = $0 { return node.path }
                return nil
            }
            let defaultDest: URL
            if isDualPane, case .diskFolder(let otherFolder) = inactivePane.location {
                defaultDest = otherFolder
            } else {
                defaultDest = rootDiskFolder
            }
            let strip = (selectedPaths.isEmpty || pane.isShowingFlattenedPaths) ? "" : subpath
            extractSheet = ExtractSheetRequest(
                paneSide: pane.side,
                archiveURL: topLayer.archiveFileURL,
                selectedPaths: selectedPaths,
                stripPrefix: strip,
                defaultDestinationFolder: defaultDest
            )
        } else if let firstSelected = pane.selectedActionableRows.first,
                  case .disk(let d) = firstSelected,
                  d.isArchiveContainer {
            let defaultDest: URL
            if isDualPane, case .diskFolder(let otherFolder) = inactivePane.location {
                defaultDest = otherFolder
            } else {
                defaultDest = d.url.deletingLastPathComponent()
            }
            extractSheet = ExtractSheetRequest(
                paneSide: pane.side,
                archiveURL: d.url,
                selectedPaths: [],
                stripPrefix: "",
                defaultDestinationFolder: defaultDest
            )
        } else {
            showStatusBanner(
                title: "Выберите архив",
                detail: "Откройте архив или выделите архивный файл в таблице для извлечения.",
                isError: false
            )
        }
    }

    func executeCompression(
        archiveURL: URL,
        inputURLs: [URL],
        options: CompressionOptions,
        password: String?,
        saveToKeychain: Bool
    ) {
        let paths = inputURLs.map(\.path)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let alert = NSAlert()
            alert.messageText = "Заменить архив «\(archiveURL.lastPathComponent)»?"
            alert.informativeText = "Исходный архив сохранится, если создание новой версии завершится ошибкой или будет отменено."
            alert.addButton(withTitle: "Заменить")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        runBackgroundOperation(title: "Создание архива", initialDetail: archiveURL.lastPathComponent) { flag, report in
            if options.splitVolumeBytes > 0 {
                // Never overwrite an existing volume set implicitly.
                guard !FileManager.default.fileExists(atPath: archiveURL.path + ".001") else {
                    throw ArchiveError.ioError("Набор томов уже существует. Выберите другое имя архива.")
                }
                try SevenZipEngine.createOrUpdateArchive(at: archiveURL, inputPaths: paths, options: options, password: password) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } else {
                try StagedReplacement.publish(at: archiveURL) { stagedURL in
                    try SevenZipEngine.createOrUpdateArchive(at: stagedURL, inputPaths: paths, options: options, password: password) { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                }
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            if let password, !password.isEmpty {
                self.leftPane.storePassword(password, for: archiveURL, saveToKeychain: saveToKeychain)
                self.rightPane.storePassword(password, for: archiveURL, saveToKeychain: false)
            }
            self.leftPane.reloadCurrentLocation()
            if self.isDualPane { self.rightPane.reloadCurrentLocation() }
            self.showTransientSuccess("Архив «\(archiveURL.lastPathComponent)» создан")
        }
    }

    func executeExtraction(
        request: ExtractSheetRequest,
        destinationFolder: URL,
        createArchiveSubfolder: Bool,
        eliminateDupRoot: Bool,
        fullPaths: Bool,
        overwriteMode: OverwriteMode,
        passwordOverride: String?
    ) {
        let pane = (request.paneSide == .left) ? leftPane : rightPane
        let pwd = (passwordOverride?.isEmpty == false)
            ? passwordOverride
            : (pane.currentArchivePassword ?? KeychainPasswordStore.password(for: request.archiveURL))

        let archiveURL = request.archiveURL
        let selectedPaths = request.selectedPaths
        let stripPrefix = request.stripPrefix
        let enc = pane.archiveEncoding
        let interactiveOverwrite = makeInteractiveOverwriteBridge()
        let finalFolderBox = Box<URL>(destinationFolder)
        let overwriteCallback: (@Sendable (OverwriteConflict) -> OverwriteDecision)? =
            overwriteMode == .askInteractive ? interactiveOverwrite : nil

        runBackgroundOperation(title: "Извлечение", initialDetail: archiveURL.lastPathComponent) { flag, report in
            let opened = try OpenArchive(url: archiveURL, password: pwd, encoding: enc)
            defer { opened.close() }

            let tree = VirtualArchiveTree(entries: opened.entries)
            let plan = SmartExtractionPlanner.planDialogExtraction(
                archiveURL: archiveURL,
                tree: tree,
                selectedPaths: selectedPaths,
                currentStripPrefix: stripPrefix,
                baseDestination: destinationFolder,
                createArchiveSubfolder: createArchiveSubfolder,
                eliminateRootDuplication: eliminateDupRoot
            )
            finalFolderBox.value = plan.finalDestinationDirectory

            let indices: [UInt32]? = selectedPaths.isEmpty
                ? nil
                : tree.extractionIndices(for: selectedPaths)

            try opened.extract(
                indices: indices,
                to: plan.finalDestinationDirectory,
                stripPrefix: plan.effectiveStripPrefix,
                fullPaths: fullPaths,
                overwrite: overwriteMode,
                password: pwd,
                overwriteHandler: overwriteCallback,
                progress: { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            )
        } onSuccess: { [weak self] in
            guard let self else { return }
            if let pwd, !pwd.isEmpty {
                pane.storePassword(pwd, for: archiveURL)
            }
            self.leftPane.reloadCurrentLocation()
            if self.isDualPane { self.rightPane.reloadCurrentLocation() }
            self.showTransientSuccess("Извлечено в «\(finalFolderBox.value.lastPathComponent)»")
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompt = PasswordPromptRequest(
                archiveURL: archiveURL,
                isRetryAfterFailure: wrong
            ) { supplied, remember in
                guard let supplied, !supplied.isEmpty else { return }
                pane.storePassword(supplied, for: archiveURL, saveToKeychain: remember)
                self.executeExtraction(
                    request: request,
                    destinationFolder: destinationFolder,
                    createArchiveSubfolder: createArchiveSubfolder,
                    eliminateDupRoot: eliminateDupRoot,
                    fullPaths: fullPaths,
                    overwriteMode: overwriteMode,
                    passwordOverride: supplied
                )
            }
        }
    }

    func testCurrentArchive() {
        let pane = activePane
        let targetArchiveURL: URL?
        if let activeLayer = pane.location.activeArchiveLayer {
            targetArchiveURL = activeLayer.archiveFileURL
        } else if let first = pane.selectedActionableRows.first,
                  case .disk(let d) = first,
                  d.isArchiveContainer {
            targetArchiveURL = d.url
        } else {
            targetArchiveURL = nil
        }

        guard let archiveURL = targetArchiveURL else {
            showStatusBanner(
                title: "Нет активного архива",
                detail: "Откройте архив или выделите архивный файл для проверки целостности.",
                isError: false
            )
            return
        }

        let pwd = pane.currentArchivePassword ?? KeychainPasswordStore.password(for: archiveURL)
        runBackgroundOperation(title: "Проверка целостности", initialDetail: archiveURL.lastPathComponent) { flag, report in
            let opened = try OpenArchive(url: archiveURL, password: pwd)
            defer { opened.close() }
            try opened.test(password: pwd, progress: { prog in
                report(prog)
                return !flag.isCancelled
            })
        } onSuccess: { [weak self] in
            self?.showTransientSuccess("Проверка пройдена: ошибок в «\(archiveURL.lastPathComponent)» не обнаружено")
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompt = PasswordPromptRequest(archiveURL: archiveURL, isRetryAfterFailure: wrong) { supplied, remember in
                guard let supplied, !supplied.isEmpty else { return }
                pane.storePassword(supplied, for: archiveURL, saveToKeychain: remember)
                self.testCurrentArchive()
            }
        }
    }

    /// F5 (Copy) / F6 (Move) between left and right panes.
    func copyOrMoveSelectionAcrossPanes(move: Bool) {
        guard isDualPane else {
            if activePane.location.isInsideArchive {
                presentExtractDialog()
            } else {
                presentAddCompressDialog()
            }
            return
        }

        let src = activePane
        let dst = inactivePane
        let selected = src.selectedActionableRows
        guard !selected.isEmpty else { return }

        switch (src.location, dst.location) {
        case (.diskFolder, .diskFolder(let destFolder)):
            let urls: [URL] = selected.compactMap {
                if case .disk(let d) = $0 { return d.url }
                return nil
            }
            guard !urls.isEmpty else { return }
            let interactiveOverwrite = makeInteractiveOverwriteBridge()

            runBackgroundOperation(
                title: move ? "Перемещение" : "Копирование",
                initialDetail: "\(urls.count) объ."
            ) { flag, _ in
                let fm = FileManager.default
                var applyAllDecision: OverwriteDecision?
                for u in urls {
                    if flag.isCancelled { throw ArchiveError.cancelled }
                    var target = destFolder.appendingPathComponent(u.lastPathComponent)
                    if target.standardizedFileURL == u.standardizedFileURL { continue }
                    if fm.fileExists(atPath: target.path) {
                        let srcVals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let dstVals = try? target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let decision = applyAllDecision ?? interactiveOverwrite(
                            OverwriteConflict(
                                existingPath: target.path,
                                existingSize: dstVals?.fileSize.map { UInt64(max(0, $0)) },
                                existingModifiedDate: dstVals?.contentModificationDate,
                                newPath: u.path,
                                newSize: srcVals?.fileSize.map { UInt64(max(0, $0)) },
                                newModifiedDate: srcVals?.contentModificationDate
                            )
                        )
                        if decision == .replaceAll || decision == .skipAll {
                            applyAllDecision = decision
                        }
                        switch decision {
                        case .cancel:
                            throw ArchiveError.cancelled
                        case .skip, .skipAll:
                            continue
                        case .autoRename:
                            let ext = target.pathExtension
                            let stem = target.deletingPathExtension().lastPathComponent
                            let renamed = ext.isEmpty ? "\(stem)_copy" : "\(stem)_copy.\(ext)"
                            target = destFolder.appendingPathComponent(renamed)
                        case .replace, .replaceAll:
                            try fm.removeItem(at: target)
                        }
                    }
                    if move {
                        try fm.moveItem(at: u, to: target)
                    } else {
                        try fm.copyItem(at: u, to: target)
                    }
                }
            } onSuccess: { [weak self] in
                self?.leftPane.reloadCurrentLocation()
                self?.rightPane.reloadCurrentLocation()
                self?.showTransientSuccess(move ? "Перемещение завершено" : "Копирование завершено")
            }

        case (.archive(_, let layers, let srcSubpath), .diskFolder(let destFolder)):
            guard let topLayer = layers.last else { return }
            let selectedPaths: [String] = selected.compactMap {
                if case .archive(let node) = $0 { return node.path }
                return nil
            }
            guard !selectedPaths.isEmpty else { return }
            let canDeleteFromArc = move && (src.activeArchiveSummary?.isUpdatable == true)
            let pwd = src.currentArchivePassword
            let enc = src.archiveEncoding
            let arcURL = topLayer.archiveFileURL
            let strip = src.isShowingFlattenedPaths ? "" : srcSubpath
            let fullPaths = !src.isShowingFlattenedPaths
            let interactiveOverwrite = makeInteractiveOverwriteBridge()

            runBackgroundOperation(
                title: move ? "Извлечение с удалением" : "Извлечение в соседнюю панель",
                initialDetail: destFolder.lastPathComponent
            ) { flag, report in
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: enc)
                let tree = VirtualArchiveTree(entries: opened.entries)
                let indices = tree.extractionIndices(for: selectedPaths)
                var skippedAny = false
                try opened.extract(
                    indices: indices,
                    to: destFolder,
                    stripPrefix: strip,
                    fullPaths: fullPaths,
                    overwrite: .askInteractive,
                    password: pwd,
                    overwriteHandler: { conflict in
                        let decision = interactiveOverwrite(conflict)
                        if decision == .skip || decision == .skipAll { skippedAny = true }
                        return decision
                    },
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
                opened.close()

                if canDeleteFromArc && !skippedAny {
                    try SevenZipEngine.deleteItems(
                        in: arcURL,
                        archivePaths: selectedPaths,
                        password: pwd
                    ) { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                }
            } onSuccess: { [weak self] in
                guard let self else { return }
                dst.reloadCurrentLocation()
                if canDeleteFromArc {
                    self.reloadPanesShowingArchive(arcURL)
                }
                self.showTransientSuccess("Скопировано в «\(destFolder.lastPathComponent)»")
            } onPasswordNeeded: { [weak self] wrong in
                guard let self else { return }
                src.requestPasswordForCurrentArchive(wrongAttempt: wrong) { ok in
                    if ok { self.copyOrMoveSelectionAcrossPanes(move: move) }
                }
            }

        case (.diskFolder, .archive):
            let urls: [URL] = selected.compactMap {
                if case .disk(let d) = $0 { return d.url }
                return nil
            }
            guard !urls.isEmpty else { return }
            addDiskFiles(urls, intoArchivePane: dst, deleteSourcesAfter: move)

        case (.archive, .archive):
            showStatusBanner(
                title: "Два архива",
                detail: "Откройте в целевой панели папку на диске или используйте буфер обмена ⌘C / ⌘V.",
                isError: false
            )
        }
    }

    func addDiskFiles(_ urls: [URL], intoArchivePane dstPane: PaneViewModel, deleteSourcesAfter: Bool) {
        guard case .archive(_, let layers, let targetSubpath) = dstPane.location,
              let topLayer = layers.last,
              dstPane.activeArchiveSummary?.isUpdatable == true else {
            showStatusBanner(
                title: "Архив только для чтения",
                detail: "Этот формат архива не поддерживает добавление или изменение элементов.",
                isError: true
            )
            return
        }

        let arcURL = topLayer.archiveFileURL
        let cleanSubpath = VirtualArchiveTree.normalize(targetSubpath)
        let pwd = dstPane.currentArchivePassword
        let opts = CompressionOptions(
            excludeMacOSMetadata: deleteSourcesAfter ? false : excludeMacOSMetadataByDefault,
            preserveMacExtendedAttributes: preserveMacXattrByDefault
        )

        runBackgroundOperation(title: "Добавление в архив", initialDetail: topLayer.displayName) { flag, report in
            let fm = FileManager.default
            if cleanSubpath.isEmpty {
                try SevenZipEngine.createOrUpdateArchive(
                    at: arcURL,
                    inputPaths: urls.map(\.path),
                    baseDirectory: nil,
                    options: opts,
                    password: pwd
                ) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } else {
                let stageRoot = fm.temporaryDirectory.appendingPathComponent("SevenZipMac-AddStage-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: stageRoot) }
                let nestedStage = stageRoot.appendingPathComponent(cleanSubpath, isDirectory: true)
                try fm.createDirectory(at: nestedStage, withIntermediateDirectories: true)

                var relInputs: [String] = []
                for u in urls {
                    let staged = nestedStage.appendingPathComponent(u.lastPathComponent)
                    try fm.copyItem(at: u, to: staged)
                    relInputs.append("\(cleanSubpath)/\(u.lastPathComponent)")
                }

                try SevenZipEngine.createOrUpdateArchive(
                    at: arcURL,
                    inputPaths: relInputs,
                    baseDirectory: stageRoot,
                    options: opts,
                    password: pwd
                ) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            }

            if deleteSourcesAfter {
                for u in urls {
                    try? fm.trashItem(at: u, resultingItemURL: nil)
                }
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.reloadPanesShowingArchive(arcURL)
            self.leftPane.reloadCurrentLocation()
            if self.isDualPane { self.rightPane.reloadCurrentLocation() }
            self.showTransientSuccess("Добавлено в «\(topLayer.displayName)»")
        }
    }

    func handleDroppedURLs(_ urls: [URL], into side: PaneSide) {
        activeSide = side
        let pane = (side == .left) ? leftPane : rightPane

        if urls.count == 1, SevenZipEngine.isBrowsableArchive(url: urls[0]), !pane.location.isInsideArchive {
            pane.openArchiveFile(urls[0])
            return
        }

        switch pane.location {
        case .diskFolder(let destFolder):
            let interactiveOverwrite = makeInteractiveOverwriteBridge()
            runBackgroundOperation(title: "Копирование", initialDetail: destFolder.lastPathComponent) { flag, _ in
                let fm = FileManager.default
                var applyAll: OverwriteDecision?
                for u in urls {
                    if flag.isCancelled { throw ArchiveError.cancelled }
                    var target = destFolder.appendingPathComponent(u.lastPathComponent)
                    if target.standardizedFileURL == u.standardizedFileURL {
                        let ext = target.pathExtension
                        let stem = target.deletingPathExtension().lastPathComponent
                        target = destFolder.appendingPathComponent(ext.isEmpty ? "\(stem)_copy" : "\(stem)_copy.\(ext)")
                    } else if fm.fileExists(atPath: target.path) {
                        let srcVals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let dstVals = try? target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let decision = applyAll ?? interactiveOverwrite(
                            OverwriteConflict(
                                existingPath: target.path,
                                existingSize: dstVals?.fileSize.map { UInt64(max(0, $0)) },
                                existingModifiedDate: dstVals?.contentModificationDate,
                                newPath: u.path,
                                newSize: srcVals?.fileSize.map { UInt64(max(0, $0)) },
                                newModifiedDate: srcVals?.contentModificationDate
                            )
                        )
                        if decision == .replaceAll || decision == .skipAll { applyAll = decision }
                        switch decision {
                        case .cancel: throw ArchiveError.cancelled
                        case .skip, .skipAll: continue
                        case .autoRename:
                            let ext = target.pathExtension
                            let stem = target.deletingPathExtension().lastPathComponent
                            target = destFolder.appendingPathComponent(ext.isEmpty ? "\(stem)_copy" : "\(stem)_copy.\(ext)")
                        case .replace, .replaceAll:
                            try fm.removeItem(at: target)
                        }
                    }
                    try fm.copyItem(at: u, to: target)
                }
            } onSuccess: { [weak self] in
                pane.reloadCurrentLocation()
                self?.showTransientSuccess("Файлы скопированы в «\(destFolder.lastPathComponent)»")
            }

        case .archive:
            addDiskFiles(urls, intoArchivePane: pane, deleteSourcesAfter: false)
        }
    }

    // MARK: - Rename, New Folder, Delete, Properties

    func presentRenameDialog() {
        guard let first = activePane.selectedActionableRows.first else { return }
        if activePane.location.isInsideArchive && activePane.activeArchiveSummary?.isUpdatable != true {
            showStatusBanner(title: "Только чтение", detail: "Этот формат архива не поддерживает переименование.", isError: true)
            return
        }
        renameSheet = RenameSheetRequest(paneSide: activeSide, row: first)
    }

    func executeRename(request: RenameSheetRequest, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let pane = (request.paneSide == .left) ? leftPane : rightPane

        switch request.row {
        case .parentDirectory:
            return
        case .disk(let d):
            let dest = d.url.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: d.url, to: dest)
                pane.reloadCurrentLocation()
                pane.selectedIDs = ["disk:\(dest.path)"]
            } catch {
                showStatusBanner(title: "Ошибка переименования", detail: error.localizedDescription, isError: true)
            }
        case .archive(let node):
            guard let arcURL = pane.location.activeArchiveLayer?.archiveFileURL else { return }
            let parent = VirtualArchiveTree.parentPath(of: node.path) ?? ""
            let newPath = parent.isEmpty ? trimmed : "\(parent)/\(trimmed)"
            let pwd = pane.currentArchivePassword

            runBackgroundOperation(title: "Переименование в архиве", initialDetail: trimmed) { flag, report in
                try SevenZipEngine.renameItems(
                    in: arcURL,
                    pairs: [(oldPath: node.path, newPath: newPath)],
                    password: pwd
                ) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } onSuccess: { [weak self] in
                self?.reloadPanesShowingArchive(arcURL)
                self?.showTransientSuccess("Переименовано в «\(trimmed)»")
            }
        }
    }

    func presentNewFolderDialog() {
        let pane = activePane
        if pane.location.isInsideArchive && pane.activeArchiveSummary?.isUpdatable != true {
            showStatusBanner(title: "Только чтение", detail: "Нельзя создать папку внутри архива только для чтения.", isError: true)
            return
        }
        newFolderSheet = NewFolderSheetRequest(paneSide: activeSide)
    }

    func executeCreateFolder(request: NewFolderSheetRequest, folderName: String) {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let pane = (request.paneSide == .left) ? leftPane : rightPane

        switch pane.location {
        case .diskFolder(let folder):
            let target = folder.appendingPathComponent(trimmed, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                pane.reloadCurrentLocation()
                pane.selectedIDs = ["disk:\(target.path)"]
            } catch {
                showStatusBanner(title: "Не удалось создать папку", detail: error.localizedDescription, isError: true)
            }

        case .archive(_, let layers, let subpath):
            guard let arcURL = layers.last?.archiveFileURL else { return }
            let cleanSub = VirtualArchiveTree.normalize(subpath)
            let relPath = cleanSub.isEmpty ? trimmed : "\(cleanSub)/\(trimmed)"
            let pwd = pane.currentArchivePassword

            runBackgroundOperation(title: "Создание папки в архиве", initialDetail: trimmed) { flag, report in
                let fm = FileManager.default
                let stage = fm.temporaryDirectory.appendingPathComponent("SevenZipMac-Mkdir-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: stage) }
                let dirOnDisk = stage.appendingPathComponent(relPath, isDirectory: true)
                try fm.createDirectory(at: dirOnDisk, withIntermediateDirectories: true)

                try SevenZipEngine.createOrUpdateArchive(
                    at: arcURL,
                    inputPaths: [relPath],
                    baseDirectory: stage,
                    options: CompressionOptions(excludeMacOSMetadata: true),
                    password: pwd
                ) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } onSuccess: { [weak self] in
                self?.reloadPanesShowingArchive(arcURL)
                self?.showTransientSuccess("Папка «\(trimmed)» создана в архиве")
            }
        }
    }

    func deleteSelectedItems() {
        let pane = activePane
        let selected = pane.selectedActionableRows
        guard !selected.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning

        switch pane.location {
        case .diskFolder:
            alert.messageText = "Переместить выбранные объекты (\(selected.count)) в Корзину?"
            alert.informativeText = selected.prefix(5).map(\.name).joined(separator: "\n")
            alert.addButton(withTitle: "В Корзину")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            for row in selected {
                if case .disk(let d) = row {
                    try? FileManager.default.trashItem(at: d.url, resultingItemURL: nil)
                }
            }
            pane.reloadCurrentLocation()

        case .archive(_, let layers, _):
            guard let arcURL = layers.last?.archiveFileURL,
                  pane.activeArchiveSummary?.isUpdatable == true else {
                showStatusBanner(title: "Только чтение", detail: "Этот формат архива не поддерживает удаление элементов.", isError: true)
                return
            }
            alert.messageText = "Удалить выбранные элементы (\(selected.count)) из архива?"
            alert.informativeText = "Действие перезапишет архив «\(arcURL.lastPathComponent)» без этих элементов."
            alert.addButton(withTitle: "Удалить из архива")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let paths: [String] = selected.compactMap {
                if case .archive(let n) = $0 { return n.path }
                return nil
            }
            let pwd = pane.currentArchivePassword
            runBackgroundOperation(title: "Удаление из архива", initialDetail: arcURL.lastPathComponent) { flag, report in
                try SevenZipEngine.deleteItems(
                    in: arcURL,
                    archivePaths: paths,
                    password: pwd
                ) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } onSuccess: { [weak self] in
                self?.reloadPanesShowingArchive(arcURL)
                self?.showTransientSuccess("Удалено элементов: \(paths.count)")
            }
        }
    }

    func presentProperties() {
        let pane = activePane
        propertiesSheet = PropertiesSheetRequest(
            location: pane.location,
            summary: pane.activeArchiveSummary,
            selectedRows: pane.selectedActionableRows
        )
    }

    // MARK: - Helpers

    private func makeInteractiveOverwriteBridge() -> @Sendable (OverwriteConflict) -> OverwriteDecision {
        return { [weak self] conflict in
            let sem = DispatchSemaphore(value: 0)
            let replyBox = OverwriteReplyBox()
            Task { @MainActor [weak self] in
                guard let self else {
                    replyBox.set(.cancel)
                    sem.signal()
                    return
                }
                self.overwriteConflictSheet = OverwriteConflictSheetRequest(conflict: conflict) { decision in
                    replyBox.set(decision)
                    sem.signal()
                }
            }
            sem.wait()
            return replyBox.get()
        }
    }

    private func wirePaneCallbacks(_ pane: PaneViewModel) {
        pane.onRequestPassword = { [weak self] archiveURL, isRetry, completion in
            guard let self else {
                completion(nil)
                return
            }
            self.passwordPrompt = PasswordPromptRequest(
                archiveURL: archiveURL,
                isRetryAfterFailure: isRetry
            ) { supplied, remember in
                if let supplied, !supplied.isEmpty {
                    pane.storePassword(supplied, for: archiveURL, saveToKeychain: remember)
                }
                completion(supplied)
            }
        }
        pane.onArchiveOpened = { [weak self] url in
            guard let self else { return }
            let std = url.standardizedFileURL
            self.recentArchiveURLs.removeAll { $0.standardizedFileURL == std }
            self.recentArchiveURLs.insert(std, at: 0)
            if self.recentArchiveURLs.count > 8 {
                self.recentArchiveURLs = Array(self.recentArchiveURLs.prefix(8))
            }
            self.persistSessionState()
        }
        pane.onLocationChanged = { [weak self] in
            self?.persistSessionState()
        }
    }

    private func reloadPanesShowingArchive(_ archiveURL: URL) {
        let std = archiveURL.standardizedFileURL
        if leftPane.location.activeArchiveLayer?.archiveFileURL.standardizedFileURL == std {
            leftPane.reloadCurrentLocation(forceReopenArchive: true)
        }
        if rightPane.location.activeArchiveLayer?.archiveFileURL.standardizedFileURL == std {
            rightPane.reloadCurrentLocation(forceReopenArchive: true)
        }
    }

    private func runBackgroundOperation(
        title: String,
        initialDetail: String,
        work: @escaping @Sendable (CancellationFlag, @escaping @Sendable (ArchiveProgress) -> Void) throws -> Void,
        onSuccess: @escaping @MainActor () -> Void,
        onPasswordNeeded: (@MainActor (Bool) -> Void)? = nil
    ) {
        let flag = CancellationFlag()
        currentCancellation = flag
        operationBanner = OperationBannerState(
            title: title,
            detail: initialDetail,
            fraction: nil,
            isRunning: true,
            isError: false
        )

        let reportProgress: @Sendable (ArchiveProgress) -> Void = { [weak self] prog in
            Task { @MainActor [weak self] in
                guard let self, self.currentCancellation === flag else { return }
                self.operationBanner = OperationBannerState(
                    title: title,
                    detail: prog.currentItem ?? initialDetail,
                    fraction: prog.fraction,
                    isRunning: true,
                    isError: false
                )
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try work(flag, reportProgress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.currentCancellation === flag {
                        self.currentCancellation = nil
                        self.operationBanner = nil
                    }
                    onSuccess()
                }
            } catch let err as ArchiveError where err == .passwordRequired || err == .wrongPassword {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.currentCancellation === flag {
                        self.currentCancellation = nil
                        self.operationBanner = nil
                    }
                    if let onPasswordNeeded {
                        onPasswordNeeded(err == .wrongPassword)
                    } else {
                        self.showStatusBanner(title: title, detail: err.localizedDescription, isError: true)
                    }
                }
            } catch ArchiveError.cancelled {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.currentCancellation = nil
                    self.operationBanner = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.currentCancellation = nil
                    self.showStatusBanner(title: "Ошибка: \(title)", detail: error.localizedDescription, isError: true)
                }
            }
        }
    }

    func showStatusBanner(title: String, detail: String, isError: Bool) {
        operationBanner = OperationBannerState(
            title: title,
            detail: detail,
            fraction: nil,
            isRunning: false,
            isError: isError
        )
    }

    func showTransientSuccess(_ message: String) {
        operationBanner = OperationBannerState(
            title: "Готово",
            detail: message,
            fraction: 1.0,
            isRunning: false,
            isError: false
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.operationBanner?.detail == message {
                self?.operationBanner = nil
            }
        }
    }

    static func archiveBaseName(for url: URL) -> String {
        SmartExtractionPlanner.archiveBaseName(for: url)
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
