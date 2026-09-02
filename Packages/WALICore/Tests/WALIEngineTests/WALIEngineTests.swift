import Testing
import Foundation
@testable import WALIEngine

@Test("WALIEngine package marker proves its model dependency")
func engineModuleIsAvailableThroughModel() {
    #expect(WALIEngineModule.name == "WALIEngine")
    #expect(WALIEngineModule.modelModuleName == "WALIModel")
}

@Test("Repeated idempotency keys reconcile effects without advancing state twice")
func repeatedCommandDoesNotMutateTwice() async throws {
    let engine = RuntimeEngine()
    let key = UUID()

    let first = try await engine.perform(.setPaused(true), idempotencyKey: key)
    let replay = try await engine.perform(.setPaused(true), idempotencyKey: key)
    let completed = await engine.completedTransaction(for: key)

    #expect(first.snapshot.revision.rawValue == 1)
    #expect(replay.snapshot.revision == first.snapshot.revision)
    #expect(replay.effects == first.effects)
    #expect(completed == first)
}

@Test("Display disconnect and reconnect preserve its wallpaper assignment")
func displayReconnectPreservesAssignment() async throws {
    let itemID = UUID()
    let initial = EngineSnapshot(displays: [
        EngineDisplay(
            id: "display-a",
            name: "Studio Display",
            pixelWidth: 5_120,
            pixelHeight: 2_880,
            isMain: true,
            assignedItemID: itemID
        ),
    ])
    let engine = RuntimeEngine(restoring: initial)

    _ = try await engine.perform(.replaceDisplays([]))
    let reconnect = try await engine.perform(.replaceDisplays([
        EngineDisplay(
            id: "display-a",
            name: "Studio Display",
            pixelWidth: 5_120,
            pixelHeight: 2_880,
            isMain: true
        ),
    ]))

    #expect(reconnect.snapshot.displays.first?.assignedItemID == itemID)
    #expect(reconnect.snapshot.displays.first?.isOnline == true)
}

@Test("Catalog installs are idempotent without creating local import jobs")
func catalogInstallIsIdempotent() async throws {
    let engine = RuntimeEngine()
    let item = catalogItem(id: UUID(), digest: String(repeating: "a", count: 64))

    let first = try await engine.perform(.installCatalogItem(item))
    let replay = try await engine.perform(.installCatalogItem(item))

    #expect(first.snapshot.items == [item])
    #expect(replay.snapshot.items == [item])
    #expect(replay.snapshot.imports.isEmpty)
}

@Test("A stale catalog release cannot retarget an existing item identity")
func catalogInstallRejectsRetarget() async throws {
    let id = UUID()
    let engine = RuntimeEngine(restoring: EngineSnapshot(items: [
        catalogItem(id: id, digest: String(repeating: "a", count: 64)),
    ]))

    await #expect(throws: EngineError.catalogInstallConflict(id)) {
        try await engine.perform(
            .installCatalogItem(catalogItem(id: id, digest: String(repeating: "b", count: 64)))
        )
    }
}

private func catalogItem(id: UUID, digest: String) -> EngineLibraryItem {
    let root = URL(fileURLWithPath: "/tmp/wali-engine-catalog-test", isDirectory: true)
    return EngineLibraryItem(
        id: id,
        name: "Catalog Wallpaper",
        createdAt: Date(timeIntervalSince1970: 1),
        duration: 10,
        pixelWidth: 1_920,
        pixelHeight: 1_080,
        masterURL: root.appendingPathComponent("master.mov"),
        previewURL: root.appendingPathComponent("preview.mov"),
        posterURL: root.appendingPathComponent("poster.heic"),
        contentDigest: digest
    )
}
