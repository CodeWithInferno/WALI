import Foundation
import Observation
import SwiftUI
import WALICatalogRuntime

@MainActor
@Observable
public final class ModeratorAccessModel {
    public enum State: Equatable {
        case idle
        case working
        case setup(secret: String)
        case challenge
        case verified
        case failed
    }

    public private(set) var state: State = .idle
    public private(set) var errorMessage: String?
    public var onVerified: (() -> Void)?

    private let store: any AccountMFASessionProviding
    private var task: Task<Void, Never>?
    private var subjectID: String?
    private var factorID: String?
    private var enrollmentID: String?

    public init(store: any AccountMFASessionProviding) { self.store = store }

    public func begin(subjectID: String) {
        guard state != .working else { return }
        task?.cancel()
        self.subjectID = subjectID
        state = .working
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await store.mfaStatus()
                try Task.checkCancellation()
                guard self.subjectID == subjectID, status.subjectID == subjectID else { return }
                if status.isFresh() {
                    finish()
                } else if let factor = status.verifiedTOTPFactorID {
                    factorID = factor
                    state = .challenge
                } else {
                    let enrollment = try await store.beginTOTPEnrollment()
                    guard !Task.isCancelled, self.subjectID == subjectID,
                          enrollment.subjectID == subjectID
                    else {
                        try? await store.cancelTOTPEnrollment(factorID: enrollment.factorID)
                        return
                    }
                    enrollmentID = enrollment.factorID
                    factorID = enrollment.factorID
                    state = .setup(secret: enrollment.secret)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.subjectID == subjectID else { return }
                state = .failed
                errorMessage = "Two-factor authentication couldn’t be prepared. Try again."
            }
        }
    }

    public func verify(code: String) {
        guard state != .working, let factorID, let subjectID else { return }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            errorMessage = "Enter the six-digit code from your authenticator."
            return
        }
        let previousState = state
        state = .working
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await store.verifyTOTP(factorID: factorID, code: code)
                try Task.checkCancellation()
                guard self.subjectID == subjectID, status.subjectID == subjectID, status.isFresh() else { return }
                enrollmentID = nil
                finish()
            } catch is CancellationError {
                return
            } catch {
                guard self.subjectID == subjectID else { return }
                state = previousState
                errorMessage = "That code couldn’t be verified. Check the code and try again."
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        let pendingEnrollment = enrollmentID
        subjectID = nil
        factorID = nil
        enrollmentID = nil
        state = .idle
        errorMessage = nil
        if let pendingEnrollment {
            Task { try? await store.cancelTOTPEnrollment(factorID: pendingEnrollment) }
        }
    }

    private func finish() {
        factorID = nil
        state = .verified
        onVerified?()
    }
}

struct ModeratorAccessView: View {
    @Bindable var model: ModeratorAccessModel
    let subjectID: String
    let isUnlocked: Bool
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review tools require two-factor authentication.")
                .foregroundStyle(.secondary)
            if isUnlocked {
                Label("Review tools unlocked", systemImage: "checkmark.shield")
            } else {
                switch model.state {
                case .idle, .failed, .verified:
                    Button("Unlock Review Tools") { model.begin(subjectID: subjectID) }
                case .working:
                    ProgressView("Verifying identity…").controlSize(.small)
                case let .setup(secret):
                    Text("Add this setup key to your authenticator, then enter its six-digit code.")
                    Text(secret)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .privacySensitive()
                    codeEntry
                case .challenge:
                    codeEntry
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: model.state) { _, state in
            if state == .working || state == .idle { code = "" }
        }
    }

    private var codeEntry: some View {
        HStack {
            TextField("Authentication code", text: $code)
                .textContentType(.oneTimeCode)
                .frame(maxWidth: 180)
                .onSubmit { model.verify(code: code) }
            Button("Verify") { model.verify(code: code) }
                .disabled(code.count != 6)
            Button("Cancel") { model.cancel() }
        }
    }
}
