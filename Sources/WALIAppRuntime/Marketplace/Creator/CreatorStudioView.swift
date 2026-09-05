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
    @State private var uploadProblem: String?
    @Environment(\.scenePhase) private var scenePhase

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
        .navigationDestination(for: CreatorSubmission.self) { submission in
            editor(submission)
                .navigationBarBackButtonHidden()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { beginUpload(url) }
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    uploadProblem = "This video couldn’t be opened. Choose a readable MP4 or QuickTime file and try again."
                }
            }
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
        .task(id: model.authorization) {
            await model.loadSubmissions()
        }
        .task(id: completedUploadID) {
            guard completedUploadID != nil else { return }
            await model.loadSubmissions()
        }
        .task(id: scenePhase == .active && model.hasProcessingSubmissions && model.canUseCreatorStudio) {
            guard scenePhase == .active, model.canUseCreatorStudio else { return }
            while !Task.isCancelled, model.hasProcessingSubmissions {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                await model.refreshProcessingSubmissions()
            }
        }
        .alert("Couldn’t Open Video", isPresented: Binding(
            get: { uploadProblem != nil }, set: { if !$0 { uploadProblem = nil } }
        )) {
            Button("OK", role: .cancel) { uploadProblem = nil }
        } message: {
            Text(uploadProblem ?? "Choose another video and try again.")
        }
    }

    private var creatorAccess: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Creator Studio") {}
            creatorAccessMessage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var creatorAccessMessage: some View {
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
            WALIPageHeader("Creator Studio") {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.loadSubmissions() }
                }
                .labelStyle(.iconOnly)
                .help("Refresh submissions")
                .disabled(model.loadState == .loading)
                uploadWallpaperButton
            }
            uploadBanner
            switch model.loadState {
            case .loading:
                ProgressView("Loading your submissions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty, .idle:
                ContentUnavailableView {
                    Label("Upload your first wallpaper", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text("Upload a video, add its details, and submit it for review.")
                } actions: {
                    uploadWallpaperButton
                        .controlSize(.large)
                }
            case .offline:
                ContentUnavailableView {
                    Label("Creator Studio is offline", systemImage: "wifi.slash")
                } description: {
                    Text("Your source file is unchanged. Try again when the service is available.")
                } actions: {
                    Button("Try Again") { Task { await model.loadSubmissions() } }
                }
            case .failed:
                ContentUnavailableView {
                    Label("Couldn’t load submissions", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your submissions couldn’t be loaded. Try again in a moment.")
                } actions: {
                    Button("Try Again") { Task { await model.loadSubmissions() } }
                }
            case .restricted:
                EmptyView()
            case .ready:
                submissionList
            }
            if let message = model.pageError {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(12)
            }
            if model.nextCursor != nil {
                Button(model.isLoadingMore ? "Loading…" : "Load More Submissions") {
                    Task { await model.loadNextPage() }
                }
                .disabled(model.isLoadingMore)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var submissionList: some View {
        List(model.submissions) { submission in
            NavigationLink(value: submission) {
                HStack(spacing: 12) {
                    Image(systemName: submission.wallpaperStatus?.creatorRestrictionLabel == nil
                        ? submission.state.symbolName : "eye.slash")
                        .font(.title3)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(submission.draft?.title ?? "Untitled wallpaper")
                            .font(.headline)
                        Text(submission.wallpaperStatus?.creatorRestrictionLabel ?? submission.state.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(submission.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
            }
            .contextMenu {
                if submission.state == .processingFailed {
                    Button("Upload Another Video", systemImage: "square.and.arrow.up") {
                        isImporting = true
                    }
                    .disabled(uploadIsActive)
                }
                if submission.state.canWithdraw {
                    Button("Withdraw", systemImage: "xmark.circle", role: .destructive) {
                        Task { await model.withdraw(submission) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var uploadWallpaperButton: some View {
        Button("Upload Wallpaper", systemImage: "square.and.arrow.up") {
            isImporting = true
        }
        .disabled(!model.canUseCreatorStudio || uploadIsActive)
    }

    private var uploadIsActive: Bool {
        switch upload.state {
        case .requestingGrant, .uploading, .paused, .completing: true
        default: false
        }
    }

    private var completedUploadID: UUID? {
        if case let .processing(result) = upload.state { return result.submissionID }
        return nil
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
            let submissionState = model.submissions.first(where: { $0.id == result.submissionID })?.state
            HStack {
                if submissionState == .processingFailed {
                    Label("This video couldn’t be prepared.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Upload Another Video") { isImporting = true }
                } else {
                    Label(
                        submissionState == .readyForSubmission
                            ? "Your wallpaper is ready. Open the submission to add its details."
                            : "Upload complete. Open the submission for its latest status.",
                        systemImage: "checkmark.circle.fill"
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        case .failed:
            Label("Upload couldn’t be completed. Your source file is unchanged. Choose the video again to retry.", systemImage: "exclamationmark.triangle")
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
        else {
            uploadProblem = "This video is empty or can’t be read. Choose another MP4 or QuickTime file."
            return
        }
        let hint = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        upload.start(
            fileURL: url,
            declaredByteCount: UInt64(fileSize),
            containerHint: hint
        )
    }
}

extension CreatorSubmissionState {
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
        case .approved, .published, .withdrawn, .rejected:
            false
        default:
            true
        }
    }
}

extension ModerationWallpaperStatus {
    var creatorRestrictionLabel: String? {
        switch self {
        case .hidden: "Hidden from Marketplace"
        case .suspended: "Suspended from Marketplace"
        case .removed: "Removed from Marketplace"
        case .draft, .published: nil
        }
    }
}
