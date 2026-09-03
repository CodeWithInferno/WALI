import SwiftUI
import UniformTypeIdentifiers
import WALICatalogRuntime

public struct CreatorStudioView: View {
    @Bindable private var model: CreatorStudioModel
    @Bindable private var upload: CreatorUploadCoordinator
    private let categories: [CreatorTaxonomyOption]
    private let tags: [CreatorTaxonomyOption]
    private let licenses: [CreatorLicenseOption]
    private let accessState: MarketplaceCreatorAccessState
    private let lastFailureCode: String?
    private let onAcceptTerms: () -> Void
    private let editor: (CreatorSubmission) -> AnyView

    @State private var isImporting = false
    @State private var isReviewingTerms = false

    public init(
        model: CreatorStudioModel,
        upload: CreatorUploadCoordinator,
        categories: [CreatorTaxonomyOption],
        tags: [CreatorTaxonomyOption],
        licenses: [CreatorLicenseOption],
        accessState: MarketplaceCreatorAccessState,
        lastFailureCode: String? = nil,
        onAcceptTerms: @escaping () -> Void,
        @ViewBuilder editor: @escaping (CreatorSubmission) -> some View
    ) {
        self.model = model
        self.upload = upload
        self.categories = categories
        self.tags = tags
        self.licenses = licenses
        self.accessState = accessState
        self.lastFailureCode = lastFailureCode
        self.onAcceptTerms = onAcceptTerms
        self.editor = { AnyView(editor($0)) }
    }

