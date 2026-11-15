import AppKit
import ArchiveCore
import Foundation

// Rename, new folder, deletion and properties.
extension AppViewModel {
    func presentRenameDialog() {
        guard !operations.isRunning else { NSSound.beep(); return }
        guard let first = activePane.selectedActionableRows.first else { return }
        if activePane.location.isInsideArchive && !activePane.canModifyArchive {
            showStatusBanner(title: "Только чтение", detail: "Этот формат архива не поддерживает переименование.", isError: true)
            return
        }
        renameSheet = RenameSheetRequest(paneSide: activeSide, row: first)
    }

    func executeRename(request: RenameSheetRequest, newName: String) {
        guard !operations.isRunning else { NSSound.beep(); return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let pane = (request.paneSide == .left) ? leftPane : rightPane

        switch request.row {
        case .parentDirectory:
            return
        case .disk(let d):
            let dest = d.url.deletingLastPathComponent().appendingPathComponent(trimmed)
            let origin = pane.location
            runBackgroundOperation(title: "Переименование", initialDetail: d.name) { flag, _ in
                try flag.check()
                try FileManager.default.moveItem(at: d.url, to: dest)
            } onSuccess: {
                pane.reloadCurrentLocation(highlightItemNamed: pane.location == origin ? dest.lastPathComponent : nil)
            }
        case .archive(let node):
            guard pane.canModifyArchive, let arcURL = pane.location.activeArchiveLayer?.archiveFileURL else { return }
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
        guard !operations.isRunning else { NSSound.beep(); return }
        let pane = activePane
        if pane.location.isInsideArchive && !pane.canModifyArchive {
            showStatusBanner(title: "Только чтение", detail: "Нельзя создать папку внутри архива только для чтения.", isError: true)
            return
        }
        newFolderSheet = NewFolderSheetRequest(paneSide: activeSide)
    }

    func executeCreateFolder(request: NewFolderSheetRequest, folderName: String) {
        guard !operations.isRunning else { NSSound.beep(); return }
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let pane = (request.paneSide == .left) ? leftPane : rightPane

        switch pane.location {
        case .diskFolder(let folder):
            let target = folder.appendingPathComponent(trimmed, isDirectory: true)
            let origin = pane.location
            runBackgroundOperation(title: "Создание папки", initialDetail: trimmed) { flag, _ in
                try flag.check()
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } onSuccess: {
                pane.reloadCurrentLocation(highlightItemNamed: pane.location == origin ? target.lastPathComponent : nil)
            }

        case .archive(_, let layers, let subpath):
            guard pane.canModifyArchive, let arcURL = layers.last?.archiveFileURL else { return }
            let cleanSub = VirtualArchiveTree.normalize(subpath)
            let relPath = cleanSub.isEmpty ? trimmed : "\(cleanSub)/\(trimmed)"
            let pwd = pane.currentArchivePassword

            runBackgroundOperation(title: "Создание папки в архиве", initialDetail: trimmed) { flag, report in
                let fm = FileManager.default
                let stage = fm.temporaryDirectory.appendingPathComponent("Arkvello-Mkdir-\(UUID().uuidString)", isDirectory: true)
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
        guard !operations.isRunning else { NSSound.beep(); return }
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

            let urls = selected.compactMap { row -> URL? in
                if case .disk(let disk) = row { return disk.url }; return nil
            }
            runBackgroundOperation(title: "Перемещение в Корзину", initialDetail: "\(urls.count) объ.") { flag, report in
                for (index, url) in urls.enumerated() {
                    try flag.check()
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    report(ArchiveProgress(completedBytes: UInt64(index + 1), totalBytes: UInt64(urls.count), currentItem: url.lastPathComponent))
                }
            } onSuccess: { pane.reloadCurrentLocation() }

        case .archive(_, let layers, _):
            guard let arcURL = layers.last?.archiveFileURL,
                  pane.canModifyArchive else {
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
        guard !operations.isRunning else { NSSound.beep(); return }
        let pane = activePane
        propertiesSheet = PropertiesSheetRequest(
            location: pane.location,
            summary: pane.activeArchiveSummary,
            selectedRows: pane.selectedActionableRows
        )
    }
}
