import AppKit
import ArchiveCore
import Foundation
import Combine

// Navigation, pane callbacks and persisted preferences.
extension AppViewModel {
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

    func restoreSessionIfAvailable() {
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
        guard sessionPersistenceEnabled, !isRestoringSession else { return }
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
        operations.cancel()
        pendingOverwriteResolution = nil
        overwriteConflictSheet = nil
        if operationBanner?.isRunning == true { operationBanner?.detail = "Отмена…" }
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
    func wirePaneCallbacks(_ pane: PaneViewModel) {
        // Toolbar actions read pane selection and loading state through AppViewModel.
        // Forward changes so their enabled state tracks the currently visible rows.
        pane.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &paneSubscriptions)
        let passwordOwner = UUID()
        pane.onCancelPasswordRequest = { [weak self] url in
            self?.passwordPrompts.cancel(for: url, owner: passwordOwner)
        }
        pane.onRequestPassword = { [weak self, weak pane] archiveURL, isRetry, completion in
            guard let self, let pane else {
                completion(nil)
                return
            }
            self.passwordPrompts.enqueue(
                owner: passwordOwner, archiveURL: archiveURL,
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

    func reloadPanesShowingArchive(_ archiveURL: URL) {
        let std = archiveURL.standardizedFileURL
        if leftPane.location.activeArchiveLayer?.archiveFileURL.standardizedFileURL == std {
            leftPane.reloadCurrentLocation(forceReopenArchive: true)
        }
        if rightPane.location.activeArchiveLayer?.archiveFileURL.standardizedFileURL == std {
            rightPane.reloadCurrentLocation(forceReopenArchive: true)
        }
    }

}
