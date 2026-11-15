import ArchiveCore
import Foundation
import Testing

@Suite("Safe replacement")
struct StagedReplacementTests {
    @Test func failedBuildPreservesOriginal() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("archive.7z")
        try Data("original".utf8).write(to: original)
        #expect(throws: ArchiveError.cancelled) {
            try StagedReplacement.publish(at: original) { staged in
                try Data("incomplete".utf8).write(to: staged)
                throw ArchiveError.cancelled
            }
        }
        #expect(try Data(contentsOf: original) == Data("original".utf8))
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["archive.7z"])
    }

    @Test func completedBuildReplacesOriginalBundle() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: app.appendingPathComponent("payload"))
        try StagedReplacement.publish(at: app) { staged in
            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            try Data("new".utf8).write(to: staged.appendingPathComponent("payload"))
        }
        #expect(try Data(contentsOf: app.appendingPathComponent("payload")) == Data("new".utf8))
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["Demo.app"])
    }
}
