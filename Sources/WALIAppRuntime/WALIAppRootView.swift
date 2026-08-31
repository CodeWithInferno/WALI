import SwiftUI
import UniformTypeIdentifiers
import WALIModel
import WALIUI
import WALIWire

/// The foreground library window. Runtime adapters can inject a live model and
/// intention handler while the parameterless initializer keeps previews safe.
public struct WALIAppRootView: View {
    @State private var model: WALIAppModel
    private let actions: any WALIUIActionHandling

    @State private var route: AppRoute = .library
    @State private var selectedWallpaperID: UUID?
    @State private var selectedDisplayIDs: Set<String> = []
    @State private var hasInitializedDisplaySelection = false
    @State private var knownConnectedDisplayIDs: Set<String> = []
    @State private var selectedContentFit: WALIContentFitPreference = .fill
    @State private var searchText = ""
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
        actions: any WALIUIActionHandling = NoopWALIUIActionHandler()
    ) {
        _model = State(initialValue: model)
        self.actions = actions
    }

    public var body: some View {
        navigation
        .navigationTitle(route.title)
        .toolbar { toolbar }
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
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, idealWidth: 1120, minHeight: 560, idealHeight: 720)
        .onAppear(perform: synchronizeSelection)
        .onChange(of: connectedDisplayIDs) { _, _ in
            synchronizeDisplays()
            synchronizeContentFit()
        }
        .onChange(of: selectedDisplayIDs) { _, _ in synchronizeContentFit() }
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
            } detail: {
                detail
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search Library")
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 168, ideal: 190, max: 230)
            } detail: {
                content
            }
        }
    }

    private var sidebar: some View {
        List(selection: $route) {
            Section("My WALI") {
                sidebarRow(.library)
                sidebarRow(.downloads, badge: activeTransferCount)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: route) { _, newRoute in
            if newRoute != .library { searchText = "" }
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
        }
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
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsImporter = true
            } label: {
                Label("Import Video", systemImage: "plus")
            }
            .help("Import Video… (⌘O)")
            .accessibilityIdentifier("WALI.Import")
        }

        ToolbarItemGroup(placement: .automatic) {
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
}

private enum AppRoute: String, CaseIterable, Hashable {
    case library
    case downloads

    var title: String {
        switch self {
        case .library: "Library"
        case .downloads: "Downloads"
        }
    }

    var symbolName: String {
        switch self {
        case .library: "square.grid.2x2"
        case .downloads: "arrow.down.circle"
        }
    }

    var detailHint: String {
        switch self {
        case .library: "Select a wallpaper to see details and display controls."
        case .downloads: "Import videos and follow their preparation progress."
        }
    }
}
