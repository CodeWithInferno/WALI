import Foundation
import ServiceManagement
import XCTest
import WALIWire
import WALIModel
@testable import WALIAppRuntime

@MainActor
final class AgentLifecycleTests: XCTestCase {
    func testConsentPrecedesRegistrationAndDoesNotChangeLaunchAtLogin() throws {
        let suite = "WALI.LifecycleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "launchAtLogin")
        let service = RecordingRegistration()
        let lifecycle = AgentLifecycleController(
            registrations: [service], defaults: defaults, requiresExplicitConsent: true
        )
        XCTAssertThrowsError(try lifecycle.ensureRunning())
        XCTAssertEqual(service.registrations, 0)
        lifecycle.allowBackgroundPlayback()
        try lifecycle.ensureRunning()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        try lifecycle.ensureRunning()
        XCTAssertEqual(service.registrations, 1)
    }

    func testOtherDistributionBlocksRegistration() throws {
        for identifier in [
            "io.github.codewithinferno.wali.WALIAgent", "com.wali.WALIAgent",
            "com.wali.development.WALIAgent", "com.wali.debug.WALIAgent",
            "com.wali.store.development.WALIAgent",
        ] {
            let suite = "WALI.LifecycleTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = RecordingRegistration()
            let lifecycle = AgentLifecycleController(
                registrations: [service], defaults: defaults, requiresExplicitConsent: true,
                expectedAgentIdentifier: "com.wali.store.WALIAgent",
                runningAgentIdentifiers: { [identifier] }
            )
            lifecycle.allowBackgroundPlayback()
            XCTAssertThrowsError(try lifecycle.ensureRunning(), identifier)
            XCTAssertEqual(service.registrations, 0, identifier)
        }
    }

    #if !WALI_APP_STORE
    func testDirectServiceFallbackUsesRegisteredReleaseNamespace() {
        XCTAssertEqual(AgentServiceName.current, "io.github.codewithinferno.wali.WALIAgent.control")
    }
    #endif

    func testSystemApprovalDoesNotBecomeConsentOrRepeatedRegistration() throws {
        let suite = "WALI.LifecycleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RecordingRegistration()
        service.status = .requiresApproval
        let lifecycle = AgentLifecycleController(
            registrations: [service], defaults: defaults, requiresExplicitConsent: true
        )
        XCTAssertFalse(lifecycle.hasBackgroundPlaybackConsent)
        lifecycle.allowBackgroundPlayback()
        XCTAssertThrowsError(try lifecycle.ensureRunning())
        XCTAssertEqual(service.registrations, 0)
        XCTAssertTrue(lifecycle.requiresApproval)
    }
}

@MainActor
private final class RecordingRegistration: AgentServiceRegistration {
    var status = SMAppService.Status.notRegistered
    var registrations = 0
    func register() throws { registrations += 1; status = .enabled }
    func unregister() async throws { status = .notRegistered }
}

#if WALI_APP_STORE
final class StoreAgentPeerRequirementTests: XCTestCase {
    func testOnlyExactStoreChannelIsAccepted() throws {
        let expression = try StoreAgentPeerRequirement.expression(
            appIdentifier: "com.wali.store.WALI", agentIdentifier: "com.wali.store.WALIAgent", team: "ABCDEFGHIJ"
        )
        XCTAssertTrue(expression.contains("com.wali.store.WALIAgent"))
        for peer in ["io.github.codewithinferno.wali.WALIAgent", "com.wali.WALIAgent", "com.wali.store.development.WALIAgent", "com.wali.debug.WALIAgent"] {
            XCTAssertThrowsError(try StoreAgentPeerRequirement.expression(
                appIdentifier: "com.wali.store.WALI", agentIdentifier: peer, team: "ABCDEFGHIJ"
            ))
        }
        XCTAssertThrowsError(try StoreAgentPeerRequirement.expression(
            appIdentifier: "com.wali.store.WALI", agentIdentifier: "com.wali.store.WALIAgent", team: ""
        ))
    }
}
#endif

#if WALI_APP_STORE
@MainActor
final class StoreForegroundQuitTests: XCTestCase {
    func testNeverConsentedQuitDoesNotContactAgent() async throws {
        let suite = "WALI.QuitTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = QuitRecorder()
        let lifecycle = AgentLifecycleController(registrations: [], defaults: defaults, requiresExplicitConsent: true)
        let coordinator = WALIAppCoordinator(lifecycle: lifecycle, quitAgent: { try recorder.quit() })
        try await coordinator.prepareForQuit()
        XCTAssertEqual(recorder.calls, 0)
        XCTAssertTrue(coordinator.quitWasAcknowledged)
    }

