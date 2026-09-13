import SwiftUI
import WALICatalogRuntime
import WALIUI

struct CatalogPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var discovery: CatalogDiscoveryModel
    let isSignedIn: Bool
    let onReload: () -> Void
    let onSave: ([String], String, Bool) -> Void
    @State private var selected: Set<String> = []
    @State private var rating = "teen"
    @State private var optOut = false

    var body: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Discover Preferences") {}
            if !isSignedIn {
                ContentUnavailableView("Sign In to Choose Interests", systemImage: "person.crop.circle",
                                       description: Text("Your category choices are saved with your account."))
            } else if let preferences = discovery.preferences, !discovery.categories.isEmpty {
                Form {
                    Section("Categories") {
                        Text("Recommendations stay in the categories you choose. Leave all unchecked to use your saves and downloads.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(discovery.categories) { category in
                            Toggle(category.name, isOn: Binding(
                                get: { selected.contains(category.id) },
                                set: { enabled in
                                    if enabled && selected.count < 12 { selected.insert(category.id) }
                                    else if !enabled { selected.remove(category.id) }
                                }))
                                .toggleStyle(.checkbox)
                                .disabled(selected.count >= 12 && !selected.contains(category.id))
                        }
                    }
                    Section("Content and Privacy") {
                        Picker("Content rating", selection: $rating) {
                            Text("Everyone").tag("everyone")
                            Text("Teen").tag("teen")
                            Text("Mature").tag("mature")
                        }
                        Toggle("Personalized suggestions", isOn: Binding(get: { !optOut }, set: { optOut = !$0 }))
                    }
                    if case let .failed(message) = discovery.preferencesSaveState {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if case let .succeeded(message) = discovery.preferencesSaveState {
                        Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .disabled(discovery.preferencesSaveState == .working)
                .onAppear { apply(preferences) }
                .onChange(of: discovery.preferences) { _, value in if let value { apply(value) } }
            } else if discovery.preferencesState == .loading || discovery.taxonomyState == .loading {
                ProgressView("Loading preferences…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Preferences Aren’t Available", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Load your account preferences and available categories to continue.")
                } actions: { Button("Try Again", action: onReload) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if discovery.preferencesSaveState == .working { ProgressView().controlSize(.small).accessibilityLabel("Saving preferences") }
                Button("Save") { onSave(selected.sorted(), rating, optOut) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isSignedIn || discovery.preferences == nil || discovery.categories.isEmpty
                              || discovery.preferencesSaveState == .working)
            }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("WALI.DiscoverPreferences")
    }

    private func apply(_ value: CatalogPreferences) {
        selected = Set(value.categoryIDs).intersection(Set(discovery.categories.map(\.id)))
        rating = value.ratingCeiling
        optOut = value.personalizationOptOut
    }
}

struct SavedCatalogLibraryView: View {
    @Bindable var discovery: CatalogDiscoveryModel
    let isSignedIn: Bool
    let query: String
    let onLoad: () -> Void
    let onLoadMore: () -> Void
    let onOpen: (String) -> Void
    let onSignIn: () -> Void

    private var visibleItems: [WALICatalogCardPresentation] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? discovery.savedItems : discovery.savedItems.filter {
            $0.title.localizedStandardContains(value) || $0.creator.localizedStandardContains(value)
                || $0.category.localizedStandardContains(value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Saved Wallpapers") {}
            if !isSignedIn {
                ContentUnavailableView {
                    Label("Save Wallpapers to Your Account", systemImage: "bookmark")
                } description: { Text("Sign in to find wallpapers you bookmarked on WALI.") }
                actions: { Button("Sign In", action: onSignIn) }
            } else {
                switch discovery.savedState {
                case .idle, .loading: ProgressView("Loading saved wallpapers…").frame(maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView("No Saved Wallpapers", systemImage: "bookmark",
                                           description: Text("Use Save on a wallpaper to find it here later."))
                case .ready:
                    GeometryReader { geometry in
                        let columns = Array(
                            repeating: GridItem(.flexible(), spacing: WALILibraryLayout.gutter, alignment: .top),
                            count: WALILibraryLayout.columnCount(forAvailableWidth: geometry.size.width)
                        )
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: WALILibraryLayout.gutter) {
                                ForEach(visibleItems) { item in
                                    CatalogCardView(card: item, artworkAspect: WALILibraryLayout.artworkAspect) {
                                        onOpen(item.id)
                                    }
                                }
                            }.padding(WALILibraryLayout.chromeInset)
                            if visibleItems.isEmpty { Text("No matching saved wallpapers.").foregroundStyle(.secondary) }
                            if let message = discovery.savedPageError { Text(message).foregroundStyle(.secondary) }
                            if discovery.savedNextCursor != nil {
                                Button(discovery.isLoadingSavedPage ? "Loading…" : "Load More", action: onLoadMore)
                                    .disabled(discovery.isLoadingSavedPage).padding(.bottom, 20)
                            }
                        }
                    }
                case .offline, .failed:
                    ContentUnavailableView {
                        Label("Couldn’t Load Saved Wallpapers", systemImage: "bookmark")
                    } description: { Text("Your downloaded wallpapers remain available in Library.") }
                    actions: { Button("Try Again", action: onLoad) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: onLoad)
        .onChange(of: isSignedIn) { _, _ in onLoad() }
        .accessibilityIdentifier("WALI.SavedLibrary")
    }
}
