import SwiftUI

struct CreatorTermsReviewView: View {
    let document: CreatorTermsDocument
    let accessState: MarketplaceCreatorAccessState
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
                    "WALI couldn’t record your acceptance. Check your connection and try again.",
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
}
