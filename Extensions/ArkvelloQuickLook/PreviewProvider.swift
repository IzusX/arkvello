import CSevenZip
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Metadata-only previews. No extraction, password callbacks, keychain or shared app state.
@objc(ArkvelloPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 760, height: 560)) { reply in
            reply.stringEncoding = .utf8
            return ArchiveListing.html(for: url)
        }
        handler(reply, nil)
    }
}