    func testConsentedStartingStateStillQuitsAgentAndRetriesFailure() async throws {
        let suite = "WALI.QuitTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = QuitRecorder()
        recorder.failFirst = true
        let lifecycle = AgentLifecycleController(registrations: [], defaults: defaults, requiresExplicitConsent: true)
        lifecycle.allowBackgroundPlayback()
        let coordinator = WALIAppCoordinator(lifecycle: lifecycle, quitAgent: { try recorder.quit() })
        XCTAssertEqual(coordinator.backgroundState, .starting)
        do {
            try await coordinator.prepareForQuit()
            XCTFail("Expected the simulated transport failure")
        } catch {}
        XCTAssertFalse(coordinator.quitWasAcknowledged)
        coordinator.start()
        XCTAssertEqual(coordinator.backgroundState, .starting, "Pending starts must stay stopped after a Quit attempt")
        try await coordinator.prepareForQuit()
        XCTAssertEqual(recorder.calls, 2)
        XCTAssertTrue(coordinator.quitWasAcknowledged)
    }
}

@MainActor
private final class QuitRecorder {
    var calls = 0
    var failFirst = false
    func quit() throws {
        calls += 1
        if failFirst, calls == 1 { throw CocoaError(.xpcConnectionInterrupted) }
    }
}
#endif

#if WALI_APP_STORE
@MainActor
final class StoreWindowPollingTests: XCTestCase {
    func testPollingPausesOnlyAfterLastWindowClosesAndResumes() async throws {
        let suite = "WALI.WindowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = AgentLifecycleController(
            registrations: [RecordingRegistration()], defaults: defaults, requiresExplicitConsent: true
        )
        lifecycle.allowBackgroundPlayback()
        let probe = SnapshotPollingProbe()
        let coordinator = WALIAppCoordinator(
            lifecycle: lifecycle, snapshotRequest: { probe.snapshot() }, snapshotInterval: .milliseconds(10)
        )
        let firstWindow = UUID(), secondWindow = UUID(), reopenedWindow = UUID()
        defer {
            coordinator.windowDidDisappear(firstWindow)
            coordinator.windowDidDisappear(secondWindow)
            coordinator.windowDidDisappear(reopenedWindow)
        }
        let firstPoll = expectation(description: "First visible window polls")
        probe.nextPoll = firstPoll
        coordinator.windowDidAppear(firstWindow)
        coordinator.windowDidAppear(secondWindow)
        await fulfillment(of: [firstPoll], timeout: 2)
        XCTAssertEqual(coordinator.backgroundState, .ready)

        let remainingWindowPoll = expectation(description: "Remaining window continues polling")
        probe.nextPoll = remainingWindowPoll
        coordinator.windowDidDisappear(firstWindow)
        await fulfillment(of: [remainingWindowPoll], timeout: 2)

        coordinator.windowDidDisappear(secondWindow)
        XCTAssertEqual(coordinator.backgroundState, .ready,
            "Occlusion pauses polling without removing the foreground root")
        let stoppedAt = probe.calls
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.calls, stoppedAt)

        let resumed = expectation(description: "Reopened window refreshes")
        probe.nextPoll = resumed
        coordinator.windowDidAppear(reopenedWindow)
        XCTAssertEqual(coordinator.backgroundState, .ready,
            "The ready content branch must stay mounted, preserving its route, importer and authentication sheets")
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(coordinator.backgroundState, .ready)
        XCTAssertGreaterThan(probe.calls, stoppedAt)
    }

    func testInitialConsentAndApprovalRecoveryStillGateForegroundReadiness() async throws {
        let suite = "WALI.WindowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registration = RecordingRegistration()
        registration.status = .requiresApproval
        let lifecycle = AgentLifecycleController(
            registrations: [registration], defaults: defaults, requiresExplicitConsent: true
        )
        let probe = SnapshotPollingProbe()
        let coordinator = WALIAppCoordinator(
            lifecycle: lifecycle, snapshotRequest: { probe.snapshot() }
        )
        let window = UUID()
        defer { coordinator.windowDidDisappear(window) }
        coordinator.windowDidAppear(window)
        XCTAssertEqual(coordinator.backgroundState, .needsConsent)
        XCTAssertEqual(probe.calls, 0)

        coordinator.allowBackgroundPlayback()
        XCTAssertEqual(coordinator.backgroundState, .starting)
        try await waitUntil { coordinator.backgroundState == .needsApproval }
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(registration.registrations, 0)

        registration.status = .enabled
        let resumed = expectation(description: "Approved service provides its first snapshot")
        probe.nextPoll = resumed
        coordinator.start()
        XCTAssertEqual(coordinator.backgroundState, .starting,
            "Retry from an actual approval error still shows startup")
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(coordinator.backgroundState, .ready)
    }

    func testInitialRegistrationFailureDoesNotExposeReadyContent() async throws {
        let suite = "WALI.WindowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = AgentLifecycleController(
            registrations: nil, defaults: defaults, requiresExplicitConsent: true
        )
        lifecycle.allowBackgroundPlayback()
        let probe = SnapshotPollingProbe()
        let coordinator = WALIAppCoordinator(
            lifecycle: lifecycle, snapshotRequest: { probe.snapshot() }
        )
        let window = UUID()
        defer { coordinator.windowDidDisappear(window) }
        coordinator.windowDidAppear(window)
        XCTAssertEqual(coordinator.backgroundState, .starting)
        try await waitUntil {
            coordinator.backgroundState == .failed(AgentLifecycleError.missingConfiguration.localizedDescription)
        }
        XCTAssertEqual(probe.calls, 0)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Expected the bounded lifecycle transition")
    }
}

