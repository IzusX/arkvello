import ArchiveCore
import Foundation
import Testing

@Suite("ArchiveCore & libsevenzip Integration Tests")
struct ArchiveCoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Engine loads 7-Zip 26.06 and registers all core formats")
    func engineFormats() throws {
        #expect(SevenZipEngine.version.contains("26.06"))
        let formats = try SevenZipEngine.supportedFormats()
        #expect(formats.count >= 50)

        let byName = Dictionary(uniqueKeysWithValues: formats.map { ($0.name.lowercased(), $0) })
        #expect(byName["7z"]?.isUpdatable == true)
        #expect(byName["zip"]?.isUpdatable == true)
        #expect(byName["tar"]?.isUpdatable == true)
        #expect(byName["rar5"]?.isUpdatable == false)
        #expect(byName["dmg"]?.isUpdatable == false)
    }

    @Test("7z creation, UTF-8 + symlink preservation, VirtualArchiveTree, and stripPrefix extraction")
    func sevenZipLifecycleAndVirtualTree() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let srcRoot = work.appendingPathComponent("Project", isDirectory: true)
        let subDir = srcRoot.appendingPathComponent("docs/спецификация", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let readmeURL = srcRoot.appendingPathComponent("README.md")
        let specURL = subDir.appendingPathComponent("Отчёт_2026.txt")
        let linkURL = srcRoot.appendingPathComponent("latest-spec.txt")

        try "# Hello 7-Zip Mac\n".write(to: readmeURL, atomically: true, encoding: .utf8)
        try "Строка с кириллицей и точными данными 12345".write(to: specURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "docs/спецификация/Отчёт_2026.txt")

        let archiveURL = work.appendingPathComponent("bundle.7z")
        try SevenZipEngine.createOrUpdateArchive(
            at: archiveURL,
            inputPaths: [srcRoot.path],
            options: CompressionOptions(format: "7z", method: "LZMA2", level: 5, storeSymlinks: true)
        )

        let archive = try OpenArchive(url: archiveURL)
        #expect(archive.summary.formatName == "7z")
        #expect(archive.summary.isUpdatable == true)

        let tree = VirtualArchiveTree(entries: archive.entries)
        let rootChildren = tree.children(in: "")
        #expect(rootChildren.count == 1)
        #expect(rootChildren.first?.name == "Project")
        #expect(rootChildren.first?.isDirectory == true)

        let projectChildren = tree.children(in: "Project")
        #expect(projectChildren.map(\.name).contains("docs"))
        #expect(projectChildren.map(\.name).contains("README.md"))
        #expect(projectChildren.map(\.name).contains("latest-spec.txt"))

        let linkNode = tree.node(at: "Project/latest-spec.txt")
        #expect(linkNode?.isSymlink == true)

        // Selective extraction from inside subfolder `Project/docs` stripping that prefix
        let outDir = work.appendingPathComponent("ExtractedSubfolder", isDirectory: true)
        let indices = tree.extractionIndices(for: ["Project/docs/спецификация"])
        #expect(!indices.isEmpty)

        try archive.extract(
            indices: indices,
            to: outDir,
            stripPrefix: "Project/docs",
            fullPaths: true
        )

        let extractedSpec = outDir.appendingPathComponent("спецификация/Отчёт_2026.txt")
        let text = try String(contentsOf: extractedSpec, encoding: .utf8)
        #expect(text == "Строка с кириллицей и точными данными 12345")
    }

    @Test("Encrypted 7z with header encryption (-mhe=on), password errors, and in-memory streaming")
    func encryptedHeadersAndMemoryExtract() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let secretFile = work.appendingPathComponent("secret.txt")
        let payload = "Top-secret payload for in-memory Quick Look preview!"
        try payload.write(to: secretFile, atomically: true, encoding: .utf8)

        let encArcURL = work.appendingPathComponent("vault.7z")
        try SevenZipEngine.createOrUpdateArchive(
            at: encArcURL,
            inputPaths: [secretFile.path],
            options: CompressionOptions(format: "7z", level: 5, encryptHeaders: true),
            password: "CorrectHorseBatteryStaple!"
        )

        // 1. Opening without password must report .passwordRequired
        #expect(throws: ArchiveError.passwordRequired) {
            _ = try OpenArchive(url: encArcURL)
        }

        // 2. Opening with wrong password must report .wrongPassword
        #expect(throws: ArchiveError.wrongPassword) {
            _ = try OpenArchive(url: encArcURL, password: "WrongPassword123")
        }

        // 3. Opening via dynamic in-process passwordProvider callback must succeed
        let opened = try OpenArchive(
            url: encArcURL,
            passwordProvider: { "CorrectHorseBatteryStaple!" }
        )
        #expect(opened.summary.headersEncrypted == true)
        #expect(opened.entries.count == 1)

        try opened.test(password: "CorrectHorseBatteryStaple!")
        #expect(throws: ArchiveError.wrongPassword) {
            try opened.test(password: "BadPass")
        }

        let memData = try opened.extractData(
            for: opened.entries[0].index,
            password: "CorrectHorseBatteryStaple!"
        )
        #expect(String(data: memData, encoding: .utf8) == payload)
    }

    @Test("ZIP AES-256 creation, rename entry in-place, and delete entry in-place")
    func zipModifyRenameAndDelete() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let fileA = work.appendingPathComponent("alpha.txt")
        let fileB = work.appendingPathComponent("beta.txt")
        try "AAA".write(to: fileA, atomically: true, encoding: .utf8)
        try "BBB".write(to: fileB, atomically: true, encoding: .utf8)

        let zipURL = work.appendingPathComponent("items.zip")
        try SevenZipEngine.createOrUpdateArchive(
            at: zipURL,
            inputPaths: [fileA.path, fileB.path],
            options: CompressionOptions(format: "zip", method: "Deflate", level: 5),
            password: "ZipSecret256"
        )

        try SevenZipEngine.renameItems(
            in: zipURL,
            pairs: [(oldPath: "alpha.txt", newPath: "alpha_renamed.txt")],
            password: "ZipSecret256"
        )

        try SevenZipEngine.deleteItems(
            in: zipURL,
            archivePaths: ["beta.txt"],
            password: "ZipSecret256"
        )

        let reopened = try OpenArchive(url: zipURL, password: "ZipSecret256")
        let paths = reopened.entries.map(\.path)
        #expect(paths == ["alpha_renamed.txt"])
        try reopened.test(password: "ZipSecret256")
    }

    @Test("TempEditSession detects atomic editor save and commits update back into archive")
    func tempEditSessionRoundtrip() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let cfgDir = work.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        let cfgURL = cfgDir.appendingPathComponent("app.json")
        try #"{"port":8080}"#.write(to: cfgURL, atomically: true, encoding: .utf8)

        let arcURL = work.appendingPathComponent("service.7z")
        try SevenZipEngine.createOrUpdateArchive(
            at: arcURL,
            inputPaths: ["config/app.json"],
            baseDirectory: work,
            options: CompressionOptions(format: "7z", level: 3)
        )

        let arc = try OpenArchive(url: arcURL)
        guard let targetEntry = arc.entries.first(where: { $0.path == "config/app.json" }) else {
            Issue.record("Missing config/app.json in archive")
            return
        }

        let session = try TempEditSession(archive: arc, entry: targetEntry)
        defer { session.cleanup() }
        arc.close()

        #expect(session.hasUncommittedChanges() == false)

        // Simulate atomic save (writes to temp file and renames over target, like TextEdit / VS Code)
        try #"{"port":9090,"updated":true}"#.write(
            to: session.extractedFileURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(session.hasUncommittedChanges() == true)

        try session.commitChanges()
        #expect(session.hasUncommittedChanges() == false)

        let updatedArc = try OpenArchive(url: arcURL)
        guard let updatedEntry = updatedArc.entries.first(where: { $0.path == "config/app.json" }) else {
            Issue.record("Missing updated config/app.json")
            return
        }
        let updatedData = try updatedArc.extractData(for: updatedEntry.index)
        #expect(String(data: updatedData, encoding: .utf8) == #"{"port":9090,"updated":true}"#)
    }

    @Test("NavigationLocation transitions seamlessly across disk folders, archives, and nested archives")
    func navigationBreadcrumbsAndUp() {
        let downloads = URL(fileURLWithPath: "/Users/izus/Downloads")
        let outerArc = downloads.appendingPathComponent("release.7z")
        let nestedTemp = URL(fileURLWithPath: "/tmp/nested-inner.tar")

        let loc0 = NavigationLocation.diskFolder(downloads)
        let loc1 = loc0.enteringArchiveOnDisk(outerArc)
        let loc2 = loc1.enteringArchiveSubfolder("packages/core")
        let loc3 = loc2.enteringNestedArchive(extractedTempURL: nestedTemp, displayName: "inner.tar")
        let loc4 = loc3.enteringArchiveSubfolder("bin")

        // Up from `inner.tar/bin` -> `inner.tar` root, highlighting `bin`
        let up1 = loc4.goingUp()
        #expect(up1?.destination == loc3)
        #expect(up1?.highlightName == "bin")

        // Up from `inner.tar` root -> `release.7z/packages/core`, highlighting `inner.tar`
        let up2 = loc3.goingUp()
        #expect(up2?.destination == loc2)
        #expect(up2?.highlightName == "inner.tar")

        // Up from `release.7z/packages/core` -> `release.7z/packages`
        let up3 = loc2.goingUp()
        #expect(up3?.highlightName == "core")

        // Up from `release.7z` root -> `/Users/izus/Downloads`, highlighting `release.7z`
        let upFromRoot = loc1.goingUp()
        #expect(upFromRoot?.destination == loc0)
        #expect(upFromRoot?.highlightName == "release.7z")
    }
}
