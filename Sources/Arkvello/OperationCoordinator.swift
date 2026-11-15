import ArchiveCore
import Foundation

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func onCancel(_ action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if cancelled { lock.unlock(); action() }
        else { handlers[id] = action; lock.unlock() }
        return id
    }

    func removeHandler(_ id: UUID) { _ = lock.withLock { handlers.removeValue(forKey: id) } }
}

/// A synchronous native callback can wait for the UI, but cancellation or teardown
/// must always release it. Only the first reply wins, including a late UI response.
final class OperationReply<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?

    func resolve(_ value: Value) {
        condition.lock(); defer { condition.unlock() }
        guard self.value == nil else { return }
        self.value = value
        condition.broadcast()
    }

    func wait(cancellation: CancellationFlag, cancelledValue: Value) -> Value {
        let id = cancellation.onCancel { self.resolve(cancelledValue) }
        defer { cancellation.removeHandler(id) }
        condition.lock(); defer { condition.unlock() }
        while value == nil { condition.wait() }
        return value!
    }
}

/// Keeps at most one pending main-actor update regardless of native callback rate.
private final class OperationProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ArchiveProgress?
    private var scheduled = false
    let deliver: @MainActor @Sendable (ArchiveProgress) -> Void

    init(deliver: @escaping @MainActor @Sendable (ArchiveProgress) -> Void) { self.deliver = deliver }

    func report(_ progress: ArchiveProgress) {
        lock.lock()
        latest = progress
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [self] in
            let value = lock.withLock { let value = latest; latest = nil; scheduled = false; return value }
            if let value { deliver(value) }
        }
    }
}

@MainActor
final class OperationCoordinator {
    private(set) var cancellation: CancellationFlag?
    private(set) var task: Task<Void, Never>?
    private let worker = PaneLoadWorker()
    var isRunning: Bool { cancellation != nil }

    deinit { cancellation?.cancel() }

    /// Admission is exclusive, including the time spent cancelling native work.
    /// Callers keep the current banner when a second command is rejected.
    @discardableResult
    func start(work: @escaping @Sendable (CancellationFlag, @escaping @Sendable (ArchiveProgress) -> Void) throws -> Void,
               progress: @escaping @MainActor @Sendable (ArchiveProgress) -> Void,
               completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> Bool {
        guard cancellation == nil else { return false }
        let flag = CancellationFlag()
        cancellation = flag
        let relay = OperationProgressRelay { [weak self] value in
            guard self?.cancellation === flag, !flag.isCancelled else { return }
            progress(value)
        }
        let worker = worker
        task = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await worker.run {
                    try flag.check()
                    try work(flag, relay.report)
                }
                result = flag.isCancelled ? .failure(ArchiveError.cancelled) : .success(())
            } catch {
                result = flag.isCancelled ? .failure(ArchiveError.cancelled) : .failure(error)
            }
            guard let self, self.cancellation === flag else { return }
            self.cancellation = nil
            completion(result)
        }
        return true
    }

    func cancel() { cancellation?.cancel() }
}

/// Password prompts from both panes and operations are serialized. Completion
/// runs after sheet dismissal, so a retry cannot replace a sheet being dismissed.
@MainActor
final class PasswordPromptQueue {
    private(set) var current: PasswordPromptRequest?
    private var pending: [PasswordPromptRequest] = []
    private var afterDismiss: (() -> Void)?
    var onChange: ((PasswordPromptRequest?) -> Void)?
    private(set) var isDeliveringReply = false
    var isSuspended = false { didSet { if !isSuspended { presentNext() } } }
    var hasRequests: Bool { current != nil || !pending.isEmpty || afterDismiss != nil }

    func enqueue(owner: UUID? = nil, archiveURL: URL, isRetryAfterFailure: Bool, completion: @escaping (String?, Bool) -> Void) {
        pending.append(PasswordPromptRequest(owner: owner, archiveURL: archiveURL, isRetryAfterFailure: isRetryAfterFailure, completion: completion))
        presentNext()
    }

    func cancel(for url: URL, owner: UUID? = nil) {
        let removed = pending.filter { $0.archiveURL == url && $0.owner == owner }
        pending.removeAll { $0.archiveURL == url && $0.owner == owner }
        removed.forEach { $0.completion(nil, false) }
        if current?.archiveURL == url && current?.owner == owner { respond(nil, remember: false) }
    }

    func dismiss() { respond(nil, remember: false) }

    private func respond(_ password: String?, remember: Bool) {
        guard let request = current else { return }
        current = nil
        afterDismiss = { request.completion(password, remember) }
        onChange?(nil)
    }

    func didDismiss() {
        // Handles escape/swipe dismissal as well as explicit button responses.
        if current != nil { dismiss() }
        let completion = afterDismiss
        afterDismiss = nil
        isDeliveringReply = true
        completion?()
        isDeliveringReply = false
        presentNext()
    }

    private func presentNext() {
        guard !isSuspended, !isDeliveringReply, current == nil, afterDismiss == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        let id = request.id
        current = request
        onChange?(PasswordPromptRequest(archiveURL: request.archiveURL, isRetryAfterFailure: request.isRetryAfterFailure) { [weak self] password, remember in
            guard self?.current?.id == id else { return }
            self?.respond(password, remember: remember)
        })
    }
}
