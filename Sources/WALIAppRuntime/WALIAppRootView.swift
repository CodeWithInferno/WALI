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
    @State private var creatorPath: [CreatorSubmission] = []
    @State private var reviewPath: [ModerationQueueItem] = []
    @State private var reportPath: [ModerationReport] = []
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
    @State private var dismissedNoticeKeys: Set<String> = []

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
            .overlay(alignment: WALIChromeLayout.noticeAlignment) { noticeOverlay }
            .onChange(of: model.snapshot.notice) { _, notice in
                if notice == nil {
                    dismissedNoticeKeys.removeAll()
                }
            }
            .background(
                WindowTitlebarSeparatorHider(
                    showsCatalogBack: showsCatalogBack,
                    onCatalogBack: popCatalogPath
                )
            )
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
            .onChange(of: catalogPath) { previous, current in
                guard previous.last != current.last else { return }
                if let wallpaperID = previous.last {
                    marketplace.cancelDetail(wallpaperID: wallpaperID)
                }
                if let wallpaperID = current.last {
                    marketplace.loadDetail(wallpaperID: wallpaperID)
                }
            }
            .onChange(of: model.snapshot.wallpapers) { _, _ in synchronizeWallpaperSelection() }
            .onChange(of: model.settingsPresentationRequest) { _, _ in showsSettings = true }
            .onChange(of: marketplace.model.accountState) { _, _ in
                reviewPath.removeAll()
                reportPath.removeAll()
                creatorPath.removeAll()
            }
            .onChange(of: marketplace.creatorContext.canShowModeratorTools) { _, allowed in
                if !allowed { reviewPath.removeAll(); reportPath.removeAll() }
            }
            .background(keyboardCommands)
            .focusedSceneValue(\.waliSettingsAction, { showsSettings = true })
            .accessibilityIdentifier("WALI.MainWindow")
    }

    private var navigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                .toolbar {
                    if #available(macOS 26.0, *) {
                        DefaultToolbarItem(kind: .sidebarToggle, placement: .navigation)
                            .sharedBackgroundVisibility(sidebarToolbarSharedBackground)
                    }
                }
        } detail: {
            Group {
                if route.isMarketplace {
                    if let wallpaperID = catalogPath.last,
                       WALIMarketplaceDetailLayout.hidesDestinationNavigationHeader {
                        MarketplaceWallpaperDetailView(
                            marketplace: marketplace.model,
                            wallpaperID: wallpaperID,
                            onRetry: { marketplace.loadDetail(wallpaperID: wallpaperID) },
                            onOpenRelated: openCatalogWallpaper,
                            onInstall: { marketplace.installSelectedWallpaper() },
                            onCancelInstall: { marketplace.cancelCatalogInstall() },
                            onRetryInstall: { marketplace.retryCatalogInstall() },
                            installedReleaseIDs: Set(model.snapshot.wallpapers.map { $0.id.uuidString.lowercased() }),
                            onOpenLibrary: {
                                guard let releaseID = marketplace.model.selectedDetail?.currentReleaseID,
                                      let itemID = UUID(uuidString: releaseID) else { return }
                                route = .library
                                selectedWallpaperID = itemID
                            },
                            onFavorite: { marketplace.toggleFavorite() },
                            onSave: { marketplace.toggleSaved() },
                            onReport: marketplace.reportSelectedWallpaper
                        )
                    } else {
                        content
                    }
                } else {
                    content
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .inspector(isPresented: libraryInspectorPresented) {
                libraryInspector
                    .inspectorColumnWidth(min: 280, ideal: 300, max: 320)
            }
            .toolbar(WALIChromeLayout.hidesWindowToolbar ? .hidden : .automatic)
            .waliHiddenWindowToolbarBackground(
                WALIMarketplaceDetailLayout.hidesWindowToolbarBackground
                    && route.isMarketplace
                    && !catalogPath.isEmpty
            )
            .disableMirroredBackgroundExtension()
        }
        .modifier(StableSidebarToggleModifier())
        .environment(
            \.waliOverlayLeadingBleed,
            WALIChromeLayout.overlayLeadingBleed(columnVisibility: columnVisibility)
        )
    }

    private var showsCatalogBack: Bool {
        WALIChromeLayout.catalogBackLivesBesideSidebarToggle
            && (route == .creatorStudio ? !creatorPath.isEmpty
                : route == .reviewQueue ? !reviewPath.isEmpty
                : route == .reports ? !reportPath.isEmpty : !catalogPath.isEmpty)
    }

    private var sidebarToolbarSharedBackground: Visibility {
        WALIChromeLayout.hidesToolbarSharedBackground ? .hidden : .automatic
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
        .searchable(
            text: $searchText,
            placement: WALIChromeLayout.searchFieldPlacement,
            prompt: Text("Search")
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarImportControl
        }
        .onChange(of: route) { _, newRoute in
            if newRoute != .library && newRoute != .browse { searchText = "" }
            catalogPath.removeAll()
            creatorPath.removeAll()
        }
        .accessibilityIdentifier("WALI.Sidebar")
    }

    private func sidebarRow(_ item: AppRoute, badge: Int = 0) -> some View {
        HStack(spacing: 8) {
            if item == .account {
                Label {
                    Text(item.title)
                } icon: {
                    WALIAccountAvatarView(
                        displayName: accountAvatarName,
                        size: 22
                    )
                }
            } else {
                Label(item.title, systemImage: item.symbolName)
            }
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

    private var sidebarImportControl: some View {
        Button {
            showsImporter = true
        } label: {
            Label("Import Video", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .help("Import Video… (⌘O)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("WALI.Import")
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
                onLoad: { sort in
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        marketplace.loadBrowse(sort: sort)
                    } else {
                        marketplace.search(searchText)
                    }
                },
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
                catalogInstall: marketplace.model.catalogInstall,
                onCancelCatalog: { marketplace.cancelCatalogInstall() },
                onRetryCatalog: { marketplace.retryCatalogInstall() },
                onImport: { showsImporter = true },
                onDrop: importVideos,
                onCancel: { transferID in
                    actions.send(.cancelTransfer(id: transferID))
                }
            )
        case .account:
            AccountView(
                account: marketplace.model.accountState,
                authenticationState: marketplace.model.authenticationState,
                profile: marketplace.model.accountProfile,
                profileState: marketplace.model.accountProfileState,
                exportState: marketplace.model.accountExportState,
                deletionState: marketplace.model.accountDeletionState,
                moderatorAccess: marketplace.moderatorAccess,
                hasModeratorRole: marketplace.creatorContext.moderationModel?.authorization.moderatorGrantRevision != nil,
                isModerationUnlocked: marketplace.creatorContext.moderationModel?.canShowReviewQueue == true,
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
                NavigationStack(path: $creatorPath) {
                    CreatorStudioView(
                        model: studioModel,
                        upload: upload,
                        categories: metadata.categories,
                        tags: metadata.tags,
                        licenses: metadata.licenses,
                        accessState: marketplace.creatorContext.state,
                        lastFailureCode: marketplace.creatorContext.lastFailureCode,
                        onAcceptTerms: marketplace.acceptCreatorTerms
                    ) { submission in
                        CreatorSubmissionEditor(
                            submission: submission,
                            gateway: gateway,
                            categories: metadata.categories,
                            tags: metadata.tags,
                            licenses: metadata.licenses,
                            currentTermsVersion: metadata.currentCreatorTermsVersion,
                            didChange: { _ in
                                Task { await studioModel.loadSubmissions() }
                            }
                        )
                    }
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
                NavigationStack(path: $reviewPath) {
                    ReviewQueueView(model: moderationModel)
                        .navigationDestination(for: ModerationQueueItem.self) { item in
                            SubmissionReviewView(item: item, model: moderationModel,
                                                 moderationMetadata: moderationMetadata)
                                .navigationBarBackButtonHidden(WALIChromeLayout.catalogBackLivesBesideSidebarToggle)
                        }
                }
            } else {
                protectedModeratorUnavailable
            }
        case .reports:
            if let moderationModel = marketplace.creatorContext.moderationModel,
               marketplace.creatorContext.canShowModeratorTools {
                NavigationStack(path: $reportPath) {
                    ReportQueueView(model: moderationModel)
                        .navigationDestination(for: ModerationReport.self) { report in
                            ReportReviewView(report: report, model: moderationModel)
                                .navigationBarBackButtonHidden(WALIChromeLayout.catalogBackLivesBesideSidebarToggle)
                        }
                }
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
    private var libraryInspector: some View {
        if let selectedWallpaper {
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
            Button("Back") { popCatalogPath() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!showsCatalogBack)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var noticeOverlay: some View {
        if let localError {
            NoticeBanner(
                kind: .error,
                title: "Import Failed",
                message: localError,
                onDismiss: { self.localError = nil }
            )
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
        } else if let notice = visibleSnapshotNotice {
            NoticeBanner(
                kind: notice.kind,
                title: notice.title,
                message: notice.message,
                onDismiss: { dismissedNoticeKeys.insert(notice.dismissalKey) }
            )
            .padding(16)
        }
    }

    private var visibleSnapshotNotice: WALINoticePresentation? {
        guard let notice = model.snapshot.notice else { return nil }
        guard dismissedNoticeKeys.contains(notice.dismissalKey) == false else { return nil }
        return notice
    }

    private var libraryInspectorPresented: Binding<Bool> {
        Binding(
            get: { route == .library && selectedWallpaper != nil },
            set: { presented in
                if !presented { selectedWallpaperID = nil }
            }
        )
    }

    private var accountAvatarName: String? {
        marketplace.model.accountProfile?.displayName
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
        guard let selectedWallpaperID else { return }
        if !model.snapshot.wallpapers.contains(where: { $0.id == selectedWallpaperID }) {
            self.selectedWallpaperID = nil
        }
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

    private func popCatalogPath() {
        if route == .reports, !reportPath.isEmpty {
            reportPath.removeLast()
            return
        }
        if route == .reviewQueue, !reviewPath.isEmpty {
            reviewPath.removeLast()
            return
        }
        if route == .creatorStudio, !creatorPath.isEmpty {
            creatorPath.removeLast()
            return
        }
        guard !catalogPath.isEmpty else { return }
        catalogPath.removeLast()
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

    var isMarketplace: Bool {
        self == .discover || self == .browse || self == .creatorStudio
            || self == .reviewQueue || self == .reports
    }
}

private struct StableSidebarToggleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func disableMirroredBackgroundExtension() -> some View {
        if #available(macOS 26.0, *), WALIDiscoverLayout.usesMirroredBackgroundExtension == false {
            backgroundExtensionEffect(isEnabled: false)
        } else {
            self
        }
    }
}

private struct WindowTitlebarSeparatorHider: NSViewRepresentable {
    var showsCatalogBack: Bool
    var onCatalogBack: () -> Void

    func makeNSView(context: Context) -> WindowAccessView {
        let view = WindowAccessView()
        view.showsCatalogBack = showsCatalogBack
        view.onCatalogBack = onCatalogBack
        return view
    }

    func updateNSView(_ nsView: WindowAccessView, context: Context) {
        nsView.showsCatalogBack = showsCatalogBack
        nsView.onCatalogBack = onCatalogBack
        nsView.applyChrome()
    }

    static func dismantleNSView(_ nsView: WindowAccessView, coordinator: ()) {
        nsView.removeChrome()
    }
}

private final class WindowAccessView: NSView {
    var showsCatalogBack = false
    var onCatalogBack: (() -> Void)?

    private let catalogBackButton = CatalogBackTitlebarButton()

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func removeChrome() {
        NotificationCenter.default.removeObserver(self)
        catalogBackButton.removeFromSuperview()
        catalogBackButton.onBack = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        applyChrome()
        DispatchQueue.main.async { [weak self] in
            self?.applyChrome()
        }
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
        if let toolbar = window.toolbar {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(toolbarWillAddItem(_:)),
                name: NSToolbar.willAddItemNotification,
                object: toolbar
            )
        }
    }

    func applyChrome() {
        guard let window else { return }
        if WALIChromeLayout.hidesTitlebarSeparator {
            window.titlebarSeparatorStyle = .none
        }
        if WALIChromeLayout.usesFullSizeContentTitlebar {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
        overlaySidebarOnDetail(in: window)
        if WALIChromeLayout.hidesSplitToolbarHandle, let toolbar = window.toolbar {
            toolbar.removeItem(identifier: .sidebarTrackingSeparator)
            toolbar.removeItem(identifier: .inspectorTrackingSeparator)
            toolbar.removeItem(identifier: .space)
            toolbar.removeItem(identifier: .flexibleSpace)
            for item in toolbar.items where isSplitTrackingItem(item) {
                item.isHidden = true
            }
        }
        syncCatalogBackButton(in: window)
    }

    private func overlaySidebarOnDetail(in window: NSWindow) {
        guard WALIChromeLayout.overlaysSidebarOnDetail else { return }
        guard #available(macOS 26.0, *) else { return }
        let split = window.contentView.flatMap(findSplitViewController(in:))
            ?? findSplitViewController(from: window.contentViewController)
        guard let split else { return }
        for item in split.splitViewItems where item.behavior != .sidebar && item.behavior != .inspector {
            item.automaticallyAdjustsSafeAreaInsets = true
        }
    }

    private func findSplitViewController(from controller: NSViewController?) -> NSSplitViewController? {
        guard let controller else { return nil }
        if let split = controller as? NSSplitViewController,
           split.splitViewItems.contains(where: { $0.behavior == .sidebar }) {
            return split
        }
        for child in controller.children {
            if let found = findSplitViewController(from: child) {
                return found
            }
        }
        return nil
    }

    private func findSplitViewController(in view: NSView) -> NSSplitViewController? {
        var responder: NSResponder? = view.nextResponder
        while let current = responder {
            if let split = current as? NSSplitViewController,
               split.splitViewItems.contains(where: { $0.behavior == .sidebar }) {
                return split
            }
            responder = current.nextResponder
        }
        for subview in view.subviews {
            if let found = findSplitViewController(in: subview) {
                return found
            }
        }
        return nil
    }

    @objc private func windowDidChange(_ notification: Notification) {
        applyChrome()
    }

    @objc private func toolbarWillAddItem(_ notification: Notification) {
        if WALIChromeLayout.hidesSplitToolbarHandle {
            let item = notification.userInfo?.values.compactMap { value in
                value as? NSToolbarItem
            }.first
            if let item, isSplitTrackingItem(item) {
                item.isHidden = true
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyChrome()
        }
    }

    private func isSplitTrackingItem(_ item: NSToolbarItem) -> Bool {
        item is NSTrackingSeparatorToolbarItem
            || item.itemIdentifier == .sidebarTrackingSeparator
            || item.itemIdentifier == .inspectorTrackingSeparator
            || item.itemIdentifier == .space
            || item.itemIdentifier == .flexibleSpace
    }

    private func syncCatalogBackButton(in window: NSWindow) {
        catalogBackButton.onBack = onCatalogBack
        guard WALIChromeLayout.catalogBackLivesBesideSidebarToggle, showsCatalogBack else {
            catalogBackButton.removeFromSuperview()
            return
        }
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview,
              let toggle = sidebarToggleView(in: window, titlebar: titlebar)
        else {
            catalogBackButton.removeFromSuperview()
            return
        }
        if catalogBackButton.superview !== titlebar {
            catalogBackButton.removeFromSuperview()
            titlebar.addSubview(catalogBackButton)
        }
        let toggleFrame = toggle.convert(toggle.bounds, to: titlebar)
        let width = max(toggleFrame.width, 28)
        catalogBackButton.frame = NSRect(
            x: toggleFrame.maxX + WALIChromeLayout.catalogBackTitlebarSpacing,
            y: toggleFrame.minY,
            width: width,
            height: toggleFrame.height
        )
    }

    private func sidebarToggleView(in window: NSWindow, titlebar: NSView) -> NSView? {
        if let toolbar = window.toolbar {
            for item in toolbar.items where isSidebarToggleItem(item) {
                if let view = item.view, view.bounds.width > 0 {
                    return view
                }
            }
        }
        let lights = Set(trafficLights(in: window).map(ObjectIdentifier.init))
        let buttons = buttons(in: titlebar).filter { button in
            button !== catalogBackButton && lights.contains(ObjectIdentifier(button)) == false
        }
        return buttons.min { left, right in
            left.convert(left.bounds, to: titlebar).minX < right.convert(right.bounds, to: titlebar).minX
        }
    }

    private func isSidebarToggleItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleSidebar { return true }
        let raw = item.itemIdentifier.rawValue.lowercased()
        return raw.contains("sidebar") && raw.contains("toggle")
    }

    private func trafficLights(in window: NSWindow) -> [NSView] {
        [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton {
            found.append(button)
        }
        for subview in view.subviews {
            found.append(contentsOf: buttons(in: subview))
        }
        return found
    }
}

private final class CatalogBackTitlebarButton: NSButton {
    var onBack: (() -> Void)?

    init() {
        super.init(frame: .zero)
        let image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        self.image = image
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .shadowlessSquare
        toolTip = "Back"
        identifier = NSUserInterfaceItemIdentifier("WALI.Marketplace.Detail.Back")
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
        setAccessibilityLabel("Back")
        setAccessibilityIdentifier("WALI.Marketplace.Detail.Back")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    @objc private func clicked() {
        onBack?()
    }
}
