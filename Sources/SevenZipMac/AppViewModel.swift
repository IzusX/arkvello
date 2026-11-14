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
    let completion: (String?) -> Void
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

@MainActor
final class AppViewModel: ObservableObject {
    let leftPane: PaneViewModel
    let rightPane: PaneViewModel

    @Published var isDualPane: Bool = false
    @Published var activeSide: PaneSide = .left
    @Published var recentArchiveURLs: [URL] = []
    @Published var operationBanner: OperationBannerState?
    @Published private(set) var modifiedEditSessions: [TempEditSession] = []

    @Published var passwordPrompt: PasswordPromptRequest?
    @Published var compressSheet: CompressSheetRequest?
    @Published var extractSheet: ExtractSheetRequest?
    @Published var renameSheet: RenameSheetRequest?
    @Published var newFolderSheet: NewFolderSheetRequest?
    @Published var propertiesSheet: PropertiesSheetRequest?

    private var allEditSessions: [TempEditSession] = []
    private var currentCancellation: CancellationFlag?
    private let quickLookTempDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home

        self.leftPane = PaneViewModel(side: .left, initialFolder: downloads)
        self.rightPane = PaneViewModel(side: .right, initialFolder: desktop)
        self.quickLookTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipMac-QuickLook-\(UUID().uuidString)", isDirectory: true)

