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
    private let onPublished: () -> Void
    private let editor: (CreatorSubmission) -> AnyView

    @State private var isImporting = false
    @State private var isPreparingUpload = false
    @State private var isReviewingTerms = false
    @State private var uploadProblem: String?
    @State private var pendingSource: PendingSource?
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
        onPublished: (() -> Void)? = nil,
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
        self.onPublished = onPublished ?? {}
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
            allowedContentTypes: supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { beginUpload(url) }
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    uploadProblem = "This file couldn’t be opened. Choose a readable \(supportedFormatNames) file and try again."
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
        .sheet(item: $pendingSource) { source in
            CreatorNewUploadForm(
                fileName: source.url.lastPathComponent, categories: categories, tags: tags, licenses: licenses,
                currentTermsVersion: model.authorization.currentCreatorTermsVersion,
                onUpload: { draft in
                    guard model.canUseCreatorStudio, source.subjectID == model.authorization.subjectID else {
                        pendingSource = nil
                        return
                    }
                    upload.start(fileURL: source.url, declaredByteCount: source.byteCount,
                                 containerHint: source.containerHint, draft: draft,
                                 creatorTermsVersion: model.authorization.currentCreatorTermsVersion)
                    pendingSource = nil
                },
                onCancel: { pendingSource = nil }
            )
        }
        .onChange(of: model.authorization.subjectID) { _, _ in
            pendingSource = nil
            isImporting = false
            isReviewingTerms = false
        }
        .onChange(of: model.submissions.filter { $0.state == .published }.map(\.id)) { old, new in
            if !Set(new).subtracting(old).isEmpty { onPublished() }
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
        .alert("Couldn’t Prepare Upload", isPresented: Binding(
            get: { uploadProblem != nil }, set: { if !$0 { uploadProblem = nil } }
        )) {
            Button("OK", role: .cancel) { uploadProblem = nil }
        } message: {
            Text(uploadProblem ?? "Choose another wallpaper file and try again.")
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
                    Text("Choose a \(supportedFormatNames) file, add its details and credits, and publish it after automatic verification.")
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
                        Text(submission.wallpaperStatus?.creatorRestrictionLabel
                             ?? (submission.state == .approved && submission.processing?.safeErrorCode != nil
                                 ? "Publishing needs another attempt" : submission.state.displayName))
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
                if submission.state == .approved, submission.processing?.safeErrorCode != nil {
                    Button("Retry Publishing", systemImage: "arrow.clockwise") {
                        Task { await model.retryPublication(submission) }
                    }
                }
                if submission.state == .processingFailed {
                    Button("Upload Another Wallpaper", systemImage: "square.and.arrow.up") {
                        requestImport()
                    }
                    .disabled(uploadIsActive || isPreparingUpload)
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
        Button(isPreparingUpload ? "Checking Upload Formats…" : "Upload Wallpaper", systemImage: "square.and.arrow.up") {
            requestImport()
        }
        .disabled(!model.canUseCreatorStudio || uploadIsActive || isPreparingUpload)
        .help("Supported uploads: \(supportedFormatNames)")
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
            let submission = model.submissions.first(where: { $0.id == result.submissionID })
            let submissionState = submission?.state
            HStack {
                if submissionState == .processingFailed {
                    Label("This wallpaper couldn’t be prepared.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    if let submission {
                        Button("Retry Processing") { Task { await model.retryProcessing(submission) } }
                    }
                } else if let submission, submissionState == .approved, submission.processing?.safeErrorCode != nil {
                    Label("Publishing needs another attempt.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry Publishing") { Task { await model.retryPublication(submission) } }
                } else {
                    Label(
                        submissionState == .published
                            ? "Published. Your wallpaper is available in the catalog."
                            : "Upload complete. Processing and publication continue even if you close WALI.",
                        systemImage: submissionState == .published ? "checkmark.circle.fill" : "gearshape.2"
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        case let .failed(code):
            HStack {
                Label([CreatorContractError.unsupportedUploadFormat.rawValue, "still_intake_disabled"].contains(code)
                      ? "This format is not available for publishing. Choose a \(supportedFormatNames) file and try again."
                      : upload.canRetry
                      ? "Upload couldn’t be completed. Your source file and entered details are preserved."
                      : (code == CreatorUploadError.sessionExpired.rawValue
                         ? "This upload expired. Choose the source again to start a new upload."
                         : "This upload can’t continue. Check the source and details, then start another upload."),
                      systemImage: "exclamationmark.triangle")
                Spacer()
                if upload.canRetry { Button("Retry Upload") { upload.retry() } }
                else { Button("Choose Wallpaper") { requestImport() } }
                Button("Cancel", role: .destructive) { upload.cancel() }
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
        case .restricted:
            Label("Creator access expired. Sign in again before resuming.", systemImage: "lock")
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
        case .idle, .cancelled:
            EmptyView()
        }
    }

    private var supportedContentTypes: [UTType] {
        CreatorUploadMediaType.allCases.filter { upload.supportedMediaTypes.contains($0) }.map {
            switch $0 {
            case .mp4: .mpeg4Movie
            case .quickTime: .quickTimeMovie
            case .jpeg: .jpeg
            case .png: .png
            }
        }
    }

    private var supportedFormatNames: String {
        let names = CreatorUploadMediaType.allCases.filter { upload.supportedMediaTypes.contains($0) }.map {
            switch $0 {
            case .mp4: "MP4"
            case .quickTime: "QuickTime"
            case .jpeg: "JPEG"
            case .png: "PNG"
            }
        }
        return names.isEmpty ? "supported wallpaper" : names.joined(separator: ", ")
    }

    private func requestImport() {
        guard model.canUseCreatorStudio, !uploadIsActive, !isPreparingUpload else { return }
        let subject = model.authorization.subjectID
        let terms = model.authorization.currentCreatorTermsVersion
        isPreparingUpload = true
        Task { @MainActor in
            defer { isPreparingUpload = false }
            do {
                let formats = try await upload.refreshSupportedMediaTypes()
                guard model.canUseCreatorStudio, model.authorization.subjectID == subject,
                      model.authorization.currentCreatorTermsVersion == terms else { return }
                guard !formats.isEmpty else {
                    uploadProblem = "Uploads are temporarily unavailable. Try again later."
                    return
                }
                isImporting = true
            } catch is CancellationError {
                return
            } catch {
                guard model.authorization.subjectID == subject else { return }
                uploadProblem = "Supported upload formats couldn’t be checked. Try again when the service is available."
            }
        }
    }

    private func beginUpload(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let hint: String
        switch url.pathExtension.lowercased() {
        case "png": hint = "image/png"
        case "jpg", "jpeg": hint = "image/jpeg"
        case "mov": hint = "video/quicktime"
        case "mp4", "m4v": hint = "video/mp4"
        default:
            uploadProblem = "Choose a \(supportedFormatNames) file."
            return
        }
        guard let format = CreatorUploadMediaType(rawValue: hint), upload.supportedMediaTypes.contains(format) else {
            uploadProblem = "This format is not available for publishing. Choose a \(supportedFormatNames) file."
            return
        }
        let limit = hint.hasPrefix("image/") ? 134_217_728 : 1_073_741_824
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let fileSize = values.fileSize, (1...limit).contains(fileSize)
        else {
            uploadProblem = hint.hasPrefix("image/")
                ? "Choose a readable JPEG or PNG no larger than 128 MB."
                : "Choose a readable MP4 or QuickTime file no larger than 1 GB."
            return
        }
        pendingSource = PendingSource(url: url, byteCount: UInt64(fileSize), containerHint: hint,
                                      subjectID: model.authorization.subjectID)
    }

    private struct PendingSource: Identifiable {
        let id = UUID()
        let url: URL
        let byteCount: UInt64
        let containerHint: String
        let subjectID: String
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
        case .readyForSubmission: "Preparing publication"
        case .submitted: "Submitted"
        case .underReview: "Under review"
        case .changesRequested: "Changes requested"
        case .approved: "Publishing"
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
