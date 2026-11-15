import ArchiveCore
import Foundation

/// Retains the source workspace and credentials for the whole edit session,
/// independently of the currently open panes and tabs.
@MainActor
final class ExternalEditSessionStore {
    struct Lease: Sendable {
        let session: TempEditSession
        let content: PaneArchiveContent?
    }

    private var leases: [URL: Lease] = [:]
    private var passwords: [URL: String] = [:]

    var sessions: [TempEditSession] { leases.values.map(\.session) }

    func track(_ session: TempEditSession, content: PaneArchiveContent?, password: String?) {
        leases[session.extractedFileURL] = Lease(session: session, content: content)
        passwords[session.extractedFileURL] = password
    }

    func lease(for session: TempEditSession) -> Lease? { leases[session.extractedFileURL] }
    func password(for session: TempEditSession) -> String? { passwords[session.extractedFileURL] }

    func remember(_ password: String, for session: TempEditSession) {
        passwords[session.extractedFileURL] = password
    }

    func remove(_ session: TempEditSession) {
        leases[session.extractedFileURL] = nil
        passwords[session.extractedFileURL] = nil
    }
}
