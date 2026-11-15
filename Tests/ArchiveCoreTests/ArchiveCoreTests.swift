import ArchiveCore
import Darwin
import Foundation
import Testing
import zlib

@Suite("ArchiveCore & libsevenzip Integration Tests")
struct ArchiveCoreTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let resolved = realpath(dir.path, nil) else { throw ArchiveError.ioError("Unable to resolve fixture path") }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Synthesizes a minimal standard PKZIP archive (Store, flags = 0 without UTF-8 bit) containing a raw single-byte filename.
    private func makeLegacyRawZip(rawFileName: [UInt8], payload: [UInt8]) -> Data {
        var out = Data()
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }

        let crc: UInt32 = payload.withUnsafeBufferPointer { buf in
            UInt32(crc32(0, buf.baseAddress, uInt(buf.count)))
        }
        let size32 = UInt32(payload.count)
        let nameLen = UInt16(rawFileName.count)

        // Local file header
        appendU32(0x04034b50)
        appendU16(20)      // version needed
        appendU16(0)       // flags: NO UTF-8 bit (bit 11 = 0)
        appendU16(0)       // method: Store
        appendU16(0)       // mod time
        appendU16(0x5421)  // mod date
        appendU32(crc)
        appendU32(size32)
        appendU32(size32)
        appendU16(nameLen)
        appendU16(0)       // extra len
        out.append(contentsOf: rawFileName)
        out.append(contentsOf: payload)

        let cdOffset = UInt32(out.count)

        // Central directory header
        appendU32(0x02014b50)
        appendU16(20)      // version made by: FAT/DOS (hostOS = 0)
        appendU16(20)      // version needed
        appendU16(0)       // flags: NO UTF-8 bit
        appendU16(0)       // method: Store
        appendU16(0)
        appendU16(0x5421)
        appendU32(crc)
        appendU32(size32)
        appendU32(size32)
        appendU16(nameLen)
        appendU16(0)       // extra
        appendU16(0)       // comment
        appendU16(0)       // disk
        appendU16(0)       // internal attr
        appendU32(0)       // external attr
        appendU32(0)       // local header offset
        out.append(contentsOf: rawFileName)

        let cdSize = UInt32(out.count) - cdOffset

        // End of central directory
        appendU32(0x06054b50)
        appendU16(0)
        appendU16(0)
        appendU16(1)
        appendU16(1)
        appendU32(cdSize)
        appendU32(cdOffset)
        appendU16(0)

        return out
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

    @Test("7z creation, UTF-8 + symlink preservation, VirtualArchiveTree, Flat View, and Deep Search")
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

        // Flat View across nested folders
        let flatFiles = tree.flatNodes(under: "", includeDirectories: false)
        #expect(flatFiles.map(\.name).contains("Отчёт_2026.txt"))
        #expect(flatFiles.map(\.name).contains("README.md"))

        // Deep search finds deeply nested item from root
        let deepHits = tree.search(query: "отчёт", under: "", includeDirectories: false)
        #expect(deepHits.count == 1)
        #expect(deepHits.first?.path == "Project/docs/спецификация/Отчёт_2026.txt")

        // Selective extraction stripping subfolder prefix
        let outDir = work.appendingPathComponent("ExtractedSubfolder", isDirectory: true)
        let indices = tree.extractionIndices(for: ["Project/docs/спецификация"])
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

    @Test("Legacy Windows CP866 and Windows-1251 Cyrillic ZIP auto-detection, manual override, and APFS extraction")
    func legacyCyrillicZipCodePages() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        // "Привет_мир.txt" in CP866: 8F E0 A8 A2 A5 E2 5F AC A8 E0 2E 74 78 74
        let cp866Bytes: [UInt8] = [0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2, 0x5F, 0xAC, 0xA8, 0xE0, 0x2E, 0x74, 0x78, 0x74]
        let cp866ZipURL = work.appendingPathComponent("dos_ru.zip")
        try makeLegacyRawZip(rawFileName: cp866Bytes, payload: Array("CP866-OK".utf8)).write(to: cp866ZipURL)

        let auto866 = try OpenArchive(url: cp866ZipURL, encoding: .auto)
        #expect(auto866.entries.first?.name == "Привет_мир.txt")

        let out866 = work.appendingPathComponent("out866", isDirectory: true)
        try auto866.extract(to: out866)
        #expect(FileManager.default.fileExists(atPath: out866.appendingPathComponent("Привет_мир.txt").path))

        // "Документ_отчёт.txt" in Windows-1251:
        // Д(C4) о(EE) к(EA) у(F3) м(EC) е(E5) н(ED) т(F2) _(5F) о(EE) т(F2) ч(F7) ё(B8) т(F2) .txt
        let cp1251Bytes: [UInt8] = [
            0xC4, 0xEE, 0xEA, 0xF3, 0xEC, 0xE5, 0xED, 0xF2, 0x5F,
            0xEE, 0xF2, 0xF7, 0xB8, 0xF2, 0x2E, 0x74, 0x78, 0x74
        ]
        let cp1251ZipURL = work.appendingPathComponent("win1251_ru.zip")
        try makeLegacyRawZip(rawFileName: cp1251Bytes, payload: Array("1251-OK".utf8)).write(to: cp1251ZipURL)

        let auto1251 = try OpenArchive(url: cp1251ZipURL, encoding: .auto)
        #expect(auto1251.entries.first?.name == "Документ_отчёт.txt")

        let explicit1251 = try OpenArchive(url: cp1251ZipURL, encoding: .windows1251)
        #expect(explicit1251.entries.first?.name == "Документ_отчёт.txt")
    }

    @Test("Clean archive filter excludes .DS_Store / ._* and MacMetadataPreserver roundtrips custom xattrs")
    func macMetadataFilterAndXattrPreservation() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let folder = work.appendingPathComponent("BundleSrc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let appFile = folder.appendingPathComponent("launcher.sh")
        let dsStore = folder.appendingPathComponent(".DS_Store")
        try "#!/bin/sh\necho hi\n".write(to: appFile, atomically: true, encoding: .utf8)
        try "junk".write(to: dsStore, atomically: true, encoding: .utf8)

        // Attach custom macOS extended attribute to `launcher.sh`
        let attrName = "io.sevenzipmac.customtag"
        let attrVal = Array("TaggedForMac-42".utf8)
        let setRc = appFile.path.withCString { pathC in
            setxattr(pathC, attrName, attrVal, attrVal.count, 0, 0)
        }
        #expect(setRc == 0)

        // 1. Clean Windows/Linux mode: excludes `.DS_Store`
        let cleanZipURL = work.appendingPathComponent("clean_for_win.zip")
        try SevenZipEngine.createOrUpdateArchive(
            at: cleanZipURL,
            inputPaths: [folder.path],
            options: CompressionOptions(format: "zip", excludeMacOSMetadata: true, preserveMacExtendedAttributes: false)
        )
        let cleanOpened = try OpenArchive(url: cleanZipURL)
        #expect(!cleanOpened.entries.map(\.name).contains(".DS_Store"))

        // 2. macOS xattr preservation mode: packs AppleDouble and restores xattr cleanly on extract
        let mac7zURL = work.appendingPathComponent("mac_xattr.7z")
        try SevenZipEngine.createOrUpdateArchive(
            at: mac7zURL,
            inputPaths: [folder.path],
            options: CompressionOptions(format: "7z", excludeMacOSMetadata: false, preserveMacExtendedAttributes: true)
        )

        let extractedDir = work.appendingPathComponent("ExtractedMac", isDirectory: true)
        let macOpened = try OpenArchive(url: mac7zURL)
        try macOpened.extract(to: extractedDir, restoreMacMetadata: true)

        let restoredFile = extractedDir.appendingPathComponent("BundleSrc/launcher.sh")
        let leftoverSidecar = extractedDir.appendingPathComponent("BundleSrc/._launcher.sh")
        #expect(FileManager.default.fileExists(atPath: restoredFile.path))
        #expect(!FileManager.default.fileExists(atPath: leftoverSidecar.path))

        var readBuf = [UInt8](repeating: 0, count: 64)
        let readLen = restoredFile.path.withCString { pathC in
            getxattr(pathC, attrName, &readBuf, readBuf.count, 0, 0)
        }
        #expect(readLen == attrVal.count)
        #expect(Array(readBuf.prefix(max(0, readLen))) == attrVal)
    }

    @Test("Interactive overwrite callback reports existing vs new metadata and honors skip/replace decisions")
    func interactiveOverwriteCallback() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let srcFile = work.appendingPathComponent("config.ini")
        try "NEW_VERSION=2".write(to: srcFile, atomically: true, encoding: .utf8)

        let arcURL = work.appendingPathComponent("cfg.7z")
        try SevenZipEngine.createOrUpdateArchive(at: arcURL, inputPaths: [srcFile.path])

        let destDir = work.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let existingTarget = destDir.appendingPathComponent("config.ini")
        try "OLD_VERSION=1".write(to: existingTarget, atomically: true, encoding: .utf8)

        let arc = try OpenArchive(url: arcURL)

        // First pass: choose `.skip` in interactive callback -> old file must remain untouched
        var recordedConflict: OverwriteConflict?
        try arc.extract(
            to: destDir,
            overwrite: .askInteractive,
            overwriteHandler: { conflict in
                recordedConflict = conflict
                return .skip
            }
        )
        #expect(recordedConflict != nil)
        #expect(try String(contentsOf: existingTarget, encoding: .utf8) == "OLD_VERSION=1")

        // Second pass: choose `.replace` -> file must update to NEW_VERSION=2
        try arc.extract(
            to: destDir,
            overwrite: .askInteractive,
            overwriteHandler: { _ in .replace }
        )
        #expect(try String(contentsOf: existingTarget, encoding: .utf8) == "NEW_VERSION=2")
    }

    @Test("SmartExtractionPlanner eliminates duplicate root folder (Project/Project) and protects Extract Here")
    func smartExtractionElimDup() {
        let singleRootEntries = [
            ArchiveEntry(
                index: 0, path: "MyProject/README.md", name: "README.md",
                size: 10, packedSize: 8, modifiedDate: nil, posixMode: 0,
                attributes: "", crc32: nil, method: nil, symlinkTarget: nil,
                isDirectory: false, isEncrypted: false, isSymlink: false
            )
        ]
        let singleTree = VirtualArchiveTree(entries: singleRootEntries)
        let arcURL = URL(fileURLWithPath: "/Users/izus/Downloads/MyProject.7z")
        let baseDest = URL(fileURLWithPath: "/Users/izus/Downloads")

        // Creating subfolder `MyProject` when archive already has sole root `MyProject/` strips `MyProject`
        let plan = SmartExtractionPlanner.planDialogExtraction(
            archiveURL: arcURL,
            tree: singleTree,
            selectedPaths: [],
            currentStripPrefix: "",
            baseDestination: baseDest,
            createArchiveSubfolder: true,
            eliminateRootDuplication: true
        )
        #expect(plan.finalDestinationDirectory.path == "/Users/izus/Downloads/MyProject")
        #expect(plan.effectiveStripPrefix == "MyProject")

        // Loose multi-file archive on "Extract Here" creates protective folder `LooseFiles/`
        let looseEntries = [
            ArchiveEntry(
                index: 0, path: "a.txt", name: "a.txt", size: 1, packedSize: 1,
                modifiedDate: nil, posixMode: 0, attributes: "", crc32: nil,
                method: nil, symlinkTarget: nil, isDirectory: false, isEncrypted: false, isSymlink: false
            ),
            ArchiveEntry(
                index: 1, path: "b.txt", name: "b.txt", size: 1, packedSize: 1,
                modifiedDate: nil, posixMode: 0, attributes: "", crc32: nil,
                method: nil, symlinkTarget: nil, isDirectory: false, isEncrypted: false, isSymlink: false
            )
        ]
        let looseTree = VirtualArchiveTree(entries: looseEntries)
        let loosePlan = SmartExtractionPlanner.planSmartExtractHere(
            archiveURL: URL(fileURLWithPath: "/Users/izus/Desktop/LooseFiles.zip"),
            tree: looseTree
        )
        #expect(loosePlan.finalDestinationDirectory.path == "/Users/izus/Desktop/LooseFiles")
    }

    @Test("Built-in 7-Zip hashers compute matching CRC32, SHA-256, and XXH64 on disk and inside archives")
    func checksumDigestsOnDiskAndInArchive() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let sample = work.appendingPathComponent("hello.txt")
        try Data("abc".utf8).write(to: sample)

        let diskHashes = try SevenZipEngine.computeFileHashes(at: sample)
        let mapDisk = Dictionary(uniqueKeysWithValues: diskHashes.map { ($0.algorithm.uppercased(), $0.hex.lowercased()) })

        // Standard NIST SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        // Standard CRC32("abc") = 352441c2
        #expect(mapDisk["SHA256"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(mapDisk["CRC32"] == "352441c2")
        #expect(mapDisk["XXH64"] != nil)

        let arcURL = work.appendingPathComponent("hash.7z")
        try SevenZipEngine.createOrUpdateArchive(at: arcURL, inputPaths: [sample.path])
        let arc = try OpenArchive(url: arcURL)
        let entryHashes = try arc.computeEntryHashes(for: 0)
        let mapArc = Dictionary(uniqueKeysWithValues: entryHashes.map { ($0.algorithm.uppercased(), $0.hex.lowercased()) })
        #expect(mapArc["SHA256"] == mapDisk["SHA256"])
        #expect(mapArc["CRC32"] == mapDisk["CRC32"])
    }

    @Test("KeychainPasswordStore saves, retrieves, updates, and deletes archive passwords")
    func keychainStoreRoundtrip() {
        let testService = "io.github.izusx.sevenzipmac.tests.\(UUID().uuidString)"
        let fakeArc = URL(fileURLWithPath: "/tmp/vault-\(UUID().uuidString).7z")
        defer { KeychainPasswordStore.removePassword(for: fakeArc, service: testService) }

        #expect(KeychainPasswordStore.password(for: fakeArc, service: testService) == nil)
        #expect(KeychainPasswordStore.savePassword("Secret#1", for: fakeArc, service: testService) == true)
        #expect(KeychainPasswordStore.password(for: fakeArc, service: testService) == "Secret#1")
        #expect(KeychainPasswordStore.savePassword("Secret#2", for: fakeArc, service: testService) == true)
        #expect(KeychainPasswordStore.password(for: fakeArc, service: testService) == "Secret#2")
        #expect(KeychainPasswordStore.removePassword(for: fakeArc, service: testService) == true)
        #expect(KeychainPasswordStore.password(for: fakeArc, service: testService) == nil)
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

        #expect(throws: ArchiveError.passwordRequired) {
            _ = try OpenArchive(url: encArcURL)
        }
        #expect(throws: ArchiveError.wrongPassword) {
            _ = try OpenArchive(url: encArcURL, password: "WrongPassword123")
        }

        let opened = try OpenArchive(
            url: encArcURL,
            passwordProvider: { "CorrectHorseBatteryStaple!" }
        )
        #expect(opened.summary.headersEncrypted == true)
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
        #expect(reopened.entries.map(\.path) == ["alpha_renamed.txt"])
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

        try #"{"port":9090,"updated":true}"#.write(
            to: session.extractedFileURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(session.hasUncommittedChanges() == true)
        try session.commitChanges()
        #expect(session.hasUncommittedChanges() == false)
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

        #expect(loc3.goingUp()?.destination == loc2)
        #expect(loc1.goingUp()?.destination == loc0)
    }
}
