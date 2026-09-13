import AVKit
import CoreGraphics
import SwiftUI
import WALICatalogRuntime

public struct ReviewQueueView: View {
    @Bindable private var model: CreatorModerationModel

    public init(model: CreatorModerationModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if !model.canShowReviewQueue {
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 0) {
                    WALIPageHeader("Review Queue") {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadQueue() } }
                            .labelStyle(.iconOnly)
                            .disabled(model.queueState == .loading)
                    }
                    Picker("Submission status", selection: $model.queueFilter) {
                        Text("Needs Review").tag("pending")
                        Text("Ready to Publish").tag("approved")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    queueContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle("Review Queue")
        .task(id: model.authorization) {
            guard model.canShowReviewQueue else { return }
            await model.loadQueue()
        }
        .onChange(of: model.queueFilter) { _, _ in Task { await model.loadQueue() } }
    }

    @ViewBuilder
    private var queueContent: some View {
        switch model.queueState {
        case .idle, .loading:
            ProgressView("Loading protected review queue…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView(
                model.queueFilter == "approved" ? "No wallpapers ready to publish" : "Review queue is clear",
                systemImage: "checkmark.circle",
                description: Text(model.queueFilter == "approved"
                    ? "Approved submissions appear here before they go live."
                    : "New submissions appear here after media processing.")
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
                description: Text(model.queueErrorMessage)
            )
        case .restricted:
            EmptyView()
        case .ready:
            List {
              ForEach(model.queueItems) { item in
                NavigationLink(value: item) {
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
              if let error = model.pageError { Text(error).foregroundStyle(.secondary) }
              if model.nextCursor != nil {
                  Button("Load More") { Task { await model.loadQueue(more: true) } }
                      .disabled(model.isLoadingMore)
              }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
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
        VStack(spacing: 0) {
            WALIPageHeader("Reports") {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadReports() } }
                    .labelStyle(.iconOnly)
                    .disabled(model.reportsState == .loading || !model.canShowReviewQueue)
            }
            reportContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Reports")
        .task(id: model.authorization) {
            guard model.canShowReviewQueue else { return }
            await model.loadReports()
        }
    }

    private var reportContent: some View {
        Group {
            if model.canShowReviewQueue {
                if model.reportsState == .idle || model.reportsState == .loading {
                    ProgressView("Loading reports…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.reportsState == .failed || model.reportsState == .offline {
                    ContentUnavailableView {
                        Label("Couldn’t load reports", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Refresh to try again.")
                    } actions: {
                        Button("Try Again") { Task { await model.loadReports() } }
                    }
                } else if model.reports.isEmpty {
                    ContentUnavailableView(
                        "No reports to review",
                        systemImage: "checkmark.shield",
                        description: Text("Open or assigned reports will appear here.")
                    )
                } else {
                    List {
                        ForEach(model.reports) { report in
                            NavigationLink(value: report) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.wallpaperTitle).font(.headline)
                                    Label(report.reasonCode.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "flag")
                                        .foregroundStyle(.secondary)
                                    Text(report.safeSummary).lineLimit(2)
                                    Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        if let error = model.reportsPageError { Text(error).foregroundStyle(.secondary) }
                        if model.reportsNextCursor != nil {
                            Button(model.isLoadingMoreReports ? "Loading…" : "Load More Reports") {
                                Task { await model.loadReports(more: true) }
                            }
                            .disabled(model.isLoadingMoreReports)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } else {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
    }
}

struct ReportReviewView: View {
    let report: ModerationReport
    @Bindable var model: CreatorModerationModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoadingMedia = false
    @State private var reviewImage: CGImage?
    @State private var mediaGeneration: UInt64 = 0
    @State private var loadedMediaIdentity: String?
    @State private var action: ModerationReportAction = .hidePendingReview
    @State private var reasonCode = "other"
    @State private var note = ""
    @State private var hasReviewed = false
    @State private var showsConfirmation = false

    var body: some View {
        Group {
            if model.canShowReviewQueue {
                VStack(spacing: 0) {
                    WALIPageHeader("Review Report") { EmptyView() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.wallpaperTitle).font(.title2.bold())
                                Text("Marketplace status: \(currentWallpaperStatus.rawValue.capitalized)")
                                    .foregroundStyle(.secondary)
                                if let edition = report.edition {
                                    Text("Reported edition \(edition)").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            GroupBox("Report") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(report.reasonCode.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "flag")
                                    Text(report.safeSummary).textSelection(.enabled)
                                    Text(report.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                            GroupBox("Reported Wallpaper") {
                                if let reviewImage, loadedMediaIdentity == mediaIdentity {
                                    Image(reviewImage, scale: 1, label: Text("Still wallpaper")).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity, maxHeight: 400)
                                        .accessibilityLabel("Reported still wallpaper")
                                } else if let player, loadedMediaIdentity == mediaIdentity {
                                    VideoPlayer(player: player)
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .frame(maxHeight: 400)
                                        .accessibilityLabel("Reported wallpaper full video")
                                } else if isLoadingMedia {
                                    ProgressView("Preparing wallpaper…")
                                        .frame(maxWidth: .infinity, minHeight: 140)
                                } else {
                                    VStack(spacing: 8) {
                                        Label("Wallpaper unavailable", systemImage: "photo.badge.exclamationmark")
                                        Text("Return to Reports and refresh if the private media link has expired.")
                                            .font(.callout).foregroundStyle(.secondary)
                                        Button("Try Again") { Task { await loadMedia() } }
                                    }.frame(maxWidth: .infinity, minHeight: 140)
                                }
                            }
                            decisionForm
                        }
                        .padding(24)
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Review Report")
        .task(id: mediaIdentity) {
            player?.pause(); player = nil; reviewImage = nil; isLoadingMedia = false
            model.prepareReport(report)
            reasonCode = Self.reasons.contains(report.reasonCode) ? report.reasonCode : "other"
            await loadMedia()
        }
        .confirmationDialog(action.title, isPresented: $showsConfirmation) {
            Button(action.title, role: action == .delist ? .destructive : nil) {
                Task { await model.resolveReport(report, action: action,
                    reasonCode: action == .closeNoAction ? "no_violation" : reasonCode,
                    privateNote: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        } message: { Text(action.explanation) }
        .onDisappear {
            player?.pause()
            player = nil; reviewImage = nil; mediaGeneration &+= 1; isLoadingMedia = false
            model.finishReport(report)
        }
        .onChange(of: model.canShowReviewQueue) { _, permitted in
            if !permitted { player?.pause(); player = nil; reviewImage = nil; note = ""; hasReviewed = false }
        }
    }

    @ViewBuilder private var decisionForm: some View {
        if let result = model.reportResolution, result.reportID == report.id {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Decision recorded", systemImage: "checkmark.circle.fill").font(.headline)
                    Text(result.status == .triaged
                        ? "The wallpaper is unavailable in the marketplace. The report remains open for follow-up."
                        : "The report is closed. Marketplace status: \(result.wallpaperStatus.rawValue.capitalized).")
                    Button("Back to Reports") { dismiss() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        } else if model.reportDecisionState == .staleReloaded {
            ContentUnavailableView {
                Label("This report changed", systemImage: "arrow.clockwise")
            } description: {
                Text("Return to Reports and open the latest version before deciding.")
            } actions: { Button("Back to Reports") { dismiss() } }
        } else {
            GroupBox("Decision") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Action", selection: $action) {
                        ForEach(ModerationReportAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(action.explanation).font(.callout).foregroundStyle(.secondary)
                    if action != .closeNoAction {
                        Picker("Reason", selection: $reasonCode) {
                            ForEach(Self.reasons, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                    TextField("Private decision note (required)", text: $note)
                        .textFieldStyle(.roundedBorder)
                    Text("Only the moderation team can read this note.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("I reviewed the report and the available evidence.", isOn: $hasReviewed)
                        .toggleStyle(.checkbox)
                    if model.reportDecisionState == .failed {
                        Label("The decision couldn’t be confirmed. Try again.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    Button(model.reportDecisionState == .submitting ? "Saving…" : "Record Decision") {
                        showsConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasReviewed || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 2_000)
                }
                .disabled(model.reportDecisionState == .submitting)
                .padding(8)
            }
        }
    }

    private var currentWallpaperStatus: ModerationWallpaperStatus {
        guard let result = model.reportResolution, result.reportID == report.id else {
            return report.wallpaperStatus
        }
        return result.wallpaperStatus
    }

    private var mediaIdentity: String {
        "\(report.id):\(report.revision):\(model.authorization.subjectID ?? "none"):\(model.authorization.moderatorGrantRevision ?? 0)"
    }

    @MainActor private func loadMedia() async {
        guard !isLoadingMedia else { return }
        mediaGeneration &+= 1
        let generation = mediaGeneration
        let authority = model.authorization
        isLoadingMedia = true
        defer { if generation == mediaGeneration { isLoadingMedia = false } }
        guard let media = await model.loadReportMedia(report), !Task.isCancelled,
              model.canShowReviewQueue, model.authorization == authority, generation == mediaGeneration
        else { return }
        switch media {
        case .video(let url):
            player?.pause(); reviewImage = nil; player = AVPlayer(url: url); loadedMediaIdentity = mediaIdentity
        case .still(let source):
            let image = try? await CreatorModerationImageLoader.shared.load(source)
            guard !Task.isCancelled, model.canShowReviewQueue, model.authorization == authority,
                  generation == mediaGeneration else { return }
            player?.pause(); player = nil; reviewImage = image; loadedMediaIdentity = mediaIdentity
        }
    }

    private static let reasons = ["copyright", "impersonation", "unsafe", "sexual", "hate", "violence", "spam", "misleading", "other"]
}

private extension ModerationReportAction {
    var title: String {
        switch self {
        case .closeNoAction: "Close Without Action"
        case .hidePendingReview: "Hide Pending Review"
        case .delist: "Remove from Marketplace"
        }
    }
    var explanation: String {
        switch self {
        case .closeNoAction: "Close this report without changing the wallpaper’s current visibility. A hidden wallpaper stays hidden."
        case .hidePendingReview: "Stop new marketplace downloads and hide the listing while the team investigates. Keep this report open."
        case .delist: "Remove this listing from the marketplace, stop new downloads, and close the report. Existing library copies remain on users’ devices."
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
    @State private var reviewPlayer: AVPlayer?
    @State private var isLoadingMedia = false
    @State private var reviewImage: CGImage?
    @State private var mediaGeneration: UInt64 = 0
    @State private var loadedMediaIdentity: String?
    @State private var reviewedFullMedia = false
    @State private var showsPublishConfirmation = false

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
              VStack(spacing: 0) {
                WALIPageHeader(item.proposedTitle) { EmptyView() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        canonicalPreview
                        metadata
                        serverFacts
                        suggestions
                        if item.state == .approved { publicationForm } else { decisionForm }
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
              }
            } else {
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .navigationTitle(item.proposedTitle)
        .task(id: mediaIdentity) {
            reviewPlayer?.pause(); reviewPlayer = nil; reviewImage = nil; isLoadingMedia = false; reviewedFullMedia = false
            model.prepareReview(item)
            await loadMedia()
        }
        .confirmationDialog("Publish this wallpaper?", isPresented: $showsPublishConfirmation) {
            Button("Publish Wallpaper") { Task { await model.publish(item) } }
        } message: {
            Text("This approved version will become available to everyone in the marketplace.")
        }
        .onDisappear {
            reviewPlayer?.pause()
            reviewPlayer = nil; reviewImage = nil; mediaGeneration &+= 1; isLoadingMedia = false
            model.finishReview(item)
        }
        .onChange(of: model.canShowReviewQueue) { _, permitted in
            if !permitted {
                reviewPlayer?.pause()
                reviewPlayer = nil; reviewImage = nil
                reviewedFullMedia = false
            }
        }
    }

    @ViewBuilder
    private var canonicalPreview: some View {
        GroupBox("Review Wallpaper") {
            if let reviewImage, loadedMediaIdentity == mediaIdentity {
                Image(reviewImage, scale: 1, label: Text("Still wallpaper")).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 440)
                    .accessibilityLabel("Full still wallpaper")
            } else if let reviewPlayer, loadedMediaIdentity == mediaIdentity {
                VideoPlayer(player: reviewPlayer)
                .frame(maxWidth: .infinity, maxHeight: 440)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel("Full wallpaper video")
            } else if isLoadingMedia {
                ProgressView("Preparing wallpaper…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ContentUnavailableView {
                    Label("Wallpaper couldn’t be loaded", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("Refresh the queue if its private media link has expired.")
                } actions: {
                    Button("Try Again") { Task { await loadMedia() } }
                }
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
            Text("Review the complete wallpaper and its rights before approving. Play live wallpapers through their full duration.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private var mediaIdentity: String {
        "\(item.id):\(item.revision):\(item.generation):\(model.authorization.subjectID ?? "none"):\(model.authorization.moderatorGrantRevision ?? 0)"
    }

    private func loadMedia() async {
        guard !isLoadingMedia else { return }
        mediaGeneration &+= 1
        let generation = mediaGeneration
        let authority = model.authorization
        isLoadingMedia = true
        defer { if generation == mediaGeneration { isLoadingMedia = false } }
        guard let media = await model.loadReviewMedia(for: item), !Task.isCancelled,
              model.canShowReviewQueue, model.authorization == authority, generation == mediaGeneration
        else { return }
        switch media {
        case .video(let url):
            reviewPlayer?.pause(); reviewImage = nil; reviewPlayer = AVPlayer(url: url); loadedMediaIdentity = mediaIdentity
        case .still(let source):
            let image = try? await CreatorModerationImageLoader.shared.load(source)
            guard !Task.isCancelled, model.canShowReviewQueue, model.authorization == authority,
                  generation == mediaGeneration else { return }
            reviewPlayer?.pause(); reviewPlayer = nil; reviewImage = image; loadedMediaIdentity = mediaIdentity
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
                    if let frameRate = facts.frameRate { LabeledContent("Frame rate", value: frameRate.formatted()) }
                    if let duration = facts.durationMilliseconds { LabeledContent("Duration", value: "\(duration) ms") }
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
        GroupBox("Review decision") {
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

                Menu(selectedReasons.isEmpty ? "Choose a reason (required)" : "Reasons (\(selectedReasons.count))") {
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
                TextField("Note to creator (required)", text: $creatorNote, axis: .vertical)
                    .lineLimit(2...6)
                SecureField("Private moderator note (optional)", text: $privateNote)
                if decision == .approved {
                    Toggle("I reviewed the complete wallpaper and its rights declaration", isOn: $reviewedFullMedia)
                        .disabled(loadedMediaIdentity != mediaIdentity || (reviewPlayer == nil && reviewImage == nil))
                }
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
                } else if model.decisionState == .succeeded {
                    Label("Decision recorded", systemImage: "checkmark.circle")
                } else if model.decisionState == .failed {
                    Label("The decision couldn’t be recorded. Refresh the queue and try again.", systemImage: "exclamationmark.triangle")
                }
            }
            .padding(4)
        }
        .onChange(of: decision) { _, _ in
            selectedReasons.formIntersection(Set(availableReasons.map(\.code)))
        }
    }

    private var publicationForm: some View {
        GroupBox("Publication") {
            VStack(alignment: .leading, spacing: 12) {
                if case .published = model.publicationState {
                    Text("This version is available in the marketplace.")
                } else {
                    Text("This submission is approved. Publish it to make this version available in the marketplace.")
                }
                switch model.publicationState {
                case .publishing:
                    ProgressView("Preparing publication…").controlSize(.small)
                case let .published(release):
                    Label("Published · Edition \(release.edition)", systemImage: "checkmark.seal")
                case .awaitingPromotion:
                    Text("The verified media is still being prepared. Check again in a moment.")
                    Button("Check Publication") { Task { await model.publish(item) } }
                case .failed:
                    Text("Publication couldn’t be confirmed. Retry to check the same request safely.")
                    Button("Retry Publication") { Task { await model.publish(item) } }
                case .idle:
                    Button("Publish Wallpaper…") { showsPublishConfirmation = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var checklistRevision: UInt64 { moderationMetadata.checklistRevision }

    private var availableReasons: [ModerationReasonOption] {
        moderationMetadata.reasons(for: decision)
    }

    private var canRecordDecision: Bool {
        model.decisionState != .submitting
            && model.decisionState != .succeeded
            && (decision != .approved || (loadedMediaIdentity == mediaIdentity && (reviewPlayer != nil || reviewImage != nil) && reviewedFullMedia))
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
