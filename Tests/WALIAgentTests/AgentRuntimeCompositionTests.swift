import Foundation
import WALIEngine
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class AgentRuntimeCompositionTests: XCTestCase {
    func testRuntimeModuleIsAvailableWithoutAnApplicationHost() {
        XCTAssertEqual(String(describing: WALIAgentRootView.self), "WALIAgentRootView")
    }

    func testRendererDiagnosticCountsPauseReasonsWithoutPrivateDetails() {
        let snapshot = WallpaperRendererSnapshot(displays: [], sessions: [
            .init(id: .init(rawValue: "private-display-a"), status: .paused([.windowOccluded, .lowPower])),
            .init(id: .init(rawValue: "private-display-b"), status: .paused([.windowOccluded])),
            .init(id: .init(rawValue: "private-display-c"), status: .playing),
            .init(id: .init(rawValue: "private-display-d"), status: .failed("file:///private/source/account-id/movie.mp4")),
        ], isUserPaused: false, automaticPauseReasons: [.thermalPressure, .lowPower])
        XCTAssertEqual(snapshot.diagnosticSummary,
            "sessions=4 statuses=preparing:0,playing:1,displaying:0,paused:2,failed:1 system_reasons=low_power,thermal_pressure session_reasons=low_power:1,window_occluded:2")
        XCTAssertFalse(snapshot.diagnosticSummary.contains("private"))
        XCTAssertFalse(snapshot.diagnosticSummary.contains("account-id"))
        let reordered = WallpaperRendererSnapshot(displays: [], sessions: snapshot.sessions.reversed(),
            isUserPaused: false, automaticPauseReasons: [.lowPower, .thermalPressure])
        XCTAssertEqual(snapshot.diagnosticSummary, reordered.diagnosticSummary)
    }

    func testRendererDiagnosticKeepsUserPauseDistinctFromAutomaticReasons() {
        let snapshot = WallpaperRendererSnapshot(displays: [], sessions: [
            .init(id: .init(rawValue: "private-display"), status: .paused([])),
            .init(id: .init(rawValue: "private-still"), status: .displaying),
            .init(id: .init(rawValue: "private-loading"), status: .preparing),
        ], isUserPaused: true, automaticPauseReasons: [])
        XCTAssertEqual(snapshot.diagnosticSummary,
            "sessions=3 statuses=preparing:1,playing:0,displaying:1,paused:1,failed:0 system_reasons=none session_reasons=none")
    }

    @MainActor
    func testPlayingDisplayIsNotReportedAsGloballySuspended() {
        for statuses: [WallpaperSessionStatus] in [
            [.playing, .paused([.windowOccluded])],
            [.paused([.windowOccluded]), .playing],
        ] {
            XCTAssertEqual(WALIAgentController.playbackStatus(from: rendererSnapshot(statuses)), .playing)
        }
    }

    @MainActor
    func testAllAutomaticallyPausedDisplaysRemainSuspended() {
        XCTAssertEqual(WALIAgentController.playbackStatus(from: rendererSnapshot([
            .paused([.windowOccluded]), .paused([.displayAsleep]),
        ])), .suspended)
    }

    @MainActor
    func testPlaybackAggregationPreservesUserFailureAndPreparingPriorities() {
        XCTAssertEqual(WALIAgentController.playbackStatus(from: rendererSnapshot([
            .playing, .paused([.windowOccluded]),
        ], isUserPaused: true)), .paused)
        XCTAssertEqual(WALIAgentController.playbackStatus(from: rendererSnapshot([
            .playing, .paused([.windowOccluded]), .failed("Playback unavailable"),
        ])), .failed("Playback unavailable"))
        XCTAssertEqual(WALIAgentController.playbackStatus(from: rendererSnapshot([
            .playing, .preparing,
        ])), .preparing)
        XCTAssertEqual(WALIAgentController.playbackStatus(from: rendererSnapshot([
            .displaying, .displaying,
        ], isUserPaused: true)), .displaying)
    }

    private func rendererSnapshot(_ statuses: [WallpaperSessionStatus],
                                  isUserPaused: Bool = false) -> WallpaperRendererSnapshot {
        WallpaperRendererSnapshot(displays: [], sessions: statuses.enumerated().map {
            .init(id: .init(rawValue: "test-display-\($0.offset)"), status: $0.element)
        }, isUserPaused: isUserPaused, automaticPauseReasons: [])
    }

    @MainActor
    func testRendererForwardsEachDistinctSessionLockOnce() {
        let systemEvents = SystemEventSource()
        let renderer = WallpaperRenderer(systemEvents: systemEvents)
        var lockCallbacks = 0
        renderer.onSessionLock = { lockCallbacks += 1 }
        renderer.start()
        defer { renderer.shutdown() }

        systemEvents.set(.sessionLocked, active: true)
        systemEvents.set(.sessionLocked, active: true)
        XCTAssertEqual(lockCallbacks, 1)

        systemEvents.set(.sessionLocked, active: false)
        systemEvents.set(.sessionLocked, active: true)
        XCTAssertEqual(lockCallbacks, 2)
    }

}

