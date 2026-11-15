import AppKit
import ArchiveCore
import Foundation

// System pasteboard import and archive export.
extension AppViewModel {
    func copySelectionToPasteboard() {
        let pane = activePane
        let originSide = activeSide
        let originLocation = pane.location
        let originSelection = pane.selectedIDs
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
                let opened = try OpenArchive(url: arcURL, password: pwd, encoding: enc, progress: { _ in !flag.isCancelled })
                defer { opened.close() }
                let tree = try VirtualArchiveTree(entries: opened.entries, checkCancellation: flag.check)
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
                    if ok, self?.activeSide == originSide, pane.location == originLocation, pane.selectedIDs == originSelection { self?.copySelectionToPasteboard() }
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
}
