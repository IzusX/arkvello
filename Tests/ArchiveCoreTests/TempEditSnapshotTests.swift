import ArchiveCore
import Foundation
import Testing

@Suite("External edit snapshots")
struct TempEditSnapshotTests {
    @Test("An editor save during compression remains uncommitted")
    func concurrentSave() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Arkvello-EditSnapshot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let resolved = root.resolvingSymlinksInPath()
        let source = resolved.appendingPathComponent("edit.txt")
        try "original".write(to: source, atomically: true, encoding: .utf8)
        let url = resolved.appendingPathComponent("edit.7z")
        try SevenZipEngine.createOrUpdateArchive(at: url, inputPaths: [source.path], options: CompressionOptions(level: 1))
        let archive = try OpenArchive(url: url)
        let entry = try #require(archive.entries.first { $0.path == "edit.txt" })
        let session = try TempEditSession(archive: archive, entry: entry)
        defer { session.cleanup() }
        try "first edit".write(to: session.extractedFileURL, atomically: true, encoding: .utf8)
        var savedAgain = false
        try session.commitChanges(options: CompressionOptions(level: 1)) { _ in
            if !savedAgain {
                savedAgain = true
                // The callback runs after the commit snapshot is captured.
                try? "second edit".write(to: session.extractedFileURL, atomically: true, encoding: .utf8)
            }
            return true
        }
        #expect(savedAgain)
        #expect(session.hasUncommittedChanges())
        let verified = try OpenArchive(url: url)
        let target = try #require(verified.entries.first { $0.path == "edit.txt" })
        #expect(String(decoding: try verified.extractData(for: target.index), as: UTF8.self) == "first edit")
        try session.commitChanges(options: CompressionOptions(level: 1))
        #expect(!session.hasUncommittedChanges())
    }

    @Test("Encrypted archive mutations report password and cancellation failures precisely")
    func mutationFailures() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Arkvello-Mutations-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("file.txt")
        try "original".write(to: source, atomically: true, encoding: .utf8)
        let url = root.appendingPathComponent("encrypted.7z")
        let options = CompressionOptions(level: 1, encryptHeaders: true)
        try SevenZipEngine.createOrUpdateArchive(at: url, inputPaths: [source.path], options: options, password: "secret")
        let before = try Data(contentsOf: url)
        #expect(throws: ArchiveError.passwordRequired) {
            try SevenZipEngine.createOrUpdateArchive(at: url, inputPaths: [source.path], options: options)
        }
        #expect(throws: ArchiveError.wrongPassword) {
            try SevenZipEngine.createOrUpdateArchive(at: url, inputPaths: [source.path], options: options, password: "wrong")
        }
        #expect(throws: ArchiveError.wrongPassword) {
            try SevenZipEngine.deleteItems(in: url, archivePaths: ["file.txt"], password: "wrong")
        }
        #expect(throws: ArchiveError.wrongPassword) {
            try SevenZipEngine.renameItems(in: url, pairs: [(oldPath: "file.txt", newPath: "renamed.txt")], password: "wrong")
        }
        #expect(throws: ArchiveError.cancelled) {
            try SevenZipEngine.createOrUpdateArchive(at: url, inputPaths: [source.path], options: options, password: "secret", progress: { _ in false })
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
