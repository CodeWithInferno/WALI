import SwiftUI

struct CreatorTermsReviewView: View {
    let document: CreatorTermsDocument
    let accessState: MarketplaceCreatorAccessState
    var lastFailureCode: String? = nil
    let onAccept: () -> Void
    let onCancel: () -> Void

    @State private var confirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terms
            Divider()
            actions
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 640)
        .interactiveDismissDisabled(accessState == .acceptingTerms)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(.title2)
                .fontWeight(.semibold)
            HStack(spacing: 8) {
                Text("Version \(document.version)")
                Text("•")
                    .accessibilityHidden(true)
                Text(document.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(document.introduction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var terms: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.headline)
                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "I have read these terms and confirm I have the rights required for anything I submit.",
                isOn: $confirmed
            )
            .toggleStyle(.checkbox)
            .disabled(accessState == .acceptingTerms)

            if accessState == .failed {
                Label(
                    failureMessage,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(accessState == .acceptingTerms)
                Button {
                    onAccept()
                } label: {
                    if accessState == .acceptingTerms {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Accepting Creator Terms")
                    } else {
                        Text("Accept and Enable Studio")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!confirmed || accessState == .acceptingTerms)
            }
        }
        .padding(20)
    }

    private var failureMessage: String {
        switch lastFailureCode {
        case "request_timed_out":
            "Enabling Creator Studio took too long. Try again."
        case "auth_required", "authentication_required", "invalid_session", "session_expired":
            "Your session has expired. Close this sheet and sign in again."
        case "creator_terms_required":
            "The Creator Terms have changed. Close this sheet and refresh your account to review them."
        case "account_suspended", "account_inactive":
            "Creator Studio is unavailable for this account. Contact support for help."
        case "creator_role_required", "forbidden":
            "This account doesn’t have creator access. Contact support for help."
        case "rate_limited":
            "Too many attempts. Wait a few minutes before trying again."
        case "invalid_request", "unsupported_api_version":
            "The service couldn’t accept this request. Check for a WALI update and try again."
        default:
            "Creator Studio couldn’t be enabled. Try again in a moment."
        }
    }
}
