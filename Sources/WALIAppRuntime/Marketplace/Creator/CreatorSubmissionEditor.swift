import Foundation
import SwiftUI
import WALICatalogRuntime

public struct CreatorSubmissionEditor: View {
    private let submissionID: UUID
    private let gateway: any CreatorStudioGateway
    private let categories: [CreatorTaxonomyOption]
    private let tags: [CreatorTaxonomyOption]
    private let licenses: [CreatorLicenseOption]
    private let currentTermsVersion: String
    private let creatorFacingNote: String?
    private let wallpaperStatus: ModerationWallpaperStatus?
    private let moderationReasonCodes: [String]
    private let didChange: (CreatorMutationResult) -> Void

    @State private var revision: UInt64
    @State private var generation: UInt64
    @State private var state: CreatorSubmissionState
    @State private var title: String
    @State private var description: String
    @State private var categoryID: UUID?
    @State private var selectedTagIDs: Set<UUID>
    @State private var contentWarning: String
    @State private var rightsBasis: CreatorRightsBasis
    @State private var rightsHolder: String
    @State private var licenseID: UUID?
    @State private var sourceURL: String
    @State private var attributionText: String
    @State private var proofObjectIDs: [UUID]
    @State private var attestsRights: Bool
    @State private var acceptsCurrentTerms: Bool
    @State private var activity: EditorActivity = .idle
    @State private var processingStatus: CreatorProcessingStatus?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    public init(
        submission: CreatorSubmission,
        gateway: any CreatorStudioGateway,
        categories: [CreatorTaxonomyOption],
        tags: [CreatorTaxonomyOption],
        licenses: [CreatorLicenseOption],
        currentTermsVersion: String,
        didChange: @escaping (CreatorMutationResult) -> Void
    ) {
        submissionID = submission.id
        self.gateway = gateway
        self.categories = categories
        self.tags = tags
        self.licenses = licenses
        self.currentTermsVersion = currentTermsVersion
        _processingStatus = State(initialValue: submission.processing)
        creatorFacingNote = submission.creatorFacingNote
        wallpaperStatus = submission.wallpaperStatus
        moderationReasonCodes = submission.moderationReasonCodes
        self.didChange = didChange
        let draft = submission.draft
        _revision = State(initialValue: submission.revision)
        _generation = State(initialValue: submission.generation)
        _state = State(initialValue: submission.state)
        _title = State(initialValue: draft?.title ?? "")
        _description = State(initialValue: draft?.description ?? "")
        _categoryID = State(initialValue: draft?.primaryCategoryID)
        _selectedTagIDs = State(initialValue: Set(draft?.suggestedTagIDs ?? []))
        _contentWarning = State(initialValue: draft?.contentWarning ?? "")
        _rightsBasis = State(initialValue: draft?.rights.basis ?? .original)
        _rightsHolder = State(initialValue: draft?.rights.rightsHolder ?? "")
        _licenseID = State(initialValue: draft?.rights.licenseID)
        _sourceURL = State(initialValue: draft?.rights.sourceURL?.absoluteString ?? "")
        _attributionText = State(initialValue: draft?.rights.attributionText ?? "")
        _proofObjectIDs = State(initialValue: draft?.rights.proofObjectIDs ?? [])
        _attestsRights = State(initialValue: draft?.rights.attestsRights ?? false)
        _acceptsCurrentTerms = State(initialValue: false)
    }

