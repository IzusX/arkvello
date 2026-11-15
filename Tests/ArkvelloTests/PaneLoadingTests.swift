import ArchiveCore
import Foundation
import Testing
@testable import Arkvello

/// Simulates uninterruptible I/O. Tests choose the finish order explicitly.
private final class ControlledLoader: PaneContentLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var started: Set<String> = []
    private var released: Set<String> = []
    let blocked: String
    let failure: ArchiveError?

    init(blocked: String, failure: ArchiveError? = nil) {
        self.blocked = blocked
        self.failure = failure
    }

    func didStart(_ name: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return started.contains(name)
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        released.insert(blocked)
        condition.broadcast()
    }

    func load(_ request: PaneLoadRequest, cancellation: CancellationFlag) throws -> PaneLoadResult {
        let name: String
        switch request.location {
        case .diskFolder(let url): name = url.lastPathComponent
        case .archive(_, let layers, _): name = layers.last!.displayName
        }
        condition.lock()
        started.insert(name)
        while name == blocked && !released.contains(name) { condition.wait() }
        condition.unlock()
        if name == blocked, let failure { throw failure }
        return PaneLoadResult(items: [.disk(DiskEntryInfo(url: URL(fileURLWithPath: "/\(name)/\(name).txt"),
            name: "\(name).txt", relativeDisplayPath: nil, isDirectory: false, isSymlink: false,
            isArchiveContainer: false, size: 1, modifiedDate: nil, posixAttributes: "-rw-r--r--"))])
    }
}

@Suite("Asynchronous pane navigation") @MainActor
struct PaneLoadingTests {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now > deadline { throw ArchiveError.internalError("Test worker timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func drain(_ pane: PaneViewModel) async {
        // Nested extraction and password handling can schedule a subsequent load.
        for _ in 0..<4 { await pane.loadingTask?.value }
    }

    @Test("A slow old folder cannot replace a newer folder or its selection")
    func staleSuccess() async throws {
        let loader = ControlledLoader(blocked: "A")
        defer { loader.release() }
        let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/A"), loader: loader)
        let oldTask = pane.loadingTask
        try await waitFor { loader.didStart("A") }
        #expect(pane.isLoading)
        pane.navigate(to: .diskFolder(URL(fileURLWithPath: "/B")))
        await pane.loadingTask?.value
        #expect(!pane.isLoading)
        #expect(pane.rows.map(\.name) == ["..", "B.txt"])
        pane.selectedIDs = ["disk:/B/B.txt"]
        loader.release()
        await oldTask?.value
        #expect(pane.rows.map(\.name) == ["..", "B.txt"])
        #expect(pane.selectedIDs == ["disk:/B/B.txt"])
    }

    @Test("Late errors and password failures cannot affect a different tab")
    func staleFailure() async throws {
        for failure in [ArchiveError.ioError("late"), .passwordRequired] {
            let loader = ControlledLoader(blocked: "A", failure: failure)
            defer { loader.release() }
            let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/A"), loader: loader)
            let oldTask = pane.loadingTask
            var passwordRequests = 0
            pane.onRequestPassword = { _, _, _ in passwordRequests += 1 }
            try await waitFor { loader.didStart("A") }
            pane.openNewTab(at: .diskFolder(URL(fileURLWithPath: "/B")))
            await pane.loadingTask?.value
            loader.release()
            await oldTask?.value
            #expect(pane.errorBanner == nil)
            #expect(passwordRequests == 0)
            #expect(pane.rows.last?.name == "B.txt")
        }
    }

    @Test("Cancellation remains effective even when the underlying I/O ignores it")
    func cancellation() async throws {
        let loader = ControlledLoader(blocked: "A")
        defer { loader.release() }
        let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/A"), loader: loader)
        let task = pane.loadingTask
        try await waitFor { loader.didStart("A") }
        pane.cancelLoading()
        #expect(!pane.isLoading)
        loader.release()
        await task?.value
        #expect(pane.rows.allSatisfy { $0.isParentRow })
        #expect(pane.errorBanner == "Загрузка отменена")
    }

    @Test("A password reply from an abandoned archive cannot navigate back")
    func stalePasswordReply() async throws {
        let loader = ControlledLoader(blocked: "protected.7z", failure: .passwordRequired)
        let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/B"), loader: loader)
        await drain(pane)
        var reply: ((String?) -> Void)?
        var dismissed = false
        pane.onRequestPassword = { _, _, completion in reply = completion }
        pane.onCancelPasswordRequest = { _ in dismissed = true }
        pane.openArchiveFile(URL(fileURLWithPath: "/protected.7z"))
        loader.release()
        await drain(pane)
        #expect(reply != nil)
        pane.navigate(to: .diskFolder(URL(fileURLWithPath: "/C")))
        reply?(nil)
        await drain(pane)
        #expect(dismissed)
        #expect(pane.location == .diskFolder(URL(fileURLWithPath: "/C")))
        #expect(pane.rows.last?.name == "C.txt")
    }

