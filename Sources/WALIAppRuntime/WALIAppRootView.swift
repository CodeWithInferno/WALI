import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WALICatalogRuntime
import WALIModel
import WALIUI
import WALIWire

/// The foreground library window. Runtime adapters can inject a live model and
/// intention handler while the parameterless initializer keeps previews safe.
public struct WALIAppRootView: View {
    @State private var model: WALIAppModel
    @State private var marketplace: MarketplaceCoordinator
    private let actions: any WALIUIActionHandling

    @State private var route: AppRoute = .library
    @State private var catalogPath: [String] = []
    @State private var selectedWallpaperID: UUID?
    @State private var selectedDisplayIDs: Set<String> = []
    @State private var hasInitializedDisplaySelection = false
    @State private var knownConnectedDisplayIDs: Set<String> = []
    @State private var selectedContentFit: WALIContentFitPreference = .fill
    @State private var searchText = ""
    @State private var browseSort: CatalogBrowseSort = .featured
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsImporter = false
    @State private var showsSettings = false
    @State private var showsPreview = false
    @State private var pendingDeletionID: UUID?
    @State private var recentlyDeletedID: UUID?
    @State private var localError: String?
    @State private var showsStatus = false
    @State private var showsDisplayArrangement = false

    public init(
        model: WALIAppModel = WALIAppModel(),
        actions: any WALIUIActionHandling = NoopWALIUIActionHandler(),
        marketplace: MarketplaceCoordinator = MarketplaceCoordinator()
    ) {
        _model = State(initialValue: model)
        _marketplace = State(initialValue: marketplace)
        self.actions = actions
    }

