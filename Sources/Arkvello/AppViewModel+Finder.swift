import AppKit
import ArchiveCore
import Foundation

// Finder service lifecycle and sequential batch extraction.
extension AppViewModel {
    func beginFinderService() -> Bool {
        guard currentCancellation == nil, compressSheet == nil, passwordPrompt == nil,
              overwriteConflictSheet == nil, extractSheet == nil, renameSheet == nil,
              newFolderSheet == nil, propertiesSheet == nil, checksumSheet == nil,
              !showSettingsSheet, NSApp.modalWindow == nil else {
            NSSound.beep()
            return false
        }
        operationBanner = nil
        onFinderServiceRequested?()
        return true
    }

    func finishFinderServiceIfIdle() {
        guard currentCancellation == nil, compressSheet == nil, !passwordPrompts.hasRequests,
              overwriteConflictSheet == nil, operationBanner?.isError != true else { return }
        onFinderServiceFinished?()
    }
    func finderServiceExtract(urls: [URL], alwaysCreateSubfolder: Bool, passwordOverride: String? = nil) {
        let archives = urls.filter { SevenZipEngine.isBrowsableArchive(url: $0) }
        guard !archives.isEmpty else {
            showStatusBanner(title: "Нет архивов", detail: "Выберите архив для извлечения.", isError: true)
            return
        }
        extractFinderBatch(archives, alwaysCreateSubfolder: alwaysCreateSubfolder, passwordOverride: passwordOverride, completed: 0)
    }

    private func extractFinderBatch(_ archives: [URL], alwaysCreateSubfolder: Bool, passwordOverride: String?, completed: Int) {
        guard let firstArc = archives.first else { return }
        let elimDup = eliminateRootDuplication
        let pwd = passwordOverride ?? KeychainPasswordStore.password(for: firstArc)
        let interactiveOverwrite = makeInteractiveOverwriteBridge()

        runBackgroundOperation(title: "Извлечение (Finder)", initialDetail: firstArc.lastPathComponent) { flag, report in
            do {
                let arcURL = firstArc
                if flag.isCancelled { throw ArchiveError.cancelled }
                let localPwd = pwd
                let opened = try OpenArchive(url: arcURL, password: localPwd, progress: { _ in !flag.isCancelled })
                defer { opened.close() }
                let tree = try VirtualArchiveTree(entries: opened.entries, checkCancellation: flag.check)

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
                    overwriteHandler: { interactiveOverwrite(flag, $0) },
                    progress: { prog in
                        report(prog)
                        return !flag.isCancelled
                    }
                )
            }
        } onSuccess: { [weak self] in
            self?.leftPane.reloadCurrentLocation()
            if self?.isDualPane == true { self?.rightPane.reloadCurrentLocation() }
            guard let self else { return }
            if archives.count > 1 {
                self.extractFinderBatch(Array(archives.dropFirst()), alwaysCreateSubfolder: alwaysCreateSubfolder, passwordOverride: nil, completed: completed + 1)
            } else {
                self.showTransientSuccess("Извлечено архивов: \(completed + 1)")
            }
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompts.enqueue(archiveURL: firstArc, isRetryAfterFailure: wrong) { supplied, remember in
                guard let supplied, !supplied.isEmpty else { return }
                self.leftPane.storePassword(supplied, for: firstArc, saveToKeychain: remember)
                self.extractFinderBatch(archives, alwaysCreateSubfolder: alwaysCreateSubfolder, passwordOverride: supplied, completed: completed)
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
}