        wirePaneCallbacks(leftPane)
        wirePaneCallbacks(rightPane)
    }

    deinit {
        for s in allEditSessions { s.cleanup() }
        try? FileManager.default.removeItem(at: quickLookTempDir)
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
        list.append(SidebarShortcut(id: "root", title: "Macintosh HD", systemImage: "internaldrive", url: URL(fileURLWithPath: "/")))
        return list
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

    // MARK: - Item Activation & Quick Look

    func activateRow(_ row: PaneRowItem, in side: PaneSide) {
        activeSide = side
        let pane = (side == .left) ? leftPane : rightPane

        switch row {
        case .parentDirectory:
            pane.goUp()

        case .disk(let d):
            if d.isDirectory {
                pane.navigate(to: .diskFolder(d.url))
            } else if d.isArchiveContainer {
                pane.openArchiveFile(d.url)
            } else {
                NSWorkspace.shared.open(d.url)
            }

        case .archive(let node):
            if node.isDirectory {
                pane.navigate(to: pane.location.enteringArchiveSubfolder(node.path))
            } else if row.isArchiveFile {
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
                try arc.extract(
                    indices: indices,
                    to: slot,
                    stripPrefix: pane.location.archiveSubpath,
                    fullPaths: true,
                    overwrite: .overwriteAll,
                    password: pane.currentArchivePassword
                )
                let previewURLs = entries.compactMap { entry -> URL? in
                    let rel: String
                    let sub = VirtualArchiveTree.normalize(pane.location.archiveSubpath)
                    if !sub.isEmpty && entry.path.hasPrefix(sub + "/") {
                        rel = String(entry.path.dropFirst(sub.count + 1))
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
                // Allow picking files via NSOpenPanel if nothing selected
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
            extractSheet = ExtractSheetRequest(
                paneSide: pane.side,
                archiveURL: topLayer.archiveFileURL,
                selectedPaths: selectedPaths,
                stripPrefix: selectedPaths.isEmpty ? "" : subpath,
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
        password: String?
    ) {
        let paths = inputURLs.map(\.path)
        runBackgroundOperation(title: "Создание архива", initialDetail: archiveURL.lastPathComponent) { flag, report in
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }
            try SevenZipEngine.createOrUpdateArchive(
                at: archiveURL,
                inputPaths: paths,
                baseDirectory: nil,
                options: options,
                password: password
            ) { prog in
                report(prog)
                return !flag.isCancelled
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            if let password, !password.isEmpty {
                self.leftPane.storePassword(password, for: archiveURL)
                self.rightPane.storePassword(password, for: archiveURL)
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
        fullPaths: Bool,
        overwriteMode: OverwriteMode,
        passwordOverride: String?
    ) {
        let pane = (request.paneSide == .left) ? leftPane : rightPane
        let finalDest: URL
        if createArchiveSubfolder {
            let folderName = Self.archiveBaseName(for: request.archiveURL)
            finalDest = destinationFolder.appendingPathComponent(folderName, isDirectory: true)
        } else {
            finalDest = destinationFolder
        }

        let pwd = (passwordOverride?.isEmpty == false)
            ? passwordOverride
            : pane.currentArchivePassword

        let archiveURL = request.archiveURL
        let selectedPaths = request.selectedPaths
        let stripPrefix = request.stripPrefix

        runBackgroundOperation(title: "Извлечение", initialDetail: archiveURL.lastPathComponent) { flag, report in
            let opened = try OpenArchive(url: archiveURL, password: pwd)
            defer { opened.close() }

            let indices: [UInt32]?
            if selectedPaths.isEmpty {
                indices = nil
            } else {
                let tree = VirtualArchiveTree(entries: opened.entries)
                indices = tree.extractionIndices(for: selectedPaths)
            }

            try opened.extract(
                indices: indices,
                to: finalDest,
                stripPrefix: stripPrefix,
                fullPaths: fullPaths,
                overwrite: overwriteMode,
                password: pwd,
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
            self.showTransientSuccess("Извлечено в «\(finalDest.lastPathComponent)»")
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompt = PasswordPromptRequest(
                archiveURL: archiveURL,
                isRetryAfterFailure: wrong
            ) { supplied in
                guard let supplied, !supplied.isEmpty else { return }
                self.executeExtraction(
                    request: request,
                    destinationFolder: destinationFolder,
                    createArchiveSubfolder: createArchiveSubfolder,
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

        let pwd = pane.currentArchivePassword
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
            self.passwordPrompt = PasswordPromptRequest(archiveURL: archiveURL, isRetryAfterFailure: wrong) { supplied in
                guard let supplied, !supplied.isEmpty else { return }
                pane.storePassword(supplied, for: archiveURL)
                self.testCurrentArchive()
            }
        }
    }

    /// F5 (Copy) / F6 (Move) between left and right panes, matching 7zFM dual-pane semantics.
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
            runBackgroundOperation(
                title: move ? "Перемещение" : "Копирование",
                initialDetail: "\(urls.count) объ."
            ) { flag, _ in
                let fm = FileManager.default
                for u in urls {
                    if flag.isCancelled { throw ArchiveError.cancelled }
                    let target = destFolder.appendingPathComponent(u.lastPathComponent)
                    if target.standardizedFileURL == u.standardizedFileURL { continue }
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
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
            let arcURL = topLayer.archiveFileURL

            runBackgroundOperation(
                title: move ? "Извлечение с удалением" : "Извлечение в соседнюю панель",
                initialDetail: destFolder.lastPathComponent
            ) { flag, report in
                let opened = try OpenArchive(url: arcURL, password: pwd)
                let tree = VirtualArchiveTree(entries: opened.entries)
                let indices = tree.extractionIndices(for: selectedPaths)
                try opened.extract(
                    indices: indices,
                    to: destFolder,
                    stripPrefix: srcSubpath,
                    fullPaths: true,
                    overwrite: .overwriteAll,
                    password: pwd,
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
                opened.close()

                if canDeleteFromArc {
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
                detail: "Откройте в целевой панели папку на диске или перетащите файлы напрямую.",
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

        runBackgroundOperation(title: "Добавление в архив", initialDetail: topLayer.displayName) { flag, report in
            let fm = FileManager.default
            if cleanSubpath.isEmpty {
                try SevenZipEngine.createOrUpdateArchive(
                    at: arcURL,
                    inputPaths: urls.map(\.path),
                    baseDirectory: nil,
                    options: CompressionOptions(),
                    password: pwd
                ) { prog in
                    report(prog)
                    return !flag.isCancelled
                }
            } else {
                // Stage files under `<temp>/<targetSubpath>/...` using APFS CoW copyItem so relative paths inside archive match
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
                    options: CompressionOptions(),
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
            runBackgroundOperation(title: "Копирование", initialDetail: destFolder.lastPathComponent) { flag, _ in
                let fm = FileManager.default
                for u in urls {
                    if flag.isCancelled { throw ArchiveError.cancelled }
                    let target = destFolder.appendingPathComponent(u.lastPathComponent)
                    if target.standardizedFileURL == u.standardizedFileURL { continue }
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
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
                    options: CompressionOptions(),
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

    private func wirePaneCallbacks(_ pane: PaneViewModel) {
        pane.onRequestPassword = { [weak self] archiveURL, isRetry, completion in
            guard let self else {
                completion(nil)
                return
            }
            self.passwordPrompt = PasswordPromptRequest(
                archiveURL: archiveURL,
                isRetryAfterFailure: isRetry,
                completion: completion
            )
        }
        pane.onArchiveOpened = { [weak self] url in
            guard let self else { return }
            let std = url.standardizedFileURL
            self.recentArchiveURLs.removeAll { $0.standardizedFileURL == std }
            self.recentArchiveURLs.insert(std, at: 0)
            if self.recentArchiveURLs.count > 8 {
                self.recentArchiveURLs = Array(self.recentArchiveURLs.prefix(8))
            }
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
        let name = url.lastPathComponent
        let compoundSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".7z.001", ".zip.001"]
        for suffix in compoundSuffixes where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