    public var body: some View {
        navigation
        .navigationTitle(catalogPath.isEmpty ? route.title : "")
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true,
            onCompletion: handleImportResult
        )
        .sheet(isPresented: $showsSettings) {
            WALISettingsView(preferences: model.snapshot.preferences, storage: model.snapshot.storage) { preferences in
                actions.send(.updatePreferences(preferences))
            }
        }
        .sheet(isPresented: $showsPreview) {
            if let selectedWallpaper {
                WallpaperPreviewView(
                    wallpaper: selectedWallpaper,
                    displayIDs: effectiveDisplayIDs,
                    onApply: { apply(selectedWallpaper) }
                )
            }
        }
        .alert("Delete Wallpaper?", isPresented: deletionAlertBinding) {
            Button("Cancel", role: .cancel) { pendingDeletionID = nil }
            Button("Delete", role: .destructive, action: confirmDeletion)
        } message: {
            Text("The prepared WALI copy will be removed. Your original source video is never deleted.")
        }
        .overlay(alignment: .bottom) { noticeOverlay }
        .background {
            WALIAppSurface.catalogCanvas
                .ignoresSafeArea()
        }
        .frame(minWidth: 820, idealWidth: 1120, minHeight: 560, idealHeight: 720)
        .onAppear {
            synchronizeSelection()
            marketplace.start()
        }
        .onDisappear { marketplace.stop() }
        .onChange(of: connectedDisplayIDs) { _, _ in
            synchronizeDisplays()
            synchronizeContentFit()
        }
        .onChange(of: selectedDisplayIDs) { _, _ in synchronizeContentFit() }
        .onChange(of: searchText) { _, value in
            if route == .browse { marketplace.search(value) }
        }
        .onChange(of: model.snapshot.wallpapers) { _, _ in synchronizeWallpaperSelection() }
        .onChange(of: model.settingsPresentationRequest) { _, _ in showsSettings = true }
        .background(keyboardCommands)
        .accessibilityIdentifier("WALI.MainWindow")
    }

    @ViewBuilder
    private var navigation: some View {
        if route == .library {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 168, ideal: 190, max: 230)
            } content: {
                content
                    .navigationSplitViewColumnWidth(min: 350, ideal: 630)
                    .waliBackgroundExtension()
            } detail: {
                detail
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
            }
        } else if route.isMarketplace {
            marketplaceRootNavigation
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 168, ideal: 190, max: 230)
            } detail: {
                content
                    .waliBackgroundExtension()
            }
        }
    }

    private var marketplaceRootNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 168, ideal: 190, max: 230)
        } detail: {
            NavigationStack(path: $catalogPath) {
                content
                    .navigationDestination(for: String.self) { wallpaperID in
                        MarketplaceWallpaperDetailView(
                            marketplace: marketplace.model,
                            wallpaperID: wallpaperID,
                            onRetry: { marketplace.loadDetail(wallpaperID: wallpaperID) },
                            onOpenRelated: openCatalogWallpaper,
                            onInstall: { marketplace.installSelectedWallpaper() },
                            onFavorite: { marketplace.toggleFavorite() },
                            onSave: { marketplace.toggleSaved() },
                            onReport: marketplace.reportSelectedWallpaper
                        )
                        .task { marketplace.loadDetail(wallpaperID: wallpaperID) }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .waliBackgroundExtension()
        }
    }

    private var sidebar: some View {
        List(selection: $route) {
            Section("Marketplace") {
                sidebarRow(.discover)
                sidebarRow(.browse)
                if case .signedIn = marketplace.model.accountState {
                    sidebarRow(.creatorStudio)
                }
                if marketplace.creatorContext.canShowModeratorTools {
                    sidebarRow(.reviewQueue)
                    sidebarRow(.reports)
                }
            }
            Section("My WALI") {
                sidebarRow(.library)
                sidebarRow(.downloads, badge: activeTransferCount)
                sidebarRow(.account)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: route) { _, newRoute in
            if newRoute != .library { searchText = "" }
            catalogPath.removeAll()
        }
        .accessibilityIdentifier("WALI.Sidebar")
    }

    private func sidebarRow(_ item: AppRoute, badge: Int = 0) -> some View {
        HStack(spacing: 8) {
            Label(item.title, systemImage: item.symbolName)
            Spacer(minLength: 0)
            if badge > 0 {
                Text(badge, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(badge) active")
            }
        }
        .tag(item)
        .accessibilityIdentifier("WALI.Sidebar.\(item.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .discover:
            DiscoverView(
                marketplace: marketplace.model,
                onRetry: marketplace.loadHome,
                onOpen: openCatalogWallpaper
            )
        case .browse:
            BrowseView(
                marketplace: marketplace.model,
                sort: $browseSort,
                query: searchText,
                onLoad: { marketplace.loadBrowse(sort: $0) },
                onOpen: openCatalogWallpaper,
                onLoadMore: marketplace.loadNextBrowsePage
            )
        case .library:
            LibrarySurface(
                wallpapers: filteredWallpapers,
                selectedID: $selectedWallpaperID,
                previewedID: selectedWallpaperID,
                canApply: hasConnectedDisplaySelection,
                onImport: { showsImporter = true },
                onApply: apply,
                onPreview: preview,
                onDelete: requestDeletion,
                onReveal: { actions.send(.revealWallpaper(itemID: $0.id)) },
                onDrop: importVideos
            )
        case .downloads:
            DownloadsSurface(
                transfers: model.snapshot.transfers,
                onImport: { showsImporter = true },
                onDrop: importVideos,
                onCancel: { transferID in
                    actions.send(.cancelTransfer(id: transferID))
                }
            )
        case .account:
            AccountView(
                account: marketplace.model.accountState,
                profile: marketplace.model.accountProfile,
                profileState: marketplace.model.accountProfileState,
                exportState: marketplace.model.accountExportState,
                deletionState: marketplace.model.accountDeletionState,
                onSignIn: marketplace.signIn,
                onSignOut: marketplace.signOut,
                onRefresh: marketplace.refreshAccountPrivacy,
                onRequestExport: marketplace.requestAccountExport,
                onRefreshExport: marketplace.refreshAccountExport,
                onSaveExport: marketplace.chooseAccountExportDestination,
                onRequestDeletion: marketplace.requestAccountDeletion,
                onRefreshDeletion: marketplace.refreshAccountDeletion,
                onVerifyDeletionMFA: marketplace.verifyAccountDeletionMFA,
                onCancelDeletionMFA: marketplace.cancelAccountDeletionMFA
            )
        case .creatorStudio:
            if let studioModel = marketplace.creatorContext.studioModel,
               let upload = marketplace.creatorContext.uploadCoordinator,
               let metadata = marketplace.creatorContext.metadata,
               let gateway = marketplace.creatorGateway {
                CreatorStudioView(
                    model: studioModel,
                    upload: upload,
                    categories: metadata.categories,
                    tags: metadata.tags,
                    licenses: metadata.licenses,
                    accessState: marketplace.creatorContext.state,
                    onAcceptTerms: marketplace.acceptCreatorTerms
                ) { submission in
                    CreatorSubmissionEditor(
                        submission: submission,
                        gateway: gateway,
                        categories: metadata.categories,
                        tags: metadata.tags,
                        licenses: metadata.licenses,
                        currentTermsVersion: metadata.currentCreatorTermsVersion,
                        requestProofUpload: {},
                        didChange: { _ in
                            Task { await studioModel.loadSubmissions() }
                        }
                    )
                }
            } else {
                ContentUnavailableView(
                    "Creator Studio unavailable",
                    systemImage: "person.crop.rectangle.stack",
                    description: Text("Sign in and refresh your account to load creator access.")
                )
            }
        case .reviewQueue:
            if let moderationModel = marketplace.creatorContext.moderationModel,
               let moderationMetadata = marketplace.creatorContext.moderationMetadata,
               marketplace.creatorContext.canShowModeratorTools {
                ReviewQueueView(model: moderationModel) { item in
                    SubmissionReviewView(
                        item: item,
                        model: moderationModel,
                        moderationMetadata: moderationMetadata
                    )
                }
            } else {
                protectedModeratorUnavailable
            }
        case .reports:
            if let moderationModel = marketplace.creatorContext.moderationModel,
               marketplace.creatorContext.canShowModeratorTools {
                ReportQueueView(model: moderationModel)
            } else {
                protectedModeratorUnavailable
            }
        }
    }

    private var protectedModeratorUnavailable: some View {
        ContentUnavailableView(
            "Moderator access required",
            systemImage: "lock.shield",
            description: Text("A current server grant and fresh two-factor session are required.")
        )
    }

    @ViewBuilder
    private var detail: some View {
        if route == .library, let selectedWallpaper {
            WallpaperDetailView(
                wallpaper: selectedWallpaper,
                displays: model.snapshot.displays,
                selectedDisplayIDs: $selectedDisplayIDs,
                contentFit: $selectedContentFit,
                onApply: { apply(selectedWallpaper) },
                onPreview: { preview(selectedWallpaper) },
                onDelete: { requestDeletion(selectedWallpaper) },
                onReveal: { actions.send(.revealWallpaper(itemID: selectedWallpaper.id)) }
            )
        } else {
            ContentUnavailableView {
                Label(route.title, systemImage: route.symbolName)
            } description: {
                Text(route.detailHint)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if route == .browse {
            ToolbarItemGroup(placement: .primaryAction) {
                CatalogFiltersView(sort: $browseSort)
                WALICompactSearchField(text: $searchText, prompt: "Search Wallpapers")
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 340)
                    .accessibilityIdentifier("WALI.Marketplace.Search")
            }
        }

        if route.isLocalLibrary {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showsImporter = true
                } label: {
                    Label("Import Video", systemImage: "plus")
                }
                .help("Import Video… (⌘O)")
                .accessibilityIdentifier("WALI.Import")
            }

            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    showsDisplayArrangement.toggle()
                } label: {
                    Label(displayPickerTitle, systemImage: "display.2")
                }
                .help("Choose Displays")
                .popover(isPresented: $showsDisplayArrangement, arrowEdge: .bottom) {
                    DisplayArrangementView(
                        displays: model.snapshot.displays,
                        wallpapers: model.snapshot.wallpapers,
                        selection: $selectedDisplayIDs,
                        onDone: { showsDisplayArrangement = false }
                    )
                }
                .accessibilityIdentifier("WALI.DisplayPicker")

                Button {
                    showsStatus.toggle()
                } label: {
                    Label("WALI Status", systemImage: rendererToolbarSymbol)
                }
                .help("Wallpaper Status")
                .popover(isPresented: $showsStatus, arrowEdge: .bottom) {
                    StatusPanel(status: model.snapshot.renderer, actions: actions)
                }
            }

            if route == .library {
                ToolbarItem(placement: .primaryAction) {
                    WALICompactSearchField(text: $searchText, prompt: "Search Library")
                        .frame(minWidth: 180, idealWidth: 260, maxWidth: 340)
                        .accessibilityIdentifier("WALI.Library.Search")
                }
            }
        }
    }

    private var keyboardCommands: some View {
        Group {
            Button("Import Video") { showsImporter = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Apply Selection") {
                if let selectedWallpaper { apply(selectedWallpaper) }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(selectedWallpaper == nil || !hasConnectedDisplaySelection)
            Button("Pause or Resume") {
                actions.send(.setPaused(!model.snapshot.renderer.state.isPaused))
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Settings") { showsSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var noticeOverlay: some View {
        if let localError {
            NoticeBanner(kind: .error, title: "Import Failed", message: localError) {
                self.localError = nil
            }
            .padding(16)
        } else if let deletedID = recentlyDeletedID {
            NoticeBanner(
                kind: .information,
                title: "Wallpaper Deleted",
                message: "The original source video was not changed.",
                actionTitle: "Undo",
                action: {
                    actions.send(.restoreWallpaper(itemID: deletedID))
                    recentlyDeletedID = nil
                },
                onDismiss: { recentlyDeletedID = nil }
            )
            .padding(16)
        } else if let notice = model.snapshot.notice {
            NoticeBanner(kind: notice.kind, title: notice.title, message: notice.message)
                .padding(16)
        }
    }

    private var filteredWallpapers: [WALIWallpaperPresentation] {
        guard !searchText.isEmpty else { return model.snapshot.wallpapers }
        return model.snapshot.wallpapers.filter { wallpaper in
            wallpaper.title.localizedStandardContains(searchText)
                || wallpaper.creator?.localizedStandardContains(searchText) == true
                || wallpaper.dimensions.localizedStandardContains(searchText)
        }
    }

    private var selectedWallpaper: WALIWallpaperPresentation? {
        model.snapshot.wallpapers.first { $0.id == selectedWallpaperID }
    }

    private var effectiveDisplayIDs: Set<String> {
        selectedDisplayIDs.intersection(connectedDisplayIDs)
    }

    private var connectedDisplayIDs: Set<String> {
        Set(model.snapshot.displays.lazy.filter(\.isConnected).map(\.id))
    }

    private var hasConnectedDisplaySelection: Bool {
        !effectiveDisplayIDs.isEmpty
    }

    private var activeTransferCount: Int {
        model.snapshot.transfers.count { transfer in
            switch transfer.state {
            case .queued, .working: true
            default: false
            }
        }
    }

    private var rendererToolbarSymbol: String {
        switch model.snapshot.renderer.state {
        case .playing: "play.circle.fill"
        case .automaticallyPaused, .userPaused: "pause.circle"
        case .converting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .error: "exclamationmark.triangle"
        case .stopped: "circle"
        }
    }

    private var displayPickerTitle: String {
        switch selectedDisplayIDs.count {
        case 0: "Choose Displays"
        case 1: "1 Display"
        default: "\(selectedDisplayIDs.count) Displays"
        }
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletionID != nil },
            set: { if !$0 { pendingDeletionID = nil } }
        )
    }

    private func synchronizeSelection() {
        synchronizeDisplays()
        synchronizeWallpaperSelection()
        synchronizeContentFit()
    }

    private func synchronizeDisplays() {
        let connected = connectedDisplayIDs

        if !hasInitializedDisplaySelection {
            guard !connected.isEmpty else {
                knownConnectedDisplayIDs = connected
                return
            }
            selectedDisplayIDs = connected
            hasInitializedDisplaySelection = true
        } else if connected != knownConnectedDisplayIDs {
            // Preserve the pending selection exactly: removed displays fall
            // out, while newly connected displays wait for an explicit pick.
            selectedDisplayIDs.formIntersection(connected)
        }

        knownConnectedDisplayIDs = connected
    }

    private func synchronizeWallpaperSelection() {
        guard selectedWallpaper == nil else { return }
        selectedWallpaperID = model.snapshot.wallpapers.first?.id
    }

    private func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls): importVideos(urls)
        case let .failure(error): localError = error.localizedDescription
        }
    }

    private func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        localError = nil
        actions.send(.importVideos(urls))
        route = .downloads
    }

    private func apply(_ wallpaper: WALIWallpaperPresentation) {
        guard case .ready = wallpaper.availability else { return }
        guard !effectiveDisplayIDs.isEmpty else {
            localError = "Connect or select a display before applying a wallpaper."
            return
        }
        actions.send(.applyWallpaper(
            itemID: wallpaper.id,
            displayIDs: effectiveDisplayIDs,
            contentFit: selectedContentFit
        ))
    }

    private func synchronizeContentFit() {
        let selectedModes = Set(
            model.snapshot.displays.lazy
                .filter { effectiveDisplayIDs.contains($0.id) }
                .compactMap(\.contentFit)
        )
        selectedContentFit = selectedModes.count == 1
            ? selectedModes.first!
            : model.snapshot.preferences.contentFit
    }

    private func preview(_ wallpaper: WALIWallpaperPresentation) {
        selectedWallpaperID = wallpaper.id
        showsPreview = true
    }

    private func requestDeletion(_ wallpaper: WALIWallpaperPresentation) {
        pendingDeletionID = wallpaper.id
    }

    private func confirmDeletion() {
        guard let wallpaperID = pendingDeletionID else { return }
        actions.send(.deleteWallpaper(itemID: wallpaperID))
        recentlyDeletedID = wallpaperID
        pendingDeletionID = nil
    }

    private func openCatalogWallpaper(_ wallpaperID: String) {
        if catalogPath.last != wallpaperID {
            catalogPath.append(wallpaperID)
        }
    }
}