@MainActor
final class RendererResourceReportingTests: XCTestCase {
    func testProjectionUsesActualPowerAndCountsOnlyPlayingVideoSessions() {
        let snapshot = rendererSnapshot([.playing, .paused([.lowPower]), .displaying, .preparing, .failed("Unavailable")])
        let observation = WALIAgentController.resourceObservation(from: snapshot,
            isLowPowerModeEnabled: true, thermalState: .critical)
        XCTAssertEqual(observation.activePlayers, 1)
        XCTAssertTrue(observation.isLowPowerModeEnabled)
        XCTAssertEqual(observation.thermalState, "critical")
    }

    func testExactThermalFactsChangeWithoutNeedingAPauseReasonChange() {
        for (state, label): (ProcessInfo.ThermalState, String) in [
            (.nominal, "nominal"), (.fair, "fair"), (.serious, "serious"), (.critical, "critical"),
        ] {
            let observation = WALIAgentController.resourceObservation(from: rendererSnapshot([]),
                isLowPowerModeEnabled: false, thermalState: state)
            XCTAssertEqual(observation.thermalState, label)
        }
    }

    func testRuntimeAndStorageUpdatesPreserveOtherFieldsAndSkipUnchangedWrites() async throws {
        let router = AgentCommandRouter(restoring: EngineSnapshot(resourceUsage: .init(
            cpuPercent: 7, residentMemoryBytes: 123, storageUsedBytes: 42, storageLimitBytes: 900))) { _, _ in .unchanged }
        let observation = RendererResourceObservation(playbackStatus: .playing, activePlayers: 2,
            isLowPowerModeEnabled: true, thermalState: "serious")
        _ = try await router.recordRendererObservation(observation)
        let merged = try await router.recordStorageUsage(99)
        XCTAssertEqual(merged.playbackStatus, .playing)
        XCTAssertEqual(merged.resourceUsage.activePlayers, 2)
        XCTAssertTrue(merged.resourceUsage.isLowPowerModeEnabled)
        XCTAssertEqual(merged.resourceUsage.thermalState, "serious")
        XCTAssertEqual(merged.resourceUsage.storageUsedBytes, 99)
        XCTAssertEqual(merged.resourceUsage.storageLimitBytes, 900)
        XCTAssertEqual(merged.resourceUsage.cpuPercent, 7)
        XCTAssertEqual(merged.resourceUsage.residentMemoryBytes, 123)
        let unchanged = try await router.recordRendererObservation(observation)
        let unchangedStorage = try await router.recordStorageUsage(99)
        XCTAssertEqual(unchanged.revision, merged.revision)
        XCTAssertEqual(unchangedStorage.revision, merged.revision)
    }