@MainActor
private final class SnapshotPollingProbe {
    var calls = 0
    var nextPoll: XCTestExpectation?
    func snapshot() -> AgentSnapshot {
        calls += 1
        let expectation = nextPoll
        nextPoll = nil
        expectation?.fulfill()
        return AgentSnapshot(revision: .init(rawValue: 0))
    }
}
#endif

#if WALI_APP_STORE
@MainActor
final class StoreInterruptionReconnectTests: XCTestCase {
    func testHiddenConsentedAppReconnectsWithoutStartingPolling() async throws {
        let suite = "WALI.ReconnectTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = AgentLifecycleController(registrations: [], defaults: defaults, requiresExplicitConsent: true)
        lifecycle.allowBackgroundPlayback()
        let gateway = ReconnectGateway()
        let firstSnapshot = expectation(description: "Visible window receives a snapshot")
        gateway.onSnapshot = firstSnapshot
        let coordinator = WALIAppCoordinator(
            connection: gateway, lifecycle: lifecycle, snapshotInterval: .milliseconds(10)
        )
        let window = UUID()
        coordinator.windowDidAppear(window)
        await fulfillment(of: [firstSnapshot], timeout: 2)
        coordinator.windowDidDisappear(window)
        let stoppedAt = gateway.snapshots
        let connected = expectation(description: "One hidden lifecycle handshake")
        gateway.onHandshake = connected
        gateway.interrupt()
        await fulfillment(of: [connected], timeout: 2)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(gateway.handshakes, 1)
        XCTAssertEqual(gateway.snapshots, stoppedAt)
        XCTAssertTrue(gateway.isConnected)
        coordinator.stop()
    }

    func testFailedHandshakeDoesNotRetryUntilForegroundRefresh() async throws {
        let suite = "WALI.ReconnectTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = AgentLifecycleController(registrations: [], defaults: defaults, requiresExplicitConsent: true)
        lifecycle.allowBackgroundPlayback()
        let gateway = ReconnectGateway()
        gateway.failHandshake = true
        let attempted = expectation(description: "One failed handshake")
        gateway.onHandshake = attempted
        let coordinator = WALIAppCoordinator(connection: gateway, lifecycle: lifecycle)
        gateway.interrupt()
        await fulfillment(of: [attempted], timeout: 2)
        await Task.yield()
        gateway.interrupt()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(gateway.handshakes, 1)
        XCTAssertFalse(gateway.isConnected)
        XCTAssertEqual(coordinator.model.snapshot.notice?.title, "Background Connection Interrupted")
        let recovered = expectation(description: "Explicit foreground refresh restores the connection")
        gateway.onSnapshot = recovered
        gateway.failHandshake = false
        let window = UUID()
        coordinator.windowDidAppear(window)
        await fulfillment(of: [recovered], timeout: 2)
        coordinator.windowDidDisappear(window)
        let laterHandshake = expectation(description: "A later interruption gets one new handshake")
        gateway.onHandshake = laterHandshake
        gateway.interrupt()
        await fulfillment(of: [laterHandshake], timeout: 2)
        XCTAssertEqual(gateway.handshakes, 2)
        coordinator.stop()
    }

    func testNoConsentAndIntentionalQuitSuppressReconnect() async throws {
        let suite = "WALI.ReconnectTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycle = AgentLifecycleController(registrations: [], defaults: defaults, requiresExplicitConsent: true)
        let gateway = ReconnectGateway()
        let coordinator = WALIAppCoordinator(connection: gateway, lifecycle: lifecycle)
        gateway.interrupt()
        await Task.yield()
        XCTAssertEqual(gateway.handshakes, 0)
        lifecycle.allowBackgroundPlayback()
        try await coordinator.prepareForQuit()
        gateway.interrupt()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(gateway.handshakes, 0)
        XCTAssertTrue(coordinator.quitWasAcknowledged)
        XCTAssertEqual(gateway.quits, 1)
    }
}

@MainActor
private final class ReconnectGateway: AgentGateway {
    var isConnected = false
    var onAgentWillTerminate: (@MainActor @Sendable () -> Void)?
    var onConnectionEnded: (@MainActor @Sendable () -> Void)?
    var onHandshake: XCTestExpectation?
    var onSnapshot: XCTestExpectation?
    var failHandshake = false
    var handshakes = 0
    var snapshots = 0
    var quits = 0

    func interrupt() { isConnected = false; onConnectionEnded?() }
    func invalidate() { isConnected = false }
    func send(_ command: AgentCommand, expectedRevision: WALIModel.EngineRevision?, idempotencyKey: UUID) async throws -> AgentSnapshot {
        switch command {
        case .handshake:
            handshakes += 1
            onHandshake?.fulfill()
            onHandshake = nil
            if failHandshake { throw AgentConnectionError.unavailable }
        case .snapshot:
            snapshots += 1
            onSnapshot?.fulfill()
            onSnapshot = nil
        case .quit: quits += 1
        default: break
        }
        isConnected = true
        return AgentSnapshot(revision: .init(rawValue: 0))
    }
}
#endif