    @Test("Real folders load off-main with hidden files, errors and highlighting")
    func diskIntegration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("visible.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let pane = PaneViewModel(side: .left, initialFolder: root)
        await drain(pane)
        #expect(pane.rows.map(\.name) == ["..", "visible.txt"])
        pane.showHiddenFiles = true
        await drain(pane)
        #expect(pane.rows.contains { $0.name == ".hidden" })
        pane.reloadCurrentLocation(highlightItemNamed: "visible.txt")
        await drain(pane)
        #expect(pane.selectedActionableRows.map(\.name) == ["visible.txt"])
        pane.navigate(to: .diskFolder(root.appendingPathComponent("missing")))
        await drain(pane)
        #expect(pane.errorBanner != nil)
        #expect(pane.rows.allSatisfy { $0.isParentRow })
    }

    @Test("Opening cancellation reaches the native engine and tree indexing")
    func nativeCancellation() throws {
        #expect(throws: ArchiveError.cancelled) {
            _ = try OpenArchive(url: URL(fileURLWithPath: "/cancel-before-open.zip"), progress: { _ in false })
        }
        #expect(throws: CancellationError.self) {
            _ = try VirtualArchiveTree(entries: [], checkCancellation: { throw CancellationError() })
        }
    }

    @Test("Failed nested extraction releases its temporary workspace")
    func failedNestedCleanup() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let text = root.appendingPathComponent("inner.zip")
        try Data("fixture".utf8).write(to: text)
        let outer = root.appendingPathComponent("encrypted.zip")
        try SevenZipEngine.createOrUpdateArchive(at: outer, inputPaths: [text.path], password: "test-only")
        let opened = try OpenArchive(url: outer)
        let content = PaneArchiveContent(archive: opened, tree: VirtualArchiveTree(entries: opened.entries))
        let entry = try #require(opened.entries.first { !$0.isDirectory })
        var workspace: PaneTemporaryDirectory? = PaneTemporaryDirectory()
        let path = try #require(workspace).url
        do {
            _ = try PaneContentLoader.extractNested(entry: entry, content: content, workspace: try #require(workspace),
                                                   password: nil, cancellation: CancellationFlag())
            Issue.record("Encrypted entry should require a password")
        } catch let error as ArchiveError {
            #expect(error == .passwordRequired || error == .wrongPassword)
        }
        workspace = nil
        try await waitFor { !fm.fileExists(atPath: path.path) }
        let pane = PaneViewModel(side: .left, initialFolder: root)
        await drain(pane)
        pane.openArchiveFile(outer)
        await drain(pane)
        pane.onRequestPassword = { _, _, completion in completion(nil) }
        let node = try #require(pane.archiveTree?.node(at: "inner.zip"))
        pane.filterText = "inner" // Simulate activation from a filtered listing.
        await drain(pane)
        pane.filterText = "" // Activation resets the filter before extraction.
        pane.enterNestedArchive(node: node)
        await drain(pane)
        #expect(pane.location.activeArchiveLayer?.archiveFileURL == outer)
        #expect(pane.rows.contains { $0.name == "inner.zip" })
    }

    @Test("Nested archives retain files through history and clean them after the last tab closes")
    func nestedIntegration() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let text = root.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: text)
        let inner = root.appendingPathComponent("inner.zip")
        try SevenZipEngine.createOrUpdateArchive(at: inner, inputPaths: [text.path])
        let outer = root.appendingPathComponent("outer.zip")
        try SevenZipEngine.createOrUpdateArchive(at: outer, inputPaths: [inner.path])
        let pane = PaneViewModel(side: .left, initialFolder: root)
        await drain(pane)
        pane.openNewTab()
        pane.openArchiveFile(outer)
        await drain(pane)
        let node = try #require(pane.archiveTree?.node(at: "inner.zip"))
        pane.enterNestedArchive(node: node)
        await drain(pane)
        let extracted = try #require(pane.location.activeArchiveLayer?.archiveFileURL)
        #expect(extracted != outer)
        #expect(pane.rows.contains { $0.name == "hello.txt" })
        pane.goUp()
        await drain(pane)
        #expect(fm.fileExists(atPath: extracted.path))
        pane.goBack()
        await drain(pane)
        #expect(pane.rows.contains { $0.name == "hello.txt" })
        #expect(pane.closeTab())
        await drain(pane)
        try await waitFor { !fm.fileExists(atPath: extracted.path) }
    }
}
