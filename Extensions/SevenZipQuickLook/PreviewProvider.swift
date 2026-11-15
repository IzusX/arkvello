import CSevenZip
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Metadata-only previews. No extraction, password callbacks, keychain or shared app state.
@objc(SevenZipPreviewProvider)
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

// Internal so the same metadata renderer can be exercised without launching Finder.
enum ArchiveListing {
    static let maxArchiveBytes: Int64 = 512 * 1024 * 1024
    static let maxMetadataItems: UInt32 = 20_000
    static let maxRows = 1_000
    static let maxHTMLBytes = 1024 * 1024
    static let maxNameBytes = 2048

    static func html(for url: URL) -> Data {
        let title = escape(String(url.lastPathComponent.prefix(512)))
        func notice(_ message: String) -> Data {
            document(title: title, body: "<p>\(escape(message))</p>")
        }
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            return notice("This file cannot be read for preview.")
        }
        guard Int64(size) <= maxArchiveBytes else {
            return notice("Preview is limited to archives up to 512 MiB. Open this archive in 7-Zip to browse it.")
        }

        var archive: OpaquePointer?
        var error: UnsafeMutablePointer<CChar>?
        // A nil password and nil callback intentionally prohibit credential access and prompts.
        let status = url.path.withCString { sz_archive_open($0, nil, nil, nil, &archive, &error) }
        defer {
            if let archive { sz_archive_close(archive) }
            if let error { sz_string_free(error) }
        }
        guard status == SZ_STATUS_OK, let archive else {
            if status == SZ_STATUS_ERR_PASSWORD_REQUIRED || status == SZ_STATUS_ERR_WRONG_PASSWORD {
                return notice("The archive's file names are encrypted. Open it in 7-Zip to enter a password. Quick Look does not access saved passwords.")
            }
            return notice("The archive cannot be listed. It may be damaged, unsupported, or require a password. Open it in 7-Zip for details.")
        }

        var summary = sz_archive_summary_t()
        var summaryError: UnsafeMutablePointer<CChar>?
        let summaryStatus = sz_archive_get_summary(archive, &summary, &summaryError)
        defer {
            sz_free_summary(&summary)
            if let summaryError { sz_string_free(summaryError) }
        }
        guard summaryStatus == SZ_STATUS_OK else { return notice("Archive metadata is unavailable.") }
        guard !summary.headers_encrypted else {
            return notice("The archive's file names are encrypted. Open it in 7-Zip to enter a password. Quick Look does not access saved passwords.")
        }
        // The bridge returns the complete metadata array; check its size before requesting it.
        guard summary.item_count <= maxMetadataItems else {
            return notice("This archive contains \(summary.item_count) entries, exceeding the 20,000-entry preview limit. Open it in 7-Zip to browse it.")
        }

        var items: UnsafeMutablePointer<sz_item_info_t>?
        var count: UInt32 = 0
        var itemsError: UnsafeMutablePointer<CChar>?
        let itemsStatus = sz_archive_get_items(archive, &items, &count, &itemsError)
        defer {
            if let items { sz_free_items(items, count) }
            if let itemsError { sz_string_free(itemsError) }
        }
        guard itemsStatus == SZ_STATUS_OK else { return notice("Archive entries could not be read.") }
        var body = "<p>\(count) entries · Metadata only; no files are extracted.</p><table><thead><tr><th>Name</th><th>Size</th><th>Kind</th></tr></thead><tbody>"
        var shown = 0
        if let items {
            for index in 0..<min(Int(count), maxRows) {
                let item = items[index]
                let name = escape(boundedName(item.path))
                let size = item.is_dir ? "—" : (item.has_size ? "\(item.size) B" : "—")
                let kind = item.is_dir ? "Folder" : (item.is_encrypted ? "Encrypted file" : (item.is_symlink ? "Symbolic link" : "File"))
                let row = "<tr><td>\(name)</td><td class=\"size\">\(size)</td><td>\(kind)</td></tr>"
                if body.utf8.count + row.utf8.count > maxHTMLBytes - 8192 { break }
                body += row
                shown += 1
            }
        }
        body += "</tbody></table>"
        if shown < Int(count) {
            body += "<p>Showing \(shown) of \(count) entries. Open in 7-Zip for the complete listing.</p>"
        }
        return document(title: title, body: body)
    }

    private static func boundedName(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "(unnamed)" }
        let length = strnlen(pointer, maxNameBytes)
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        return String(decoding: bytes, as: UTF8.self) + (length == maxNameBytes ? "…" : "")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func document(title: String, body: String) -> Data {
        Data("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="color-scheme" content="light dark"><title>\(title)</title>
        <style>body{font:13px -apple-system,sans-serif;margin:24px;color:CanvasText;background:Canvas}h1{font-size:20px;overflow-wrap:anywhere}p{line-height:1.5}table{border-collapse:collapse;width:100%;table-layout:fixed}th,td{text-align:left;padding:7px 8px;border-bottom:1px solid GrayText;overflow-wrap:anywhere}th:first-child{width:62%}.size{font-variant-numeric:tabular-nums}th{font-weight:600}</style>
        </head><body><h1>\(title)</h1>\(body)</body></html>
        """.utf8)
    }
}
