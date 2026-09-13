import Observation
import WALICatalogRuntime
import WALIUI

@MainActor
@Observable
public final class CatalogDiscoveryModel {
    public var taxonomyState: WALIMarketplaceLoadState = .idle
    public var categories: [CatalogTaxonomySummary] = []
    public var tags: [CatalogTaxonomySummary] = []
    public var preferences: CatalogPreferences?
    public var preferencesState: WALIMarketplaceLoadState = .idle
    public var preferencesSaveState: WALIMarketplaceActionState = .idle
    public var selectedCategory: String?
    public var selectedTags: Set<String> = []
    public var savedItems: [WALICatalogCardPresentation] = []
    public var savedState: WALIMarketplaceLoadState = .idle
    public var savedNextCursor: String?
    public var savedPageError: String?
    public var isLoadingSavedPage = false
    public var installRecordingFailure: String?
    public var isRetryingInstallRecord = false
    public var canRetryInstallRecord = false
    public init() {}
}