    public var body: some View {
        Group {
            if !model.canUseCreatorStudio {
                creatorAccess
            } else {
                content
            }
        }
        .navigationTitle("Creator Studio")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            beginUpload(url)
        }
        .sheet(isPresented: $isReviewingTerms) {
            if let document = supportedTermsDocument {
                CreatorTermsReviewView(
                    document: document,
                    accessState: accessState,
                    lastFailureCode: lastFailureCode,
                    onAccept: onAcceptTerms,
                    onCancel: { isReviewingTerms = false }
                )
            }
        }
        .onChange(of: accessState) { _, newState in
            if newState == .ready, model.canUseCreatorStudio {
                isReviewingTerms = false
            }
        }
        .task(id: model.canUseCreatorStudio) {
            await model.loadSubmissions()
        }
    }

    private var creatorAccess: some View {
        ContentUnavailableView {
            Label("Creator access required", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            if accessState == .failed {
                Text("Creator access could not be loaded. Refresh your account and try again.")
            } else if canReviewTerms {
                Text("Review and accept the current Creator Terms to enable publishing for this account.")
            } else if canAcceptTerms {
                Text("This version of WALI cannot display the current Creator Terms. Update WALI before enabling Creator Studio.")
            } else {
                Text("This account does not currently have an active creator grant.")
            }
        } actions: {
            if canReviewTerms {
                Button("Review Creator Terms") {
                    isReviewingTerms = true
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(accessState == .acceptingTerms)
            }
            if accessState == .loading || accessState == .acceptingTerms {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var canAcceptTerms: Bool {
        let authorization = model.authorization
        return authorization.accountIsActive
            && !authorization.currentCreatorTermsVersion.isEmpty
            && authorization.acceptedCreatorTermsVersion != authorization.currentCreatorTermsVersion
    }

    private var canReviewTerms: Bool {
        canAcceptTerms && supportedTermsDocument != nil
    }

    private var supportedTermsDocument: CreatorTermsDocument? {
        CreatorTermsDocument.supported(version: model.authorization.currentCreatorTermsVersion)
    }

    private var content: some View {
        VStack(spacing: 0) {
            uploadBanner
            switch model.loadState {
            case .loading:
                ProgressView("Loading your submissions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty, .idle:
                ContentUnavailableView {
                    Label("Upload your first wallpaper", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text("WALI verifies media and creates canonical variants before review.")
                } actions: {
                    uploadWallpaperButton
                        .controlSize(.large)
                }
            case .offline:
                ContentUnavailableView(
                    "Creator Studio is offline",
                    systemImage: "wifi.slash",
                    description: Text("Your source file is unchanged. Try again when the service is available.")
                )
            case .failed:
                ContentUnavailableView(
                    "Couldn’t load submissions",
                    systemImage: "exclamationmark.triangle",
                    description: Text("No private server details were shown. Try again.")
                )
            case .restricted:
                EmptyView()
            case .ready:
                submissionList
            }
        }
    }

    private var submissionList: some View {
        List(model.submissions) { submission in
            NavigationLink {
                editor(submission)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: submission.state.symbolName)
                        .font(.title3)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(submission.draft?.title ?? "Untitled wallpaper")
                            .font(.headline)
                        Text(submission.state.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("r\(submission.revision) · g\(submission.generation)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Revision \(submission.revision), generation \(submission.generation)")
                }
                .padding(.vertical, 4)
            }
            .contextMenu {
                if submission.state.canWithdraw {
                    Button("Withdraw", systemImage: "xmark.circle", role: .destructive) {
                        Task { await model.withdraw(submission) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                uploadWallpaperButton
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var uploadWallpaperButton: some View {
        Button("Upload Wallpaper", systemImage: "square.and.arrow.up") {
            isImporting = true
        }
        .disabled(!model.canUseCreatorStudio)
    }

    @ViewBuilder
    private var uploadBanner: some View {
        switch upload.state {
        case let .uploading(progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Uploading", systemImage: "arrow.up.circle.fill")
                    Spacer()
                    Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                ProgressView(value: progress.fractionCompleted)
                HStack {
                    Button("Pause", systemImage: "pause.fill") { upload.pause() }
                    Button("Cancel", systemImage: "xmark", role: .destructive) { upload.cancel() }
                }
            }
            .padding()
            .background(.regularMaterial)
        case .requestingGrant:
            ProgressView("Preparing a private upload…")
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
        case let .paused(progress):
            HStack {
                Label(
                    progress.map { "Paused at \($0.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))" }
                        ?? "Upload paused",
                    systemImage: "pause.circle"
                )
                Spacer()
                Button("Resume", systemImage: "play.fill") { upload.resume() }
                Button("Cancel", role: .destructive) { upload.cancel() }
            }
            .padding()
            .background(.regularMaterial)
        case .completing:
            ProgressView("Verifying the completed upload…")
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
        case let .processing(result):
            Label(
                "Upload verified. Processing generation \(result.generation).",
                systemImage: "checkmark.circle.fill"
            )
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        case let .failed(code):
            Label("Upload stopped (\(code)). Your source file was not changed.", systemImage: "exclamationmark.triangle")
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
        case .restricted:
            Label("Creator access expired. Sign in again before resuming.", systemImage: "lock")
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
        case .idle, .cancelled:
            EmptyView()
        }
    }

    private func beginUpload(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else { return }
        let hint = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        upload.start(
            fileURL: url,
            declaredByteCount: UInt64(fileSize),
            containerHint: hint
        )
    }
}

private extension CreatorSubmissionState {
    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .processing: "Processing"
        case .processingFailed: "Processing failed"
        case .readyForSubmission: "Ready to submit"
        case .submitted: "Submitted"
        case .underReview: "Under review"
        case .changesRequested: "Changes requested"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .published: "Published"
        case .withdrawn: "Withdrawn"
        }
    }

    var symbolName: String {
        switch self {
        case .draft, .readyForSubmission: "pencil.circle"
        case .uploading, .uploaded, .processing: "gearshape.2"
        case .processingFailed, .rejected: "exclamationmark.triangle"
        case .submitted, .underReview: "clock"
        case .changesRequested: "arrow.uturn.backward.circle"
        case .approved, .published: "checkmark.seal"
        case .withdrawn: "xmark.circle"
        }
    }

    var canWithdraw: Bool {
        switch self {
        case .published, .withdrawn, .rejected:
            false
        default:
            true
        }
    }
}
