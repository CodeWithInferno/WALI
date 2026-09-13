import AppKit
import Foundation
import SwiftUI
import WALICatalogRuntime
import WALIUI

struct AccountView: View {
    let isMarketplaceAvailable: Bool
    let authenticationMethod: CatalogAuthenticationMethod
    let account: WALIAccountPresentation
    let authenticationState: WALIMarketplaceActionState
    let profile: WALIAccountProfilePresentation?
    let profileState: WALIAccountPrivacyLoadState
    let exportState: WALIAccountExportPresentation
    let deletionState: WALIAccountDeletionPresentation
    let deletionReceipts: AccountDeletionReceiptModel?
    let creatorBlocking: CreatorBlockingModel?
    let moderatorAccess: ModeratorAccessModel?
    let hasModeratorRole: Bool
    let isModerationUnlocked: Bool
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsBlockedCreators = false
    @State private var showsDeletionConfirmation = false
    @State private var deletionConfirmation = ""
    @State private var mfaCode = ""

    var body: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Account") { EmptyView() }
            accountForm
        }
        .font(.body)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("WALI.Marketplace.Account")
        .onAppear { deletionReceipts?.setVisible(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in deletionReceipts?.setVisible(phase == .active) }
        .onDisappear { deletionReceipts?.setVisible(false) }
        .sheet(isPresented: $showsBlockedCreators) {
            if let creatorBlocking { BlockedCreatorsView(model: creatorBlocking) }
        }
        .sheet(isPresented: $showsDeletionConfirmation) {
            deletionConfirmationSheet
        }
    }

    private var accountForm: some View {
        Form {
            if isMarketplaceAvailable {
                Section {
                    HStack(spacing: 16) {
                        WALIAccountAvatarView(displayName: profile?.displayName, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            switch account {
                            case .signedOut:
                                Text(authenticationMethod == .emailOTP ? "WALI Account" : "Apple Account")
                                    .font(.title2.weight(.semibold))
                                Text("Not signed in")
                                    .foregroundStyle(.secondary)
                            case .signedIn:
                                Text(profile?.displayName ?? "Signed in")
                                    .font(.title2.weight(.semibold))
                                if let handle = profile?.handle {
                                    Text("@\(handle)")
                                        .foregroundStyle(.secondary)
                                }
                                Text("Your public marketplace profile")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)

                    switch account {
                    case .signedOut:
                        signInButton
                    case let .signedIn(userID):
                        if profileState == .loading && profile == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading account…").foregroundStyle(.secondary)
                            }
                        }
                        DisclosureGroup("Account Details") {
                            LabeledContent("Account ID", value: userID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Refresh", action: onRefresh)
                            Button("Sign Out", action: onSignOut)
                        }
                        .disabled(authenticationState == .working)
                    }

                    if authenticationState == .working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(accountIsSignedIn ? "Signing out…" : "Signing in…")
                                .foregroundStyle(.secondary)
                        }
                    } else if case let .succeeded(message) = authenticationState {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("WALI.Account.AuthenticationNotice")
                    } else if case let .failed(message) = authenticationState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("WALI.Account.AuthenticationError")
                    }
                    if case let .failed(message) = profileState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                if let deletionReceipts, !deletionReceipts.receipts.isEmpty || deletionReceipts.errorMessage != nil {
                    AccountDeletionReceiptView(model: deletionReceipts)
                }

                if creatorBlocking != nil {
                    Section("Catalog Privacy") {
                        Button("Blocked Creators", systemImage: "person.crop.circle.badge.xmark") { showsBlockedCreators = true }
                        Text("Hide a creator’s catalog content without removing existing wallpapers from your Library.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if hasModeratorRole, let moderatorAccess, let profile {
                    Section("Review Access") {
                        ModeratorAccessView(
                            model: moderatorAccess,
                            subjectID: profile.userID,
                            isUnlocked: isModerationUnlocked
                        )
                    }
                }

                Section("Your Data") {
                    Text("Your ordinary local-library filenames, display layout, lock history, and wallpaper assignments stay on this Mac. When you explicitly submit through Creator Studio, WALI uploads that media, its original filename, and the metadata you provide for processing and moderation.")
                        .foregroundStyle(.secondary)

                    if case .signedIn = account {
                        exportStatus

                        HStack {
                            Button(exportButtonTitle, action: exportButtonAction)
                                .disabled(profile == nil || exportIsBusy)
                            if exportCanRefresh {
                                Button("Refresh Status", action: onRefreshExport)
                            }
                        }
                    }
                }

                if case .signedIn = account {
                    Section("Delete Account") {
                        Text("Removes or anonymizes your marketplace account data and sign-in identity. Limited records may be retained when required by the applicable policy. Local wallpapers remain on this Mac. You can check an accepted request here after sign-out, while pending and for 30 days after completion.")
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

            } else {
                Section {
                    Label(MarketplaceUnavailableView.title, systemImage: "person.crop.circle")
                        .font(.headline)
                    Text(MarketplaceCoordinator.unavailableAccountMessage)
                        .foregroundStyle(.secondary)
                    Text("Your local-library filenames, display layout, and wallpaper assignments stay on this Mac.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("WALI.Account.Unavailable")
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
        .scrollContentBackground(.hidden)
        .clipped()
    }

    @ViewBuilder
    private var signInButton: some View {
        if #available(macOS 26.0, *) {
            Button(signInTitle, systemImage: signInSymbol, action: onSignIn)
                .buttonStyle(.glassProminent)
                .disabled(authenticationState == .working)
        } else {
            Button(signInTitle, systemImage: signInSymbol, action: onSignIn)
                .buttonStyle(.borderedProminent)
                .disabled(authenticationState == .working)
        }
    }

    private var signInTitle: String {
        authenticationMethod == .emailOTP ? "Sign in with Email" : "Sign in with Apple"
    }

    private var signInSymbol: String {
        authenticationMethod == .emailOTP ? "envelope" : "apple.logo"
    }

    private var accountIsSignedIn: Bool {
        if case .signedIn = account { return true }
        return false
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
        switch exportState {
        case .ready: "Save Export…"
        case .queued: "Export Queued"
        case .processing: "Preparing Export…"
        default: "Request Export"
        }
    }

    private var exportIsBusy: Bool {
        switch exportState {
        case .working, .queued, .processing: true
        default: false
        }
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
        VStack(alignment: .leading, spacing: 16) {
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
        .frame(minWidth: 440, idealWidth: 480)
        .background(Color(nsColor: .windowBackgroundColor))
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
