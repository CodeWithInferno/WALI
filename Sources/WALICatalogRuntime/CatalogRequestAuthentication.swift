import Foundation
import Supabase

/// A gateway operation retains its initial subject across every SDK request and retry. It is
/// transient task state, not another session owner, credential cache, or persistence format.
enum CatalogRequestAuthentication {
    struct Snapshot: Sendable {
        let ownerID: ObjectIdentifier
        let session: Session?

        var validAccessToken: String? {
            guard let session, session.expiresAt > Date.now.timeIntervalSince1970 else { return nil }
            return session.accessToken
        }
    }

    @TaskLocal static var snapshot: Snapshot?

    static func withSnapshot<Value: Sendable>(
        for owner: AuthSessionStore,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        let ownerID = ObjectIdentifier(owner)
        if snapshot?.ownerID == ownerID {
            try Task.checkCancellation()
            return try await operation()
        }
        let session = try? await owner.validatedSession()
        try Task.checkCancellation()
        let captured = Snapshot(ownerID: ownerID, session: session)
        return try await $snapshot.withValue(captured, operation: operation)
    }
}