enum WALIAppSurface {
    static let catalogCanvas = Color(nsColor: .underPageBackgroundColor)
}

private struct WALICompactSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.placeholderString = prompt
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = true
        searchField.maximumRecents = 0
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        if searchField.placeholderString != prompt {
            searchField.placeholderString = prompt
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text = searchField.stringValue
        }
    }
}

private extension View {
    @ViewBuilder
    func waliBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }
}

private enum AppRoute: String, CaseIterable, Hashable {
    case discover
    case browse
    case library
    case downloads
    case account
    case creatorStudio
    case reviewQueue
    case reports

    var title: String {
        switch self {
        case .discover: "Discover"
        case .browse: "Browse"
        case .library: "Library"
        case .downloads: "Downloads"
        case .account: "Account"
        case .creatorStudio: "Creator Studio"
        case .reviewQueue: "Review Queue"
        case .reports: "Reports"
        }
    }

    var symbolName: String {
        switch self {
        case .discover: "sparkles.rectangle.stack"
        case .browse: "square.grid.3x3"
        case .library: "square.grid.2x2"
        case .downloads: "arrow.down.circle"
        case .account: "person.crop.circle"
        case .creatorStudio: "person.crop.rectangle.stack"
        case .reviewQueue: "checklist.checked"
        case .reports: "flag.2.crossed"
        }
    }

    var detailHint: String {
        switch self {
        case .discover: "Discover curated and trending wallpapers."
        case .browse: "Browse the complete published catalog."
        case .library: "Select a wallpaper to see details and display controls."
        case .downloads: "Import videos and follow their preparation progress."
        case .account: "Manage your marketplace account and privacy settings."
        case .creatorStudio: "Upload, describe, and submit verified wallpapers."
        case .reviewQueue: "Review canonical submissions with server-owned policy."
        case .reports: "Review assigned marketplace reports."
        }
    }

    var isMarketplace: Bool {
        self == .discover || self == .browse || self == .creatorStudio
            || self == .reviewQueue || self == .reports
    }
    var isLocalLibrary: Bool { self == .library || self == .downloads }
}
