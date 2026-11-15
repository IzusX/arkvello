import AppKit
import ArchiveCore
import Foundation

// Archive creation and extraction dialogs and execution.
extension AppViewModel {
    func presentAddCompressDialog() {
        guard !operations.isRunning else { NSSound.beep(); return }
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
            guard let topLayer = layers.last, pane.canModifyArchive else {
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
        guard !operations.isRunning else { NSSound.beep(); return }
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
        guard !operations.isRunning else { NSSound.beep(); return }
        let paths = inputURLs.map(\.path)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            let alert = NSAlert()
            alert.messageText = "Заменить архив «\(archiveURL.lastPathComponent)»?"
            alert.informativeText = "Исходный архив сохранится, если создание новой версии завершится ошибкой или будет отменено."
            alert.addButton(withTitle: "Заменить")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else {
                finishFinderServiceIfIdle()
                return
            }
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
                    try flag.check()
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
        let finalFolderBox = OperationResultBox<URL>(destinationFolder)

        runBackgroundOperation(title: "Извлечение", initialDetail: archiveURL.lastPathComponent) { flag, report in
            let opened = try OpenArchive(url: archiveURL, password: pwd, encoding: enc, progress: { _ in !flag.isCancelled })
            defer { opened.close() }

            let tree = try VirtualArchiveTree(entries: opened.entries, checkCancellation: flag.check)
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
                overwriteHandler: overwriteMode == .askInteractive ? { interactiveOverwrite(flag, $0) } : nil,
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
            self.passwordPrompts.enqueue(
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
}
