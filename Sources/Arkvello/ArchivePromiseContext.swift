import ArchiveCore
import Foundation

/// A drag owns its immutable source snapshot, including nested-archive workspaces.
/// Finder may fulfill the promise after the pane has navigated elsewhere.
final class ArchivePromiseContext: NSObject, @unchecked Sendable {
    let archiveURL: URL
    let itemPath: String
    let itemName: String
    let stripPrefix: String
    let password: String?
    let encoding: ArchiveNameEncoding
    private let content: PaneArchiveContent?

    init(archiveURL: URL, itemPath: String, itemName: String, stripPrefix: String,
         password: String?, encoding: ArchiveNameEncoding, content: PaneArchiveContent?) {
        self.archiveURL = archiveURL
        self.itemPath = itemPath
        self.itemName = itemName
        self.stripPrefix = stripPrefix
        self.password = password
        self.encoding = encoding
        self.content = content
    }

    func write(to destination: URL) throws {
        defer { withExtendedLifetime(content) {} }
        let opened = try OpenArchive(url: archiveURL, password: password, encoding: encoding)
        defer { opened.close() }
        let tree = VirtualArchiveTree(entries: opened.entries)
        let indices = tree.extractionIndices(for: [itemPath])
        guard !indices.isEmpty else { throw ArchiveError.ioError("Элемент архива больше не существует") }

        let fm = FileManager.default
        let slot = fm.temporaryDirectory.appendingPathComponent("Arkvello-Promise-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: slot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: slot) }
        try opened.extract(indices: indices, to: slot, stripPrefix: stripPrefix, fullPaths: true,
                           overwrite: .overwriteAll, password: password)
        let extracted = slot.appendingPathComponent(itemName)
        guard fm.fileExists(atPath: extracted.path) else {
            throw ArchiveError.ioError("Не удалось найти извлечённый файл")
        }
        // Never remove Finder's existing destination before successful extraction.
        try StagedReplacement.publish(at: destination) { staged in
            try fm.moveItem(at: extracted, to: staged)
        }
    }
}
