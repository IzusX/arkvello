import AppKit
import ArchiveCore
import Foundation

// Copy, move and drop between disk and archive panes.
extension AppViewModel {
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
        let originSide = activeSide
        let originLocation = src.location
        let originSelection = src.selectedIDs
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
            ) { flag, report in
                try DiskTransfer.transfer(urls, to: destFolder, move: move, cancellation: flag,
                                          overwrite: { interactiveOverwrite(flag, $0) }, progress: report)
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
            let canDeleteFromArc = move && (src.canModifyArchive)
            let pwd = src.currentArchivePassword
            let enc = src.archiveEncoding
            let arcURL = topLayer.archiveFileURL
            let strip = src.isShowingFlattenedPaths ? "" : srcSubpath
            let fullPaths = !src.isShowingFlattenedPaths
            let interactiveOverwrite = makeInteractiveOverwriteBridge()

            runBackgroundOperation(
                title: canDeleteFromArc ? "Извлечение с удалением" : "Извлечение в соседнюю панель",
                initialDetail: destFolder.lastPathComponent
            ) { flag, report in
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: enc, progress: { _ in !flag.isCancelled })
                let tree = try VirtualArchiveTree(entries: opened.entries, checkCancellation: flag.check)
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
                        let decision = interactiveOverwrite(flag, conflict)
                        if decision == .skip || decision == .skipAll { skippedAny = true }
                        return decision
                    },
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
                opened.close()

                try flag.check()
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
                    if ok, self.activeSide == originSide, src.location == originLocation, src.selectedIDs == originSelection { self.copyOrMoveSelectionAcrossPanes(move: move) }
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
              dstPane.canModifyArchive else {
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
                let stageRoot = fm.temporaryDirectory.appendingPathComponent("Arkvello-AddStage-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: stageRoot) }
                let nestedStage = stageRoot.appendingPathComponent(cleanSubpath, isDirectory: true)
                try fm.createDirectory(at: nestedStage, withIntermediateDirectories: true)

                var relInputs: [String] = []
                for u in urls {
                    try flag.check()
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

            try flag.check()
            if deleteSourcesAfter {
                for u in urls {
                    try flag.check()
                    try fm.trashItem(at: u, resultingItemURL: nil)
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
            runBackgroundOperation(title: "Копирование", initialDetail: destFolder.lastPathComponent) { flag, report in
                try DiskTransfer.transfer(urls, to: destFolder, move: false, cancellation: flag,
                                          overwrite: { interactiveOverwrite(flag, $0) }, progress: report)
            } onSuccess: { [weak self] in
                pane.reloadCurrentLocation()
                self?.showTransientSuccess("Файлы скопированы в «\(destFolder.lastPathComponent)»")
            }

        case .archive:
            addDiskFiles(urls, intoArchivePane: pane, deleteSourcesAfter: false)
        }
    }
}
