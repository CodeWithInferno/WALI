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
    private let initialProcessingStatus: CreatorProcessingStatus?
    private let requestProofUpload: () -> Void
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

    public init(
        submission: CreatorSubmission,
        gateway: any CreatorStudioGateway,
        categories: [CreatorTaxonomyOption],
        tags: [CreatorTaxonomyOption],
        licenses: [CreatorLicenseOption],
        currentTermsVersion: String,
        requestProofUpload: @escaping () -> Void,
        didChange: @escaping (CreatorMutationResult) -> Void
    ) {
        submissionID = submission.id
        self.gateway = gateway
        self.categories = categories
        self.tags = tags
        self.licenses = licenses
        self.currentTermsVersion = currentTermsVersion
        initialProcessingStatus = submission.processing
        self.requestProofUpload = requestProofUpload
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
        Form {
            Section("Your wallpaper details") {
                TextField("Title", text: $title)
                    .accessibilityHint("Creator-provided title, maximum 120 characters")
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                Picker("Primary category", selection: $categoryID) {
                    Text("Choose a category").tag(UUID?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                Menu("Suggested tags (\(selectedTagIDs.count)/20)") {
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
                    .lineLimit(1...4)
            }

            if let processing = processingStatus {
                Section {
                    ProcessingStatusView(status: processing)
                }
            }

            modelSuggestions

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
                currentTermsVersion: currentTermsVersion,
                requestProofUpload: requestProofUpload
            )

            Section {
                HStack {
                    Text("Revision \(revision) · Generation \(generation)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if activity == .working { ProgressView().controlSize(.small) }
                    Button("Save Draft") { Task { await save() } }
                        .disabled(activity == .working)
                    Button("Submit for Review") { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit || activity == .working)
                }
                if case let .failed(code) = activity {
                    Label("Couldn’t save: \(code)", systemImage: "exclamationmark.triangle")
                } else if activity == .stale {
                    Label("This submission changed on the server. Reload before editing.", systemImage: "arrow.clockwise.circle")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title.isEmpty ? "Wallpaper Submission" : title)
    }

    @ViewBuilder
    private var modelSuggestions: some View {
        let suggestions = processingStatus?.suggestions ?? []
        Section {
            if suggestions.isEmpty {
                Text("Suggestions appear after WALI verifies the uploaded media.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "sparkles")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.value)
                            Text("WALI suggestion · \(suggestion.modelID) \(suggestion.modelRevision) · \(suggestion.confidence.formatted(.percent))")
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
            Label("System suggestions — optional", systemImage: "wand.and.stars")
        } footer: {
            Text("Suggestions are model output, not your saved details. Nothing is applied automatically.")
        }
    }

    private var processingStatus: CreatorProcessingStatus? {
        // A parent recreates this editor after polling a newer immutable server projection.
        initialProcessingStatus
    }

    private var requirements: CreatorRightsRequirements {
        licenses.first(where: { $0.id == licenseID })?.requirements
            ?? .init(
                requiresSourceURL: rightsBasis != .original,
                requiresAttribution: rightsBasis != .original,
                requiresProof: rightsBasis == .licensed || rightsBasis == .other
            )
    }

    private var canSubmit: Bool {
        acceptsCurrentTerms && attestsRights && generation > 0
            && state == .readyForSubmission
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
        let boundRevision = revision
        let boundGeneration = generation
        activity = .working
        do {
            _ = try makeDraft()
            let request = try CreatorSubmitRequest(
                submissionID: submissionID,
                expectedRevision: boundRevision,
                expectedGeneration: boundGeneration,
                acceptedCreatorTermsVersion: acceptsCurrentTerms ? currentTermsVersion : "",
                currentCreatorTermsVersion: currentTermsVersion,
                idempotencyKey: UUID().uuidString.lowercased()
            )
            let result = try await gateway.submit(request)
            guard revision == boundRevision, generation == boundGeneration else { return }
            apply(result)
            activity = .submitted
        } catch {
            present(error)
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
            activity = .failed((error as? CatalogRemoteError)?.code ?? "invalid_request")
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

    public init(status: CreatorProcessingStatus) {
        self.status = status
    }

    public var body: some View {
        GroupBox("Server verification") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(status.state.processingLabel, systemImage: "gearshape.2")
                    Spacer()
                    Text("Generation \(status.generation) · Revision \(status.revision)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let progress = status.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Server processing progress")
                        .accessibilityValue(progress.formatted(.percent))
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
                if let code = status.safeErrorCode {
                    Label("Processing stopped: \(code)", systemImage: "exclamationmark.triangle")
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
    private let requestProofUpload: () -> Void

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
        currentTermsVersion: String,
        requestProofUpload: @escaping () -> Void
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
        self.requestProofUpload = requestProofUpload
    }

    public var body: some View {
        Section("Rights and attribution") {
            Picker("Rights basis", selection: $basis) {
                Text("Original work").tag(CreatorRightsBasis.original)
                Text("Public domain").tag(CreatorRightsBasis.publicDomain)
            }
            Text("Licensed and other third-party works are unavailable until private proof scanning is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Rights holder", text: $rightsHolder)
            Picker("License", selection: $selectedLicenseID) {
                Text("Choose a license").tag(UUID?.none)
                ForEach(licenses) { license in
                    Text("\(license.name) (\(license.code))").tag(Optional(license.id))
                }
            }

            if requirements.requiresSourceURL {
                TextField("HTTPS source URL", text: $sourceURL)
                    .textContentType(.URL)
            }
            if requirements.requiresAttribution {
                TextField("Required attribution", text: $attributionText, axis: .vertical)
                    .lineLimit(2...5)
            }
            if requirements.requiresProof {
                HStack {
                    Label(
                        proofObjectIDs.isEmpty ? "Rights proof required" : "\(proofObjectIDs.count) proof file(s) attached",
                        systemImage: proofObjectIDs.isEmpty ? "doc.badge.plus" : "checkmark.shield"
                    )
                    Spacer()
                    Button("Add Proof…", action: requestProofUpload)
                }
                Text("PNG, JPEG, or PDF only. Proof remains private and is scanned before review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("I attest that I have the right to publish this wallpaper", isOn: $attestsRights)
            Toggle("I accept Creator Terms \(currentTermsVersion)", isOn: $acceptsCurrentTerms)
        }
    }

    private var requirements: CreatorRightsRequirements {
        licenses.first(where: { $0.id == selectedLicenseID })?.requirements
            ?? CreatorRightsRequirements(
                requiresSourceURL: basis != .original,
                requiresAttribution: basis != .original,
                requiresProof: false
            )
    }
}

private extension CreatorSubmissionState {
    var processingLabel: String {
        rawValue.replacingOccurrences(of: "_", with: " ").localizedCapitalized
    }
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