    func testConcurrentStorageUpdateCannotEraseRendererObservation() async throws {
        let gate = ResourceWriteGate()
        let router = AgentCommandRouter { step, _ in
            if case .preflight(.setResourceUsage) = step { await gate.pauseFirstWrite() }
            return .unchanged
        }
        let recording = Task {
            try await router.recordRendererObservation(.init(playbackStatus: .playing,
                activePlayers: 3, isLowPowerModeEnabled: true, thermalState: "fair"))
        }
        guard await waitUntil({ await gate.isWaiting }) else {
            recording.cancel(); XCTFail("The first resource write never reached its controlled gate"); return
        }
        let storage = Task { try await router.recordStorageUsage(77) }
        await gate.release()
        _ = try await recording.value
        _ = try await storage.value
        let result = await router.snapshot()
        XCTAssertEqual(result.resourceUsage.activePlayers, 3)
        XCTAssertTrue(result.resourceUsage.isLowPowerModeEnabled)
        XCTAssertEqual(result.resourceUsage.thermalState, "fair")
        XCTAssertEqual(result.resourceUsage.storageUsedBytes, 77)
    }

    func testCoalescedPassReadsNewestStateAfterAnInFlightObservation() async {
        let latest = LatestObservationValue()
        var applied: [Int] = []
        var pending: CheckedContinuation<Void, Never>?
        let synchronizer = RendererObservationSynchronizer {
            let captured = latest.value
            if captured == 1 { await withCheckedContinuation { pending = $0 } }
            if !Task.isCancelled { applied.append(captured) }
        }
        synchronizer.start()
        synchronizer.request()
        guard await waitUntil({ pending != nil }) else {
            synchronizer.stop(); XCTFail("The first observation did not begin"); return
        }
        latest.value = 2
        synchronizer.request()
        synchronizer.request()
        pending?.resume(); pending = nil
        await synchronizer.flush()
        XCTAssertEqual(applied, [1, 2])
        synchronizer.stop()
    }

    func testStoppingAnAwaitingObservationPreventsLateCommitAndRerun() async {
        var committed = 0
        var finished = false
        var pending: CheckedContinuation<Void, Never>?
        let synchronizer = RendererObservationSynchronizer {
            await withCheckedContinuation { pending = $0 }
            if !Task.isCancelled { committed += 1 }
            finished = true
        }
        synchronizer.start(); synchronizer.request()
        guard await waitUntil({ pending != nil }) else {
            synchronizer.stop(); XCTFail("The controlled observation did not begin"); return
        }
        synchronizer.request()
        synchronizer.stop()
        pending?.resume(); pending = nil
        let didFinish = await waitUntil({ finished })
        XCTAssertTrue(didFinish)
        await synchronizer.flush()
        XCTAssertEqual(committed, 0)
        XCTAssertNil(pending)
    }

    func testAgentPauseLabelUsesPowerPolicyAndThermalState() {
        let pause = AgentSnapshot(revision: .init(rawValue: 1), playback: .suspended,
            preferences: .init(lowPowerBehavior: .pause),
            resourceUsage: .init(isLowPowerModeEnabled: true))
        XCTAssertEqual(pause.agentPresentation.renderer.state, .automaticallyPaused(reason: "Low Power Mode"))
        let continuing = AgentSnapshot(revision: .init(rawValue: 1), playback: .suspended,
            preferences: .init(lowPowerBehavior: .continuePlaying),
            resourceUsage: .init(isLowPowerModeEnabled: true))
        XCTAssertEqual(continuing.agentPresentation.renderer.state, .automaticallyPaused(reason: "System activity"))
        let thermal = AgentSnapshot(revision: .init(rawValue: 1), playback: .suspended,
            resourceUsage: .init(thermalState: "serious"))
        XCTAssertEqual(thermal.agentPresentation.renderer.state, .automaticallyPaused(reason: "Thermal pressure"))
    }

    private func rendererSnapshot(_ statuses: [WallpaperSessionStatus]) -> WallpaperRendererSnapshot {
        .init(displays: [], sessions: statuses.enumerated().map {
            .init(id: .init(rawValue: "fixture-\($0.offset)"), status: $0.element)
        }, isUserPaused: false, automaticPauseReasons: [])
    }

    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class LatestObservationValue {
    var value = 1
}

private actor ResourceWriteGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var hasPaused = false
    var isWaiting: Bool { pending != nil }
    func pauseFirstWrite() async {
        guard !hasPaused else { return }
        hasPaused = true
        await withCheckedContinuation { pending = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
