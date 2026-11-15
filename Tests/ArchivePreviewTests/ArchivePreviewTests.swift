import ArchiveCore
import Foundation
import Testing
@testable import ArchivePreview

@Suite("Quick Look metadata renderer")
struct ArchivePreviewTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Arkvello-Preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @Test("Archive names are escaped and only metadata is rendered")
    func escapedListing() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("<script>&'\".txt")
        try "payload must never appear".write(to: source, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("<archive>.7z")
        try SevenZipEngine.createOrUpdateArchive(at: archive, inputPaths: [source.path], options: CompressionOptions(level: 1))
        let html = String(decoding: ArchiveListing.html(for: archive), as: UTF8.self)
        #expect(html.contains("&lt;script&gt;&amp;&#39;&quot;.txt"))
        #expect(html.contains("&lt;archive&gt;.7z"))
        #expect(!html.contains("payload must never appear"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.utf8.count < ArchiveListing.maxHTMLBytes)
    }

    @Test("Encrypted headers produce a notice without password access")
    func encryptedHeaders() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("private-name.txt")
        try Data("private payload".utf8).write(to: source)
        let archive = root.appendingPathComponent("encrypted.7z")
        try SevenZipEngine.createOrUpdateArchive(at: archive, inputPaths: [source.path],
            options: CompressionOptions(level: 1, encryptHeaders: true), password: "preview-test")
        let html = String(decoding: ArchiveListing.html(for: archive), as: UTF8.self)
        #expect(html.contains("file names are encrypted"))
        #expect(!html.contains("private-name.txt"))
    }

    @Test("Missing and damaged archives produce readable notices")
    func damagedArchive() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = String(decoding: ArchiveListing.html(for: root.appendingPathComponent("missing.7z")), as: UTF8.self)
        #expect(missing.contains("cannot be read"))
        let damaged = root.appendingPathComponent("damaged.7z")
        try Data("not an archive".utf8).write(to: damaged)
        #expect(String(decoding: ArchiveListing.html(for: damaged), as: UTF8.self).contains("cannot be listed"))
    }

    @Test("Large archives are rejected before native metadata loading")
    func sizeBound() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sparse = root.appendingPathComponent("large.7z")
        #expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(ArchiveListing.maxArchiveBytes + 1))
        try handle.close()
        #expect(String(decoding: ArchiveListing.html(for: sparse), as: UTF8.self).contains("512 MiB"))
    }
}