    public var body: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Wallpaper Submission") { EmptyView() }
            submissionForm
        }
        .navigationTitle(title.isEmpty ? "Wallpaper Submission" : title)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshProcessingWhileActive()
        }
    }

    private var submissionForm: some View {
        Form {
            if let restriction = wallpaperStatus?.creatorRestrictionLabel {
                Section("Marketplace Listing") {
                    Label(restriction, systemImage: "eye.slash")
                    Text("This wallpaper is unavailable for new marketplace downloads. Its submission history and existing local Library copies are preserved.")
                        .foregroundStyle(.secondary)
                }
            }
            if state == .changesRequested || state == .rejected {
                Section(state == .changesRequested ? "Changes requested" : "Review feedback") {
                    if let creatorFacingNote, !creatorFacingNote.isEmpty {
                        Text(creatorFacingNote)
                    }
                    ForEach(moderationReasonCodes, id: \.self) { reason in
                        Text(reason.replacingOccurrences(of: "_", with: " ").localizedCapitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if state == .processingFailed {
                Section {
                    Label("This video couldn’t be prepared", systemImage: "exclamationmark.triangle")
                    Text("Return to Creator Studio and upload another video to create a new submission.")
                        .foregroundStyle(.secondary)
                    Button("Back to Submissions") { dismiss() }
                }
            }
            Section("Your wallpaper details") {
                TextField("Title", text: $title)
                    .accessibilityLabel("Title")
                    .accessibilityHint("Creator-provided title, maximum 120 characters")
                TextField("Description", text: $description, axis: .vertical)
                    .accessibilityLabel("Description")
                    .lineLimit(3...8)
                Picker("Primary category", selection: $categoryID) {
                    Text("Choose a category").tag(UUID?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                Menu("Tags (\(selectedTagIDs.count)/20)") {
                    ForEach(tags) { tag in
                        Toggle(tag.name, isOn: Binding(
                            get: { selectedTagIDs.contains(tag.id) },
                            set: { selected in
                                if selected, selectedTagIDs.count < 20 {
                                    selectedTagIDs.insert(tag.id)
                                } else if !selected {
                                    selectedTagIDs.remove(tag.id)
                                }
                            }
                        ))
                    }
                }
                TextField("Content warning (optional)", text: $contentWarning, axis: .vertical)
                    .accessibilityLabel("Content warning (optional)")
                    .lineLimit(1...4)
            }
            .disabled(activity == .working || !canEdit)

            if let processing = processingStatus {
                Section {
                ProcessingStatusView(status: processing, state: state)
                }
            }

            modelSuggestions
                .disabled(activity == .working || !canEdit)

            RightsDeclarationView(
                basis: $rightsBasis,
                rightsHolder: $rightsHolder,
                selectedLicenseID: $licenseID,
                sourceURL: $sourceURL,
                attributionText: $attributionText,
                proofObjectIDs: $proofObjectIDs,
                attestsRights: $attestsRights,
                acceptsCurrentTerms: $acceptsCurrentTerms,
                licenses: licenses,
                currentTermsVersion: currentTermsVersion
            )
            .disabled(activity == .working || !canEdit)

            Section {
                HStack {
                    Spacer()
                    if activity == .working { ProgressView().controlSize(.small) }
                    Button("Save Draft") { Task { await save() } }
                        .disabled(activity == .working || !canEdit)
                    Button("Submit for Review") { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit || activity == .working)
                }
                if case let .failed(code) = activity {
                    Label(failureMessage(for: code), systemImage: "exclamationmark.triangle")
                } else if activity == .stale {
                    Label("This submission changed. Reopen it from Creator Studio before editing.", systemImage: "arrow.clockwise.circle")
                    Button("Back to Submissions") { dismiss() }
                } else if activity == .saved {
                    Label("Draft saved", systemImage: "checkmark.circle")
                } else if activity == .submitted {
                    Label("Submitted for review", systemImage: "checkmark.circle")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .defaultScrollAnchor(.top)
        .clipped()
    }

    @ViewBuilder
    private var modelSuggestions: some View {
        let suggestions = processingStatus?.suggestions ?? []
        Section {
            if suggestions.isEmpty {
                Text(state == .processing || state == .uploaded || state == .uploading
                     ? "Suggestions may appear after WALI verifies the uploaded media."
                     : "No suggestions are available. Add your wallpaper’s details above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "sparkles")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.value)
                            Text("Suggested \(suggestion.kind.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if suggestion.kind == .title || suggestion.kind == .description {
                            Button("Use") { apply(suggestion) }
                        }
                    }
                }
            }
        } header: {
            Label("Suggestions", systemImage: "wand.and.stars")
        } footer: {
            Text("Review each suggestion before adding it to your wallpaper.")
        }
    }

    private var canEdit: Bool {
        switch state {
        case .draft, .readyForSubmission, .changesRequested:
            activity != .stale
        default:
            false
        }
    }

    private var requirements: CreatorRightsRequirements {
        rightsRequirements(basis: rightsBasis, license: licenses.first(where: { $0.id == licenseID }))
    }

    private var canSubmit: Bool {
        acceptsCurrentTerms && attestsRights && generation > 0
            && (state == .readyForSubmission || state == .changesRequested) && canEdit && !requirements.requiresProof
            && (try? makeDraft()) != nil
    }

    private func makeDraft() throws -> CreatorDraft {
        guard let categoryID, let licenseID else { throw CreatorContractError.invalidRequest }
        let parsedSource: URL?
        if sourceURL.isEmpty {
            parsedSource = nil
        } else {
            guard let value = URL(string: sourceURL) else { throw CreatorContractError.invalidRequest }
            parsedSource = value
        }
        let rights = try CreatorRightsDeclaration(
            basis: rightsBasis,
            rightsHolder: rightsHolder,
            licenseID: licenseID,
            sourceURL: parsedSource,
            attributionText: attributionText.isEmpty ? nil : attributionText,
            proofObjectIDs: proofObjectIDs,
            attestsRights: attestsRights,
            requirements: requirements
        )
        return try CreatorDraft(
            title: title,
            description: description,
            primaryCategoryID: categoryID,
            suggestedTagIDs: Array(selectedTagIDs).sorted { $0.uuidString < $1.uuidString },
            contentWarning: contentWarning.isEmpty ? nil : contentWarning,
            rights: rights
        )
    }

    private func save() async {
        guard activity != .working, canEdit else { return }
        let boundRevision = revision
        let boundGeneration = generation
        activity = .working
        do {
            let request = try CreatorSaveDraftRequest(
                submissionID: submissionID,
                expectedRevision: boundRevision,
                draft: makeDraft(),
                creatorTermsVersion: currentTermsVersion,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            let result = try await gateway.saveDraft(request)
            guard revision == boundRevision, generation == boundGeneration else { return }
            apply(result)
            activity = .saved
        } catch {
            present(error)
        }
    }

    private func submit() async {
        guard activity != .working, canSubmit else { return }
        let boundRevision = revision
        let boundGeneration = generation
        activity = .working
        do {
            let saveRequest = try CreatorSaveDraftRequest(
                submissionID: submissionID,
                expectedRevision: boundRevision,
                draft: makeDraft(),
                creatorTermsVersion: currentTermsVersion,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            let saved = try await gateway.saveDraft(saveRequest)
            try Task.checkCancellation()
            guard revision == boundRevision, generation == boundGeneration,
                  saved.generation == boundGeneration, saved.state == .readyForSubmission
            else { activity = .stale; return }
            apply(saved)
            let request = try CreatorSubmitRequest(
                submissionID: submissionID,
                expectedRevision: saved.revision,
                expectedGeneration: boundGeneration,
                acceptedCreatorTermsVersion: acceptsCurrentTerms ? currentTermsVersion : "",
                currentCreatorTermsVersion: currentTermsVersion,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            let result = try await gateway.submit(request)
            guard revision == saved.revision, generation == boundGeneration else { return }
            apply(result)
            activity = .submitted
        } catch {
            present(error)
        }
    }

    private func refreshProcessingWhileActive() async {
        while !Task.isCancelled, generation > 0,
              state == .processing || state == .uploaded {
            do {
                let boundRevision = revision
                let boundGeneration = generation
                if activity != .working {
                    let status = try await gateway.processingStatus(submissionID: submissionID, generation: boundGeneration)
                    try Task.checkCancellation()
                    if activity != .working, revision == boundRevision, generation == boundGeneration,
                       status.revision >= revision {
                        processingStatus = status
                        revision = status.revision
                        state = status.state
                    }
                }
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError {
                return
            } catch {
                // Keep the editable draft. A transient status failure must not
                // replace unsaved fields or mark a completed upload as failed.
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
    }

    private func failureMessage(for code: String) -> String {
        switch code {
        case "invalid_request": "Check the title, category, license, and rights declaration, then try again."
        case "rights_incomplete": "Complete the rights holder, license, required source and attribution, and rights confirmation."
        case "invalid_remote_response": "WALI couldn’t read the service response. Reopen the submission before trying again."
        case "creator_terms_stale": "The Creator Terms have changed. Return to Creator Studio and review the current terms."
        case "creator_access_expired", "creator_terms_required": "Creator access needs to be refreshed. Return to Creator Studio and review your account."
        case "rate_limited": "Too many requests. Wait a few minutes and try again."
        default: "The submission couldn’t be updated. Your edits are still here. Try again."
        }
    }

    private func apply(_ suggestion: CreatorModelSuggestion) {
        switch suggestion.kind {
        case .title: title = String(suggestion.value.prefix(120))
        case .description: description = String(suggestion.value.prefix(2_000))
        case .category, .tag: break
        }
    }

    private func apply(_ result: CreatorMutationResult) {
        revision = result.revision
        generation = result.generation
        state = result.state
        didChange(result)
    }

    private func present(_ error: Error) {
        switch CreatorRemoteFailureDisposition(error: error) {
        case .stale: activity = .stale
        case .accessRevoked: activity = .failed("creator_access_expired")
        case .retryable: activity = .failed("temporarily_unavailable")
        case .terminal:
            if let contractError = error as? CreatorContractError {
                activity = .failed(contractError.rawValue)
            } else {
                activity = .failed((error as? CatalogRemoteError)?.code ?? "temporarily_unavailable")
            }
        }
    }
}

private enum EditorActivity: Equatable {
    case idle
    case working
    case saved
    case submitted
    case stale
    case failed(String)
}

public struct ProcessingStatusView: View {
    private let status: CreatorProcessingStatus
    private let state: CreatorSubmissionState

    public init(status: CreatorProcessingStatus, state: CreatorSubmissionState? = nil) {
        self.status = status
        self.state = state ?? status.state
    }

    public var body: some View {
        GroupBox("Video processing") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(state.displayName, systemImage: state.symbolName)
                }
                if state == .processing || state == .uploaded {
                    ProgressView("Preparing your wallpaper…")
                        .controlSize(.small)
                }
                if let facts = status.mediaFacts {
                    LabeledContent("Detected media", value: "\(facts.width) × \(facts.height) · \(facts.codec)")
                    LabeledContent("Frame rate", value: facts.frameRate.formatted(.number.precision(.fractionLength(0...2))))
                    LabeledContent("Duration", value: Duration.milliseconds(facts.durationMilliseconds).formatted(.time(pattern: .minuteSecond)))
                }
                if status.duplicateWarning {
                    Label("Possible duplicate content detected", systemImage: "rectangle.on.rectangle")
                }
                ForEach(status.findings) { finding in
                    Label(finding.message, systemImage: finding.severity.processingSymbolName)
                }
                if status.safeErrorCode != nil {
                    Label("This video couldn’t be prepared. Try uploading another video.", systemImage: "exclamationmark.triangle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

public struct RightsDeclarationView: View {
    @Binding private var basis: CreatorRightsBasis
    @Binding private var rightsHolder: String
    @Binding private var selectedLicenseID: UUID?
    @Binding private var sourceURL: String
    @Binding private var attributionText: String
    @Binding private var proofObjectIDs: [UUID]
    @Binding private var attestsRights: Bool
    @Binding private var acceptsCurrentTerms: Bool
    private let licenses: [CreatorLicenseOption]
    private let currentTermsVersion: String

    public init(
        basis: Binding<CreatorRightsBasis>,
        rightsHolder: Binding<String>,
        selectedLicenseID: Binding<UUID?>,
        sourceURL: Binding<String>,
        attributionText: Binding<String>,
        proofObjectIDs: Binding<[UUID]>,
        attestsRights: Binding<Bool>,
        acceptsCurrentTerms: Binding<Bool>,
        licenses: [CreatorLicenseOption],
        currentTermsVersion: String
    ) {
        _basis = basis
        _rightsHolder = rightsHolder
        _selectedLicenseID = selectedLicenseID
        _sourceURL = sourceURL
        _attributionText = attributionText
        _proofObjectIDs = proofObjectIDs
        _attestsRights = attestsRights
        _acceptsCurrentTerms = acceptsCurrentTerms
        self.licenses = licenses
        self.currentTermsVersion = currentTermsVersion
    }

    public var body: some View {
        Section("Rights and attribution") {
            Picker("Rights basis", selection: $basis) {
                Text("Original work").tag(CreatorRightsBasis.original)
                Text("Public domain").tag(CreatorRightsBasis.publicDomain)
            }
            Text("Currently accepting original and public-domain works.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Rights holder", text: $rightsHolder)
                .accessibilityLabel("Rights holder")
            Picker("License", selection: $selectedLicenseID) {
                Text("Choose a license").tag(UUID?.none)
                ForEach(licenses) { license in
                    Text(license.name).tag(Optional(license.id))
                        .disabled(license.requirements.requiresProof)
                }
            }

            if requirements.requiresSourceURL {
                TextField("HTTPS source URL", text: $sourceURL)
                    .accessibilityLabel("HTTPS source URL")
                    .textContentType(.URL)
            }
            if requirements.requiresAttribution {
                TextField("Required attribution", text: $attributionText, axis: .vertical)
                    .accessibilityLabel("Required attribution")
                    .lineLimit(2...5)
            }
            if requirements.requiresProof {
                Label("This rights option isn’t available for submission yet.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Toggle("I attest that I have the right to publish this wallpaper", isOn: $attestsRights)
                .toggleStyle(.checkbox)
            Toggle("I accept Creator Terms \(currentTermsVersion)", isOn: $acceptsCurrentTerms)
                .toggleStyle(.checkbox)
        }
    }

    private var requirements: CreatorRightsRequirements {
        rightsRequirements(basis: basis, license: licenses.first(where: { $0.id == selectedLicenseID }))
    }
}

private func rightsRequirements(basis: CreatorRightsBasis, license: CreatorLicenseOption?) -> CreatorRightsRequirements {
    CreatorRightsRequirements(
        requiresSourceURL: basis != .original || license?.requirements.requiresSourceURL == true,
        requiresAttribution: basis != .original || license?.requirements.requiresAttribution == true,
        requiresProof: basis == .licensed || basis == .other || license?.requirements.requiresProof == true
    )
}

private extension CreatorFindingSeverity {
    var processingSymbolName: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }
}
