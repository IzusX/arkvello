import AppKit
import Foundation
import Quartz

@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    private var previewURLs: [URL] = []

    func togglePreview(urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.previewURLs = urls

        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func updateIfVisible(urls: [URL]) {
        guard !urls.isEmpty,
              QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        self.previewURLs = urls
        panel.dataSource = self
        panel.reloadData()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated {
            guard previewURLs.indices.contains(index) else { return nil }
            return previewURLs[index]
        }
        return url.map { $0 as NSURL }
    }
}
