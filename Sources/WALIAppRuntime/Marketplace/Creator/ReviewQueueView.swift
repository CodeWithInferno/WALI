import SwiftUI
import WALICatalogRuntime

public struct ReviewQueueView: View {
    @Bindable private var model: CreatorModerationModel
    private let reviewDestination: (ModerationQueueItem) -> AnyView

    public init(
        model: CreatorModerationModel,
        @ViewBuilder reviewDestination: @escaping (ModerationQueueItem) -> some View
    ) {
        self.model = model
        self.reviewDestination = { AnyView(reviewDestination($0)) }
    }

    public var body: some View {
        Group {
            if !model.canShowReviewQueue {
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            } else {
                queueContent
            }
        }
        .navigationTitle("Review Queue")
        .task {
            guard model.canShowReviewQueue else { return }
            await model.loadQueue()
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        switch model.queueState {
        case .idle, .loading:
            ProgressView("Loading protected review queue…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                "Review queue is clear",
                systemImage: "checkmark.circle",
                description: Text("New submissions will appear here after server verification.")
            )
        case .offline:
            ContentUnavailableView(
                "Review queue is offline",
                systemImage: "wifi.slash",
                description: Text("No protected queue data is retained after this failure.")
            )
        case .failed:
            ContentUnavailableView(
                "Couldn’t load reviews",
                systemImage: "exclamationmark.triangle",
                description: Text("Try again. Private server details are not displayed.")
            )
        case .restricted:
            EmptyView()
        case .ready:
            List(model.queueItems) { item in
                NavigationLink {
                    reviewDestination(item)
                } label: {
                    HStack(spacing: 12) {
                        canonicalPoster(for: item)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.proposedTitle).font(.headline)
                            Text("@\(item.creator.handle) · \(item.primaryCategoryName)")
                                .foregroundStyle(.secondary)
                            Text("Revision \(item.revision) · Generation \(item.generation)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.findings.contains(where: { $0.severity == .blocking }) {
                            Label("Blocking finding", systemImage: "xmark.octagon.fill")
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Has a blocking finding")
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func canonicalPoster(for item: ModerationQueueItem) -> some View {
        if let poster = item.canonicalArtifacts.first(where: { $0.role == .poster }) {
            AsyncImage(url: model.localURL(for: poster)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack { Rectangle().fill(.quaternary); ProgressView().controlSize(.small) }
            }
            .frame(width: 96, height: 54)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel("Canonical poster for \(item.proposedTitle)")
        } else {
            Image(systemName: "photo")
                .frame(width: 96, height: 54)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityLabel("Canonical poster unavailable")
        }
    }
}

public struct ReportQueueView: View {
    @Bindable private var model: CreatorModerationModel

    public init(model: CreatorModerationModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.canShowReviewQueue {
                if model.reports.isEmpty {
                    ContentUnavailableView(
                        "No assigned reports",
                        systemImage: "checkmark.shield",
                        description: Text("Open or assigned reports will appear here.")
                    )
                } else {
                    List(model.reports) { report in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(report.reasonCode, systemImage: "flag")
                                .font(.headline)
                            Text(report.safeSummary)
                            Text("Revision \(report.revision) · \(report.createdAt.formatted())")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                }
            } else {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .navigationTitle("Reports")
        .task {
            guard model.canShowReviewQueue else { return }
            await model.loadReports()
        }
    }
}

public struct SubmissionReviewView: View {
    private let item: ModerationQueueItem
    @Bindable private var model: CreatorModerationModel
    private let moderationMetadata: ModerationMetadata

    @State private var decision: ModerationDecision = .changesRequested
    @State private var selectedReasons: Set<String> = []
    @State private var creatorNote = ""
    @State private var privateNote = ""

    public init(
        item: ModerationQueueItem,
        model: CreatorModerationModel,
        moderationMetadata: ModerationMetadata
    ) {
        self.item = item
        self.model = model
        self.moderationMetadata = moderationMetadata
    }

    public var body: some View {
        Group {
            if model.canShowReviewQueue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        canonicalPreview
                        metadata
                        serverFacts
                        suggestions
                        decisionForm
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .navigationTitle(item.proposedTitle)
    }

    @ViewBuilder
    private var canonicalPreview: some View {
        GroupBox("Canonical review artifact") {
            if let poster = item.canonicalArtifacts.first(where: { $0.role == .poster }) {
                AsyncImage(url: model.localURL(for: poster)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: 440)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel("Verified canonical poster")
            } else {
                ContentUnavailableView("Canonical preview unavailable", systemImage: "photo.badge.exclamationmark")
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
            Label(
                "Only verified canonical output is shown. Raw uploads and rights proof never enter this player.",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private var metadata: some View {
        GroupBox("Creator-provided metadata") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Creator", value: "@\(item.creator.handle)")
                LabeledContent("Description", value: item.proposedDescription)
                LabeledContent("Category", value: item.primaryCategoryName)
                LabeledContent("Tags", value: item.tagNames.joined(separator: ", "))
                LabeledContent("Rating", value: item.contentRating)
                LabeledContent("Rights", value: item.rightsSummary)
                LabeledContent("Proof", value: item.proofStatus.reviewLabel)
                if let attribution = item.attributionText {
                    LabeledContent("Attribution", value: attribution)
                }
                if let source = item.sourceURL {
                    LabeledContent("Source") { Link(source.absoluteString, destination: source) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var serverFacts: some View {
        GroupBox("Server-observed facts") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Revision \(item.revision) · Generation \(item.generation)")
                    .font(.callout.monospacedDigit())
                if let facts = item.mediaFacts {
                    LabeledContent("Media", value: "\(facts.width) × \(facts.height) · \(facts.codec)")
                    LabeledContent("Frame rate", value: facts.frameRate.formatted())
                    LabeledContent("Duration", value: "\(facts.durationMilliseconds) ms")
                }
                ForEach(item.findings) { finding in
                    Label(finding.message, systemImage: finding.severity.reviewSymbol)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        GroupBox {
            if item.modelSuggestions.isEmpty {
                Text("No model suggestions")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.modelSuggestions) { suggestion in
                        Label(
                            "\(suggestion.value) · \(suggestion.confidence.formatted(.percent))",
                            systemImage: "sparkles"
                        )
                        .help("Model \(suggestion.modelID), revision \(suggestion.modelRevision)")
                    }
                }
            }
        } label: {
            Label("Model suggestions — advisory", systemImage: "wand.and.stars")
        }
    }

    private var decisionForm: some View {
        GroupBox("Revision-bound decision") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Decision", selection: $decision) {
                    ForEach(ModerationDecision.allCases, id: \.self) { decision in
                        Text(decision.reviewLabel).tag(decision)
                    }
                }
                .pickerStyle(.segmented)
                Text("This action targets revision \(item.revision), generation \(item.generation), checklist \(checklistRevision).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Menu("Structured reasons (\(selectedReasons.count))") {
                    ForEach(availableReasons) { reason in
                            Toggle(reason.label, isOn: Binding(
                                get: { selectedReasons.contains(reason.code) },
                                set: { selected in
                                    if selected, selectedReasons.count < 20 { selectedReasons.insert(reason.code) }
                                    if !selected { selectedReasons.remove(reason.code) }
                                }
                            ))
                        }
                }
                TextField("Note to creator", text: $creatorNote, axis: .vertical)
                    .lineLimit(2...6)
                SecureField("Private moderator note", text: $privateNote)
                HStack {
                    if model.decisionState == .submitting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Record Decision") {
                        Task {
                            await model.moderate(
                                item,
                                decision: decision,
                                checklistRevision: moderationMetadata.checklistRevision,
                                reasonCodes: Array(selectedReasons).sorted(),
                                creatorNote: creatorNote,
                                privateNote: privateNote
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRecordDecision)
                }
                if model.decisionState == .staleReloaded {
                    Label("The submission changed. The queue was refreshed; no stale decision was applied.", systemImage: "arrow.clockwise.circle")
                }
            }
            .padding(4)
        }
        .onChange(of: decision) { _, _ in
            selectedReasons.formIntersection(Set(availableReasons.map(\.code)))
        }
    }

    private var checklistRevision: UInt64 { moderationMetadata.checklistRevision }

    private var availableReasons: [ModerationReasonOption] {
        moderationMetadata.reasons(for: decision)
    }

    private var canRecordDecision: Bool {
        model.decisionState != .submitting
            && !selectedReasons.isEmpty
            && !creatorNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension CreatorProofStatus {
    var reviewLabel: String {
        rawValue.replacingOccurrences(of: "_", with: " ").localizedCapitalized
    }
}

private extension CreatorFindingSeverity {
    var reviewSymbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }
}

private extension ModerationDecision {
    var reviewLabel: String {
        switch self {
        case .approved: "Approve"
        case .changesRequested: "Request Changes"
        case .rejected: "Reject"
        }
    }
}
