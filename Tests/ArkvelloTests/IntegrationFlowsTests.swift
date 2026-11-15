import ArchiveCore
import Foundation
import Testing
@testable import Arkvello

private func flowRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Arkvello-Flows-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func flowArchive(_ root: URL, name: String, file: String, password: String? = nil) throws -> URL {
    let source = root.appendingPathComponent("source-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(file.utf8).write(to: source.appendingPathComponent(file))
    let archive = root.appendingPathComponent("\(name).7z")
    try SevenZipEngine.createOrUpdateArchive(at: archive, inputPaths: [file], baseDirectory: source,
        options: CompressionOptions(level: 1, encryptHeaders: password != nil), password: password)
    return archive
}

@Suite("Application integration flows") @MainActor
struct IntegrationFlowsTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > end { throw ArchiveError.internalError("Flow timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Finder batch retries only the current encrypted archive after wrong password")
    func finderBatchPassword() async throws {
        let root = try flowRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try flowArchive(root, name: "first", file: "a.txt")
        let second = try flowArchive(root, name: "second", file: "b.txt", password: "flow-secret")
        let app = AppViewModel(initialFolder: root, sessionPersistenceEnabled: false)
        app.finderServiceExtract(urls: [first, second], alwaysCreateSubfolder: true)
        try await waitFor { app.passwordPrompt != nil }
        let firstOutput = root.appendingPathComponent("first/a.txt")
        #expect(try String(contentsOf: firstOutput, encoding: .utf8) == "a.txt")
        try "keep completed output".write(to: firstOutput, atomically: true, encoding: .utf8)
        #expect(app.passwordPrompt?.archiveURL == second)
        app.passwordPrompt?.completion("wrong", false)
        app.passwordPrompts.didDismiss()
        try await waitFor { app.passwordPrompt?.isRetryAfterFailure == true }
        app.passwordPrompt?.completion("flow-secret", false)
        app.passwordPrompts.didDismiss()
        try await waitFor { !app.operations.isRunning && !app.passwordPrompts.hasRequests }
        #expect(app.operationBanner?.isError == false)
        #expect(try String(contentsOf: firstOutput, encoding: .utf8) == "keep completed output")
        #expect(try String(contentsOf: root.appendingPathComponent("second/b.txt"), encoding: .utf8) == "b.txt")
    }

    @Test("Cancelling a Finder password request finishes without producing files")
    func finderCancelPassword() async throws {
        let root = try flowRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try flowArchive(root, name: "secret", file: "secret.txt", password: "flow-secret")
        let app = AppViewModel(initialFolder: root, sessionPersistenceEnabled: false)
        var finishes = 0
        app.onFinderServiceFinished = { finishes += 1 }
        app.finderServiceExtract(urls: [archive], alwaysCreateSubfolder: true)
        try await waitFor { app.passwordPrompt != nil }
        app.passwordPrompt?.completion(nil, false)
        app.passwordPrompts.didDismiss()
        app.finishFinderServiceIfIdle()
        #expect(!app.operations.isRunning)
        #expect(finishes == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret/secret.txt").path))
    }

    @Test("An edit commits with its own password after both panes navigate elsewhere")
    func editPasswordAndRetry() async throws {
        let root = try flowRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try flowArchive(root, name: "edit", file: "edit.txt", password: "edit-secret")
        let archive = try OpenArchive(url: url, password: "edit-secret")
        let entry = try #require(archive.entries.first { $0.path == "edit.txt" })
        let session = try TempEditSession(archive: archive, entry: entry, password: "edit-secret")
        let app = AppViewModel(initialFolder: root, sessionPersistenceEnabled: false)
        app.editSessions.track(session, content: nil, password: "stale-password")
        let other = root.appendingPathComponent("unrelated.7z")
        app.leftPane.storePassword("unrelated-password", for: other)
        try "updated text".write(to: session.extractedFileURL, atomically: true, encoding: .utf8)
        app.commitModifiedSession(session)
        try await waitFor { !app.operations.isRunning }
        #expect(app.operationBanner?.isError != true, "\(String(describing: app.operationBanner))")
        let prompt = try #require(app.passwordPrompt)
        #expect(prompt.archiveURL == url)
        app.passwordPrompt?.completion("edit-secret", false)
        app.passwordPrompts.didDismiss()
        try await waitFor { !app.operations.isRunning && !app.passwordPrompts.hasRequests }
        #expect(!session.hasUncommittedChanges())
        let verified = try OpenArchive(url: url, password: "edit-secret")
        defer { verified.close() }
        #expect(verified.summary.headersEncrypted)
        let target = try #require(verified.entries.first { $0.path == "edit.txt" })
        #expect(String(decoding: try verified.extractData(for: target.index, password: "edit-secret"), as: UTF8.self) == "updated text")
        app.discardModifiedSession(session)
    }

    @Test("A file promise retains a nested archive after its pane snapshot is released")
    func promiseLifetime() async throws {
        let root = try flowRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var directory: PaneTemporaryDirectory? = PaneTemporaryDirectory()
        let directoryURL = try #require(directory?.url)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let archiveURL = try flowArchive(directoryURL, name: "inner", file: "promised.txt")
        let archive = try OpenArchive(url: archiveURL)
        var content: PaneArchiveContent? = PaneArchiveContent(archive: archive, tree: VirtualArchiveTree(entries: archive.entries), temporaryDirectories: [try #require(directory)])
        weak var weakContent = content
        var promise: ArchivePromiseContext? = ArchivePromiseContext(archiveURL: archiveURL,
            itemPath: "promised.txt", itemName: "promised.txt", stripPrefix: "", password: nil,
            encoding: .auto, content: content)
        content = nil
        directory = nil
        #expect(weakContent != nil)
        let destination = root.appendingPathComponent("promised.txt")
        let worker = PaneLoadWorker()
        let retained = try #require(promise)
        try await worker.run { try retained.write(to: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "promised.txt")
        promise = nil
        // retained remains in scope here; lifetime is guaranteed through fulfillment.
    }

    @Test("A failed promise preserves Finder's existing destination")
    func promiseFailure() throws {
        let root = try flowRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try flowArchive(root, name: "promise", file: "existing.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try "original".write(to: destination, atomically: true, encoding: .utf8)
        let promise = ArchivePromiseContext(archiveURL: url, itemPath: "missing.txt", itemName: "missing.txt",
            stripPrefix: "", password: nil, encoding: .auto, content: nil)
        #expect(throws: (any Error).self) { try promise.write(to: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    }

    @Test("Nested archive writes are disabled and leave the outer archive unchanged")
    func nestedReadOnly() async throws {
        let root = try flowRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try flowArchive(root, name: "outer", file: "outer.txt")
        let inner = try flowArchive(root, name: "inner", file: "inner.txt")
        let app = AppViewModel(initialFolder: root, sessionPersistenceEnabled: false)
        let top = NavigationLocation.diskFolder(root).enteringArchiveOnDisk(outer)
        app.leftPane.navigate(to: top)
        await app.leftPane.loadingTask?.value
        #expect(app.leftPane.canModifyArchive)
        app.leftPane.navigate(to: top.enteringNestedArchive(extractedTempURL: inner, displayName: "inner.7z"))
        await app.leftPane.loadingTask?.value
        #expect(app.leftPane.isNestedArchive)
        #expect(!app.leftPane.canModifyArchive)
        let before = try Data(contentsOf: outer)
        app.presentNewFolderDialog()
        #expect(app.newFolderSheet == nil)
        #expect(app.operationBanner?.isError == true)
        let arc = try OpenArchive(url: inner)
        let entry = try #require(arc.entries.first { $0.path == "inner.txt" })
        let session = try TempEditSession(archive: arc, entry: entry, allowUpdates: app.leftPane.canModifyArchive)
        #expect(!session.isArchiveUpdatable)
        #expect(throws: (any Error).self) { try session.commitChanges() }
        #expect(try Data(contentsOf: outer) == before)
    }
}
