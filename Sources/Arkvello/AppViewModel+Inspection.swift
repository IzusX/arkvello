import AppKit
import ArchiveCore
import Foundation

// Archive integrity checks and file digests.
extension AppViewModel {
    func computeChecksumsForSelection() {
        let pane = activePane
        let originSide = activeSide
        let originLocation = pane.location
        let originSelection = pane.selectedIDs
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
            let digestsBox = OperationResultBox<[ArchiveHashDigest]>([])
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
            let digestsBox = OperationResultBox<[ArchiveHashDigest]>([])
            runBackgroundOperation(title: "Расчёт контрольных сумм", initialDetail: node.name) { flag, report in
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: enc, progress: { _ in !flag.isCancelled })
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
                    if ok, self?.activeSide == originSide, pane.location == originLocation, pane.selectedIDs == originSelection { self?.computeChecksumsForSelection() }
                }
            }
        }
    }

    func testCurrentArchive() {
        let pane = activePane
        let originSide = activeSide
        let origin = pane.location
        let selection = pane.selectedIDs
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
            let opened = try OpenArchive(url: archiveURL, password: pwd, progress: { _ in !flag.isCancelled })
            defer { opened.close() }
            try opened.test(password: pwd, progress: { prog in
                report(prog)
                return !flag.isCancelled
            })
        } onSuccess: { [weak self] in
            self?.showTransientSuccess("Проверка пройдена: ошибок в «\(archiveURL.lastPathComponent)» не обнаружено")
        } onPasswordNeeded: { [weak self] wrong in
            guard let self else { return }
            self.passwordPrompts.enqueue(archiveURL: archiveURL, isRetryAfterFailure: wrong) { supplied, remember in
                guard let supplied, !supplied.isEmpty else { return }
                pane.storePassword(supplied, for: archiveURL, saveToKeychain: remember)
                if self.activeSide == originSide, pane.location == origin, pane.selectedIDs == selection { self.testCurrentArchive() }
            }
        }
    }
}
