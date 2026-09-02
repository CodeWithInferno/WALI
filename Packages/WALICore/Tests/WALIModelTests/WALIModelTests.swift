import Testing
import Foundation
@testable import WALIModel

@Test("WALIModel provides its package-only module marker")
func modelModuleIsAvailable() {
    #expect(WALIModelModule.name == "WALIModel")
}

@Test("Legacy local and bundled library records decode without catalog provenance")
func legacyLibraryOriginMigration() throws {
    let decoder = JSONDecoder()
    for origin in ["local_import", "bundled"] {
        let json = """
        {"schema":{"epoch":1,"revision":0},"id":"11111111-1111-4111-8111-111111111111","releaseID":"22222222-2222-4222-8222-222222222222","displayName":"Legacy","origin":"\(origin)"}
        """
        let item = try decoder.decode(LibraryItem.self, from: Data(json.utf8))
        #expect(item.catalogOrigin == nil)
    }
}

@Test("Catalog library records require immutable provenance")
func catalogLibraryOriginIsRequired() throws {
    #expect(throws: ModelViolation.self) {
        try LibraryItem(
            schema: .current,
            id: LibraryItemID("11111111-1111-4111-8111-111111111111"),
            releaseID: AssetReleaseID("22222222-2222-4222-8222-222222222222"),
            displayName: "Catalog",
            origin: .catalog
        )
    }
}
