import AppKit
import Foundation
import SwiftUI
import WALIUI

struct AccountView: View {
    let account: WALIAccountPresentation
    let profile: WALIAccountProfilePresentation?
    let profileState: WALIAccountPrivacyLoadState
    let exportState: WALIAccountExportPresentation
    let deletionState: WALIAccountDeletionPresentation
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onRefresh: () -> Void
    let onRequestExport: () -> Void
    let onRefreshExport: () -> Void
    let onSaveExport: () -> Void
    let onRequestDeletion: (String) -> Void
    let onRefreshDeletion: () -> Void
    let onVerifyDeletionMFA: (String) -> Void
    let onCancelDeletionMFA: () -> Void
    private let legalLinks = MarketplaceLegalLinks()
    @State private var showsDeletionConfirmation = false
    @State private var deletionConfirmation = ""
    @State private var mfaCode = ""

    var body: some View {
        Form {
                Section("Account") {
                    switch account {
                    case .signedOut:
                        LabeledContent("Status", value: "Not signed in")
                        signInButton
                    case let .signedIn(userID):
                        if let profile {
                            LabeledContent("Name", value: profile.displayName)
                            LabeledContent("Handle", value: "@\(profile.handle)")
                            LabeledContent("Status", value: profile.status.capitalized)
                        } else if profileState == .loading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading account…").foregroundStyle(.secondary)
                            }
                        } else {
                            LabeledContent("Status", value: "Signed in")
                        }
                        LabeledContent("Account ID", value: userID)
                            .textSelection(.enabled)
                        HStack {
                            Button("Refresh", action: onRefresh)
                            Button("Sign Out", action: onSignOut)
                        }
                    }
                }

                Section("Your Data") {
                    Text("Your ordinary local-library filenames, display layout, lock history, and wallpaper assignments stay on this Mac. When you explicitly submit through Creator Studio, WALI uploads that media, its original filename, and the metadata you provide for processing and moderation.")
                        .foregroundStyle(.secondary)

                    if case .signedIn = account {
                        exportStatus

                        HStack {
                            Button(exportButtonTitle, action: exportButtonAction)
                                .disabled(profile == nil || exportState == .working)
                            if exportCanRefresh {
                                Button("Refresh Status", action: onRefreshExport)
                            }
                        }
                    }
                }

                if case .signedIn = account {
                    Section("Delete Account") {
                        Text("Removes or anonymizes your marketplace account data and sign-in identity. Required security, legal, copyright, and immutable public-release records may be retained under policy. Local wallpapers remain on this Mac.")
                            .foregroundStyle(.secondary)
                        deletionStatus

                        HStack {
                            Button("Delete Account…", role: .destructive) {
                                deletionConfirmation = ""
                                showsDeletionConfirmation = true
                            }
                            .disabled(profile == nil || deletionIsBusy)
                            if deletionCanRefresh {
                                Button("Refresh Status", action: onRefreshDeletion)
                            }
                        }
                    }
                }

