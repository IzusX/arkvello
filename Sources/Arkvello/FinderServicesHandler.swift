import AppKit
import Foundation

/// Provides macOS Finder right-click context menu actions (`NSServices` / Quick Actions)
/// mirroring Windows 7-Zip shell menu: Extract Here, Extract to Folder, Add to .7z, Add to Archive..., Test Archive.
@MainActor
final class FinderServicesHandler: NSObject {
    private unowned let appVM: AppViewModel

    init(appVM: AppViewModel) {
        self.appVM = appVM
    }

    private func readPasteboardURLs(_ pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func serviceExtractHere(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = readPasteboardURLs(pboard)
        guard !urls.isEmpty else { return }
        guard appVM.beginFinderService() else { return }
        NSApp.activate(ignoringOtherApps: true)
        appVM.finderServiceExtract(urls: urls, alwaysCreateSubfolder: false)
    }

    @objc func serviceExtractToSubfolder(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = readPasteboardURLs(pboard)
        guard !urls.isEmpty else { return }
        guard appVM.beginFinderService() else { return }
        NSApp.activate(ignoringOtherApps: true)
        appVM.finderServiceExtract(urls: urls, alwaysCreateSubfolder: true)
    }

    @objc func serviceQuickCompress7z(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = readPasteboardURLs(pboard)
        guard !urls.isEmpty else { return }
        guard appVM.beginFinderService() else { return }
        NSApp.activate(ignoringOtherApps: true)
        appVM.finderServiceQuickCompress7z(urls: urls)
    }

    @objc func serviceCompressDialog(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = readPasteboardURLs(pboard)
        guard !urls.isEmpty else { return }
        guard appVM.beginFinderService() else { return }
        NSApp.activate(ignoringOtherApps: true)
        appVM.finderServiceOpenCompressDialog(urls: urls)
    }

    @objc func serviceTestArchive(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = readPasteboardURLs(pboard)
        guard let first = urls.first else { return }
        guard appVM.beginFinderService() else { return }
        NSApp.activate(ignoringOtherApps: true)
        appVM.openExternalURLs([first])
        appVM.testCurrentArchive()
    }
}
