import AppKit
import ArchiveCore
import Foundation

// Operation admission, progress, cancellation and overwrite replies.
extension AppViewModel {
    func makeInteractiveOverwriteBridge() -> @Sendable (CancellationFlag, OverwriteConflict) -> OverwriteDecision {
        { [weak self] flag, conflict in
            let reply = OperationReply<OverwriteDecision>()
            Task { @MainActor [weak self] in
                guard let self, self.currentCancellation === flag, !flag.isCancelled else {
                    reply.resolve(.cancel)
                    return
                }
                self.overwriteConflictSheet = OverwriteConflictSheetRequest(conflict: conflict) { [weak self] decision in
                    guard let self, self.currentCancellation === flag, !flag.isCancelled else {
                        reply.resolve(.cancel)
                        return
                    }
                    self.pendingOverwriteResolution = { reply.resolve(decision) }
                    self.overwriteConflictSheet = nil
                }
            }
            return reply.wait(cancellation: flag, cancelledValue: .cancel)
        }
    }

    func finishOverwritePrompt() {
        let resolution = pendingOverwriteResolution
        pendingOverwriteResolution = nil
        resolution?()
    }

    func runBackgroundOperation(
        title: String,
        initialDetail: String,
        work: @escaping @Sendable (CancellationFlag, @escaping @Sendable (ArchiveProgress) -> Void) throws -> Void,
        onSuccess: @escaping @MainActor () -> Void,
        onPasswordNeeded: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !operations.isRunning, !passwordPrompts.hasRequests || passwordPrompts.isDeliveringReply || passwordPrompts.isSuspended else { NSSound.beep(); return }
        passwordPrompts.isSuspended = true
        operationBanner = OperationBannerState(title: title, detail: initialDetail, fraction: nil, isRunning: true, isError: false)
        let retainedContent = [leftPane.retainedArchiveContent, rightPane.retainedArchiveContent]
        operations.start(work: { flag, report in
            defer { withExtendedLifetime(retainedContent) {} }
            try work(flag, report)
        }) { [weak self] progress in
            self?.operationBanner = OperationBannerState(title: title, detail: progress.currentItem ?? initialDetail,
                fraction: progress.fraction, isRunning: true, isError: false)
        } completion: { [weak self] result in
            guard let self else { return }
            self.pendingOverwriteResolution = nil
            self.overwriteConflictSheet = nil
            self.operationBanner = nil
            defer { self.passwordPrompts.isSuspended = self.operations.isRunning }
            switch result {
            case .success:
                onSuccess()
                self.finishFinderServiceIfIdle()
            case .failure(let error):
                // Cancellation can leave completed outputs; refresh their metadata too.
                if (error as? ArchiveError) != .passwordRequired && (error as? ArchiveError) != .wrongPassword {
                    self.leftPane.reloadCurrentLocation(forceReopenArchive: true)
                    if self.isDualPane { self.rightPane.reloadCurrentLocation(forceReopenArchive: true) }
                }
                if error is CancellationError || (error as? ArchiveError) == .cancelled {
                    self.finishFinderServiceIfIdle()
                } else if let error = error as? ArchiveError,
                          error == .passwordRequired || error == .wrongPassword,
                          let onPasswordNeeded {
                    onPasswordNeeded(error == .wrongPassword)
                } else {
                    self.showStatusBanner(title: "Ошибка: \(title)", detail: error.localizedDescription, isError: true)
                }
            }
        }
    }

    func showStatusBanner(title: String, detail: String, isError: Bool) {
        guard !operations.isRunning else { return }
        operationBanner = OperationBannerState(
            title: title,
            detail: detail,
            fraction: nil,
            isRunning: false,
            isError: isError
        )
    }

    func showTransientSuccess(_ message: String) {
        guard !operations.isRunning else { return }
        operationBanner = OperationBannerState(
            title: "Готово",
            detail: message,
            fraction: 1.0,
            isRunning: false,
            isError: false
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.operationBanner?.detail == message {
                self?.operationBanner = nil
            }
        }
    }
}

/// Written by one admitted worker; read only after its completion on the main actor.
final class OperationResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
