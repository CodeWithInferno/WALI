import Foundation
import Observation
import SwiftUI

enum EmailCodeSignInPhase: Equatable {
    case email, requesting, code, resending, verifying, completing, cancelling
}

@MainActor
@Observable
final class EmailCodeSignInModel {
    var isPresented = false
    var phase: EmailCodeSignInPhase = .email
    var email = ""
    var code = ""
    var message: String?
    var resendAvailableAt: Date?

    var canCancel: Bool { phase != .completing && phase != .cancelling }
    var isBusy: Bool { ![.email, .code].contains(phase) }

    func clear() {
        isPresented = false
        phase = .email
        email = ""
        code = ""
        message = nil
        resendAvailableAt = nil
    }
}

struct EmailCodeSignInSheet: View {
    @Bindable var model: EmailCodeSignInModel
    let onRequest: () -> Void
    let onVerify: () -> Void
    let onResend: () -> Void
    let onChangeEmail: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?

    private enum Field { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Sign in to WALI", systemImage: "envelope")
                .font(.title2.weight(.semibold))

            switch model.phase {
            case .email, .requesting:
                Text("Enter your email to receive a one-time code. If you’re new to WALI, verifying the code creates your account.")
                    .foregroundStyle(.secondary)
                TextField("Email address", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .focused($focusedField, equals: .email)
                    .disabled(model.isBusy)
                    .onSubmit { if !model.isBusy { onRequest() } }
                    .accessibilityIdentifier("WALI.EmailSignIn.Email")
            case .code, .resending, .verifying:
                Text("Enter the code sent to \(model.email).")
                    .foregroundStyle(.secondary)
                TextField("One-time code", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .code)
                    .disabled(model.isBusy)
                    .onSubmit { if !model.isBusy { onVerify() } }
                    .accessibilityIdentifier("WALI.EmailSignIn.Code")
                HStack {
                    Button("Change Email", action: onChangeEmail)
                        .disabled(model.isBusy)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil((model.resendAvailableAt ?? .distantPast).timeIntervalSince(context.date))))
                        Button(remaining > 0 ? "Resend in \(remaining)s" : "Resend Code", action: onResend)
                            .disabled(model.isBusy || remaining > 0)
                    }
                }
                .font(.callout)
            case .completing:
                Text("Completing sign-in…")
                    .font(.headline)
                    .accessibilityIdentifier("WALI.EmailSignIn.Completing")
                Text("Your code was accepted. Please wait while WALI finishes signing in.")
                    .foregroundStyle(.secondary)
            case .cancelling:
                Text("Finishing your request…")
                    .foregroundStyle(.secondary)
            }

            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("WALI.EmailSignIn.Message")
            }

            HStack {
                if model.canCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("WALI.EmailSignIn.Cancel")
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(progressLabel)
                } else {
                    Button(model.phase == .email ? "Send Code" : "Verify Code") {
                        if model.phase == .email { onRequest() } else { onVerify() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("WALI.EmailSignIn.Submit")
                }
            }
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .onAppear { focusedField = model.phase == .email ? .email : .code }
        .onChange(of: model.phase) { _, phase in
            if phase == .email { focusedField = .email }
            if phase == .code { focusedField = .code }
        }
        .accessibilityIdentifier("WALI.EmailSignIn.Sheet")
    }

    private var progressLabel: String {
        switch model.phase {
        case .requesting, .resending: "Sending code"
        case .verifying: "Verifying code"
        case .completing: "Completing sign-in"
        default: "Finishing request"
        }
    }
}
