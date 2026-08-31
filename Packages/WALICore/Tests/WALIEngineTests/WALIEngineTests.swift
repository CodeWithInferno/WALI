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

    #expect(first.snapshot.revision.rawValue == 1)
    #expect(replay.snapshot.revision == first.snapshot.revision)
    #expect(replay.effects == first.effects)
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
