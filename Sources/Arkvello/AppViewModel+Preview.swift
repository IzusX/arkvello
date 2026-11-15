import AppKit
import ArchiveCore
import Foundation

// Item activation, Quick Look and external edit sessions.
extension AppViewModel {
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

            let slot = quickLookTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let stripSub = pane.isShowingFlattenedPaths ? "" : pane.location.archiveSubpath
            let password = pane.currentArchivePassword
            let previewBox = OperationResultBox<[URL]>([])
            let origin = pane.location
            runBackgroundOperation(title: "Подготовка предпросмотра", initialDetail: arc.url.lastPathComponent) { flag, report in
                var completed = false
                defer { if !completed { try? FileManager.default.removeItem(at: slot) } }
                try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
                try arc.extract(indices: entries.map(\.index), to: slot, stripPrefix: stripSub, fullPaths: true,
                    overwrite: .overwriteAll, password: password, progress: { value in report(value); return !flag.isCancelled })
                try flag.check()
                previewBox.value = entries.compactMap { entry in
                    let cleanSub = VirtualArchiveTree.normalize(stripSub)
                    let rel = !cleanSub.isEmpty && entry.path.hasPrefix(cleanSub + "/")
                        ? String(entry.path.dropFirst(cleanSub.count + 1)) : entry.path
                    let url = slot.appendingPathComponent(rel)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }
                completed = true
            } onSuccess: {
                QuickLookCoordinator.shared.togglePreview(urls: previewBox.value)
            } onPasswordNeeded: { [weak self] wrong in
                guard pane.location == origin else { return }
                pane.requestPasswordForCurrentArchive(wrongAttempt: wrong) { ok in
                    if ok, pane.location == origin { self?.triggerQuickLook(in: side) }
                }
            }
        }
    }

    private func openArchiveEntryExternally(node: VirtualArchiveNode, in pane: PaneViewModel) {
        guard let arc = pane.openArchive, let entry = node.entry else { return }
        let pwd = pane.currentArchivePassword
        let sessionBox = OperationResultBox<TempEditSession?>(nil)
        let content = pane.retainedArchiveContent
        let allowUpdates = pane.canModifyArchive
        let origin = pane.location
        runBackgroundOperation(title: "Подготовка файла", initialDetail: entry.name) { [weak self] flag, report in
            let session = try TempEditSession(archive: arc, entry: entry, password: pwd, allowUpdates: allowUpdates,
                progress: { value in report(value); return !flag.isCancelled },
                onExternalModification: { [weak self] in
                    Task { @MainActor [weak self] in self?.refreshModifiedEditSessions() }
                })
            try flag.check()
            sessionBox.value = session
        } onSuccess: { [weak self] in
            guard let self, let session = sessionBox.value else { return }
            self.editSessions.track(session, content: content, password: pwd)
            NSWorkspace.shared.open(session.extractedFileURL)
        } onPasswordNeeded: { [weak self] wrong in
            guard pane.location == origin else { return }
            pane.requestPasswordForCurrentArchive(wrongAttempt: wrong) { ok in
                if ok, pane.location == origin { self?.openArchiveEntryExternally(node: node, in: pane) }
            }
        }
    }

    func refreshModifiedEditSessions() {
        let id = UUID()
        editCheckID = id
        let sessions = editSessions.sessions
        let worker = editCheckWorker
        Task { [weak self] in
            let modified = try? await worker.run { sessions.filter { $0.isArchiveUpdatable && $0.hasUncommittedChanges() } }
            guard let self, self.editCheckID == id else { return }
            self.modifiedEditSessions = modified ?? []
        }
    }

    func commitModifiedSession(_ session: TempEditSession) {
        guard let lease = editSessions.lease(for: session) else { return }
        let pwd = editSessions.password(for: session)
            ?? leftPane.password(for: session.archiveURL) ?? rightPane.password(for: session.archiveURL)
        runBackgroundOperation(title: "Обновление архива", initialDetail: session.archiveEntryPath) { flag, report in
            defer { withExtendedLifetime(lease) {} }
            try session.commitChanges(password: pwd) { prog in
                report(prog)
                return !flag.isCancelled
            }
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.refreshModifiedEditSessions()
            self.reloadPanesShowingArchive(session.archiveURL)
            self.showTransientSuccess("Файл «\(session.extractedFileURL.lastPathComponent)» обновлён в архиве")
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompts.enqueue(archiveURL: session.archiveURL, isRetryAfterFailure: wrong) { [weak self] supplied, remember in
                guard let self, let supplied, !supplied.isEmpty,
                      self.editSessions.lease(for: session) != nil else { return }
                self.editSessions.remember(supplied, for: session)
                self.leftPane.storePassword(supplied, for: session.archiveURL, saveToKeychain: remember)
                self.commitModifiedSession(session)
            }
        }
    }

    func discardModifiedSession(_ session: TempEditSession) {
        guard !operations.isRunning else { NSSound.beep(); return }
        session.cleanup()
        editSessions.remove(session)
        refreshModifiedEditSessions()
    }
}
