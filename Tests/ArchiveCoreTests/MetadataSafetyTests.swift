@testable import ArchiveCore
import Darwin
import Foundation
import Testing

@Suite("Metadata safety (temporary fixtures only)")
struct MetadataSafetyTests {
    private let attribute = "io.sevenzipmac.safety"

    private func temporaryDirectory() throws -> URL {
        guard let tempPath = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(tempPath) }
        let root = URL(fileURLWithPath: String(cString: tempPath), isDirectory: true)
            .appendingPathComponent("MetadataSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func tag(_ file: URL, value: String = "roundtrip") throws {
        let bytes = Array(value.utf8)
        let result = file.path.withCString { setxattr($0, attribute, bytes, bytes.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func tagValue(_ file: URL) -> String? {
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = file.path.withCString { getxattr($0, attribute, &bytes, bytes.count, 0, XATTR_NOFOLLOW) }
        return count >= 0 ? String(bytes: bytes.prefix(count), encoding: .utf8) : nil
    }

    private func stagedPair(in root: URL) throws -> (URL, URL) {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source.appendingPathComponent("file"))
        try tag(source.appendingPathComponent("file"))
        let staged = try MacMetadataPreserver.prepareStagingWithAppleDouble(inputPaths: ["file"], baseDirectory: source)
        return (staged.stagingRoot, staged.stagingRoot.appendingPathComponent("._file"))
    }

    @Test("Extraction leaves preexisting pairs, unrelated sidecars, and user __MACOSX data intact")
    func preexistingDataIsUntouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (stage, sidecar) = try stagedPair(in: root)
        defer { try? FileManager.default.removeItem(at: stage) }
        let archiveURL = root.appendingPathComponent("safe.7z")
        try SevenZipEngine.createOrUpdateArchive(at: archiveURL, inputPaths: ["file", "._file"], baseDirectory: stage,
            options: CompressionOptions(format: "7z", excludeMacOSMetadata: false))
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("__MACOSX/user"), withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination.appendingPathComponent("file"))
        try tag(destination.appendingPathComponent("file"), value: "keep")
        try FileManager.default.copyItem(at: sidecar, to: destination.appendingPathComponent("._file"))
        try FileManager.default.copyItem(at: sidecar, to: destination.appendingPathComponent("._unrelated"))
        try Data("unrelated".utf8).write(to: destination.appendingPathComponent("unrelated"))
        try Data("user data".utf8).write(to: destination.appendingPathComponent("__MACOSX/user/notes"))
        let before = try Data(contentsOf: destination.appendingPathComponent("._file"))
        let archive = try OpenArchive(url: archiveURL)
        try archive.extract(to: destination, overwrite: .skipExisting)
        #expect(try Data(contentsOf: destination.appendingPathComponent("file")) == Data("existing".utf8))
        #expect(tagValue(destination.appendingPathComponent("file")) == "keep")
        #expect(try Data(contentsOf: destination.appendingPathComponent("._file")) == before)
        #expect(try Data(contentsOf: destination.appendingPathComponent("._unrelated")) == before)
        #expect(try Data(contentsOf: destination.appendingPathComponent("unrelated")) == Data("unrelated".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("__MACOSX/user/notes")) == Data("user data".utf8))
    }

    @Test("Restoration rejects symlink companions and symlink ancestors")
    func symlinkTargetsAreUntouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (stage, packed) = try stagedPair(in: root)
        defer { try? FileManager.default.removeItem(at: stage) }
        let destination = root.appendingPathComponent("out")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: target)
        try tag(target, value: "keep")
        let plan = MacMetadataPreserver.prepareRestoration(in: destination, relativePaths: ["file", "._file"])
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("file"), withDestinationURL: target)
        try FileManager.default.copyItem(at: packed, to: destination.appendingPathComponent("._file"))
        MacMetadataPreserver.restoreAppleDoubleMetadata(in: destination, plan: plan)
        #expect(tagValue(target) == "keep")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("._file").path))

        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let ancestorPlan = MacMetadataPreserver.prepareRestoration(in: destination, relativePaths: ["nested/file", "nested/._file"])
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("nested"), withDestinationURL: other)
        try FileManager.default.copyItem(at: target, to: other.appendingPathComponent("file"))
        try FileManager.default.copyItem(at: packed, to: other.appendingPathComponent("._file"))
        MacMetadataPreserver.restoreAppleDoubleMetadata(in: destination, plan: ancestorPlan)
        #expect(tagValue(other.appendingPathComponent("file")) == "keep")
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("._file").path))
        #expect(try Data(contentsOf: target) == Data("target".utf8))
    }

    @Test("Synthesized sidecar collisions fail without modifying inputs or archive")
    func sidecarCollisionFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("file")
        let sidecar = folder.appendingPathComponent("._file")
        try Data("payload".utf8).write(to: file)
        try tag(file)
        try Data("user sidecar".utf8).write(to: sidecar)
        let archive = root.appendingPathComponent("unchanged.7z")
        try Data("existing archive sentinel".utf8).write(to: archive)
        #expect(throws: (any Error).self) {
            try SevenZipEngine.createOrUpdateArchive(at: archive, inputPaths: [folder.path],
                options: CompressionOptions(format: "7z", preserveMacExtendedAttributes: true))
        }
        #expect(try Data(contentsOf: sidecar) == Data("user sidecar".utf8))
        #expect(try Data(contentsOf: archive) == Data("existing archive sentinel".utf8))
        #expect(tagValue(file) == "roundtrip")
        // The same collision must fail for individual top-level inputs in either order.
        for paths in [["file", "._file"], ["._file", "file"]] {
            #expect(throws: (any Error).self) {
                _ = try MacMetadataPreserver.prepareStagingWithAppleDouble(inputPaths: paths, baseDirectory: folder)
            }
        }
    }

    @Test("__MACOSX restoration removes only empty metadata directories")
    func macosxSidecarPreservesUserFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (stage, packed) = try stagedPair(in: root)
        defer { try? FileManager.default.removeItem(at: stage) }
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let paths = ["file", "__MACOSX/._file"]
        let plan = MacMetadataPreserver.prepareRestoration(in: destination, relativePaths: paths)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: destination.appendingPathComponent("file"))
        try Data("keep".utf8).write(to: destination.appendingPathComponent("__MACOSX/notes"))
        try FileManager.default.copyItem(at: packed, to: destination.appendingPathComponent("__MACOSX/._file"))
        MacMetadataPreserver.restoreAppleDoubleMetadata(in: destination, plan: plan)
        #expect(tagValue(destination.appendingPathComponent("file")) == "roundtrip")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("__MACOSX/._file").path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("__MACOSX/notes")) == Data("keep".utf8))
    }

    @Test("New selected outputs restore xattrs with prefix stripping and preserve __MACOSX user data")
    func happyRoundtrip() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("file")
        try Data("payload".utf8).write(to: file)
        try tag(file)
        let archiveURL = root.appendingPathComponent("safe.7z")
        try SevenZipEngine.createOrUpdateArchive(at: archiveURL, inputPaths: [source.path],
            options: CompressionOptions(format: "7z", preserveMacExtendedAttributes: true))
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("__MACOSX/notes"))
        let archive = try OpenArchive(url: archiveURL)
        let indices = archive.entries.filter { $0.path.hasPrefix("source/") }.map(\.index)
        try archive.extract(indices: indices, to: destination, stripPrefix: "source")
        #expect(tagValue(destination.appendingPathComponent("file")) == "roundtrip")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("._file").path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("__MACOSX/notes")) == Data("keep".utf8))
    }
}