                Section("Legal & Support") {
                    ForEach(MarketplaceLegalLinks.Document.allCases) { document in
                        if let url = legalLinks.url(for: document) {
                            Link(destination: url) {
                                HStack {
                                    Text(document.title)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }

                    Text("Marketplace policies are versioned with the service. Security reports require a private channel, not a public issue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
        .formStyle(.grouped)
        .font(.body)
        .frame(maxWidth: 760, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("WALI.Marketplace.Account")
        .sheet(isPresented: $showsDeletionConfirmation) {
            deletionConfirmationSheet
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        if #available(macOS 26.0, *) {
            Button("Sign in with Apple", action: onSignIn)
                .buttonStyle(.glassProminent)
        } else {
            Button("Sign in with Apple", action: onSignIn)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch exportState {
        case .idle:
            Text("Download a verified JSON copy of your marketplace account data.")
                .foregroundStyle(.secondary)
        case .working:
            Label("Working…", systemImage: "clock")
        case .queued:
            Label("Export queued", systemImage: "hourglass")
        case .processing:
            Label("Preparing export", systemImage: "arrow.triangle.2.circlepath")
        case let .ready(expiresAt):
            LabeledContent("Ready until", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
        case let .saved(fileName):
            Label("Saved as \(fileName)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var exportButtonTitle: String {
        if case .ready = exportState { return "Save Export…" }
        return "Request Export"
    }

    private func exportButtonAction() {
        if case .ready = exportState {
            onSaveExport()
        } else {
            onRequestExport()
        }
    }

    private var exportCanRefresh: Bool {
        switch exportState {
        case .queued, .processing, .failed: true
        default: false
        }
    }

    @ViewBuilder
    private var deletionStatus: some View {
        switch deletionState {
        case .idle:
            EmptyView()
        case .working:
            Label("Working…", systemImage: "clock")
        case let .mfaSetup(secret, uri, errorMessage):
            Label("Set up two-factor authentication", systemImage: "lock.shield")
                .font(.headline)
            Text("Add this one-time secret to an authenticator app, then enter its six-digit code. The secret is shown only during this setup.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(secret)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .privacySensitive()
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret, forType: .string)
                }
                if let authenticatorURL = URL(string: uri) {
                    Button("Open Authenticator") {
                        NSWorkspace.shared.open(authenticatorURL)
                    }
                }
            }
            mfaControls(errorMessage: errorMessage)
        case let .mfaChallenge(errorMessage):
            Label("Confirm with two-factor authentication", systemImage: "lock.shield")
                .font(.headline)
            Text("Enter the current six-digit code from your authenticator app. WALI requires a fresh security check before deletion.")
                .foregroundStyle(.secondary)
            mfaControls(errorMessage: errorMessage)
        case let .pending(status, identityStatus, held):
            LabeledContent("Deletion", value: status)
            LabeledContent("Sign-in identity", value: identityStatus)
            if held {
                Label("Deletion is on hold for a legal or safety review.", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
        case let .completed(completedAt):
            Label(
                "Account deletion completed \(completedAt.formatted(date: .abbreviated, time: .shortened)); required retained records were anonymized or preserved under policy.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var deletionCanRefresh: Bool {
        if case .pending = deletionState { return true }
        return false
    }

    private var deletionIsBusy: Bool {
        switch deletionState {
        case .working, .mfaSetup, .mfaChallenge, .pending:
            true
        default:
            false
        }
    }

    @ViewBuilder
    private func mfaControls(errorMessage: String?) -> some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        HStack {
            SecureField("6-digit code", text: $mfaCode)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .onChange(of: mfaCode) { _, value in
                    mfaCode = String(value.filter(\.isNumber).prefix(6))
                }
                .accessibilityIdentifier("WALI.Account.MFACode")
            Button("Verify and Delete", role: .destructive) {
                let code = mfaCode
                mfaCode = ""
                onVerifyDeletionMFA(code)
            }
            .disabled(mfaCode.count != 6)
            Button("Cancel", action: onCancelDeletionMFA)
        }
    }

    private var deletionConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Delete Marketplace Account?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text("This removes or anonymizes your marketplace account and sign-in identity. Required security, legal, copyright, and immutable public-release records may remain under policy. This cannot be undone.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Enter DELETE MY WALI to confirm")
                    .font(.callout.weight(.medium))
                TextField("DELETE MY WALI", text: $deletionConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("WALI.Account.DeleteConfirmation")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showsDeletionConfirmation = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Delete Account", role: .destructive) {
                    let confirmation = deletionConfirmation
                    showsDeletionConfirmation = false
                    onRequestDeletion(confirmation)
                }
                .disabled(deletionConfirmation != "DELETE MY WALI")
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}

struct MarketplaceLegalLinks: Sendable {
    enum Document: String, CaseIterable, Identifiable, Sendable {
        case privacy = "privacy-policy.md"
        case terms = "terms-of-service.md"
        case creatorLicense = "creator-content-license.md"
        case contentGuidelines = "content-guidelines.md"
        case copyright = "copyright-policy.md"
        case accountDeletion = "account-deletion.md"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .privacy: "Privacy Policy"
            case .terms: "Terms of Service"
            case .creatorLicense: "Creator Content License"
            case .contentGuidelines: "Content Guidelines"
            case .copyright: "Copyright Policy"
            case .accountDeletion: "Account Deletion"
            }
        }
    }

    private let baseURL: URL?

    init(bundle: Bundle = .main) {
        guard
            let rawValue = bundle.object(forInfoDictionaryKey: "WALILegalBaseURL") as? String,
            let candidate = URL(string: rawValue),
            candidate.scheme == "https",
            candidate.host != nil,
            candidate.user == nil,
            candidate.query == nil,
            candidate.fragment == nil
        else {
            baseURL = nil
            return
        }
        baseURL = candidate
    }

    func url(for document: Document) -> URL? {
        baseURL?.appending(path: document.rawValue)
    }
}
