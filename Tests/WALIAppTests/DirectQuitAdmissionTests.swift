#if !WALI_APP_STORE
import AppKit
import ServiceManagement
import WALICatalog
import WALIModel
import WALIWire
import XCTest
@testable import WALICatalogRuntime
@testable import WALIAppRuntime

@MainActor
final class DirectQuitAdmissionTests: XCTestCase {
    func testQuitSuspendsAllParticipantsAndFailureResumesOnlyOpenWindows() async throws {
        let lifetime = DirectForegroundLifetime()
        let first = QuitGateway(), second = QuitGateway(), added = QuitGateway()
        let firstCoordinator = makeCoordinator(first), secondCoordinator = makeCoordinator(second)
        lifetime.register(firstCoordinator)
        lifetime.register(secondCoordinator)
        let firstWindow = UUID(), secondWindow = UUID(), addedWindow = UUID()
        defer { firstCoordinator.stop(); secondCoordinator.stop() }
        let initial = expectation(description: "Both visible windows poll")
        initial.expectedFulfillmentCount = 2
        first.nextRequest = initial
        second.nextRequest = initial
        firstCoordinator.windowDidAppear(firstWindow)
        secondCoordinator.windowDidAppear(secondWindow)
        await fulfillment(of: [initial], timeout: 1)

        let requested = expectation(description: "Quit reaches agent after suspension")
        let failed = expectation(description: "Failed Quit is denied")
        var pendingQuit: CheckedContinuation<Void, Error>?
        let delegate = WALIDirectApplicationDelegate(lifetime: lifetime, quitAgent: {
            XCTAssertGreaterThanOrEqual(first.invalidations, 1)
            XCTAssertGreaterThanOrEqual(second.invalidations, 1)
            try await withCheckedThrowingContinuation { pendingQuit = $0; requested.fulfill() }
        }, reply: { permit in XCTAssertFalse(permit); failed.fulfill() }, reportFailure: { _ in })
        XCTAssertEqual(delegate.requestQuit(), .terminateLater)
        XCTAssertEqual(first.invalidations, 1)
        XCTAssertEqual(second.invalidations, 1)
        firstCoordinator.send(.nextWallpaper)
        secondCoordinator.send(.nextWallpaper)
        let addedCoordinator = makeCoordinator(added)
        defer { addedCoordinator.stop() }
        lifetime.register(addedCoordinator)
        addedCoordinator.windowDidAppear(addedWindow)
        secondCoordinator.windowDidDisappear(secondWindow)
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(first.commands, ["snapshot"])
        XCTAssertEqual(second.commands, ["snapshot"])
        XCTAssertTrue(added.commands.isEmpty)

        let resumed = expectation(description: "Only remaining visible windows resume")
        resumed.expectedFulfillmentCount = 2
        first.nextRequest = resumed
        added.nextRequest = resumed
        pendingQuit?.resume(throwing: AgentConnectionError.timedOut)
        await fulfillment(of: [failed, resumed], timeout: 1)
        XCTAssertEqual(first.commands, ["snapshot", "snapshot"])
        XCTAssertEqual(second.commands, ["snapshot"])
        XCTAssertEqual(added.commands, ["snapshot"])
    }

    func testPendingInstallDoesNotDelayQuitOrRetryAfterQuitFailure() async throws {
        let gateway = QuitGateway()
        let coordinator = makeCoordinator(gateway)
        let lifetime = DirectForegroundLifetime()
        lifetime.register(coordinator)
        defer { coordinator.stop() }
        let installStarted = expectation(description: "Long install is pending")
        var pendingInstall: CheckedContinuation<AgentSnapshot, Error>?
        gateway.handler = { _ in
            try await withCheckedThrowingContinuation { pendingInstall = $0; installStarted.fulfill() }
        }
        let install = Task { try await coordinator.installCatalogRelease(Self.install) }
        await fulfillment(of: [installStarted], timeout: 1)
        let quitStarted = expectation(description: "Quit does not await the install")
        let quitFailed = expectation(description: "Quit failure resumes admission")
        var pendingQuit: CheckedContinuation<Void, Error>?
        let delegate = WALIDirectApplicationDelegate(lifetime: lifetime, quitAgent: {
            try await withCheckedThrowingContinuation { pendingQuit = $0; quitStarted.fulfill() }
        }, reply: { permit in XCTAssertFalse(permit); quitFailed.fulfill() }, reportFailure: { _ in })
        XCTAssertEqual(delegate.requestQuit(), .terminateLater)
        await fulfillment(of: [quitStarted], timeout: 1)
        do { try await coordinator.installCatalogRelease(Self.install); XCTFail("Quit must close install admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await coordinator.updateCatalogSecurityState(try Self.security()); XCTFail("Quit must close security admission") }
        catch { XCTAssertTrue(error is CancellationError) }
        pendingQuit?.resume(throwing: AgentConnectionError.timedOut)
        await fulfillment(of: [quitFailed], timeout: 1)
        pendingInstall?.resume(throwing: AgentFailure(code: .staleRevision, message: "Late reply"))
        do { try await install.value; XCTFail("Old request must stay cancelled after admission resumes") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gateway.commands, ["install"], "No snapshot retry may reconnect the service")
    }

    func testLateTrustTransitionCannotIssueRevocationsAfterQuitFailure() async throws {
        let gateway = QuitGateway()
        let coordinator = makeCoordinator(gateway)
        defer { coordinator.stop() }
        let lifetime = DirectForegroundLifetime()
        lifetime.register(coordinator)
        let transitionStarted = expectation(description: "Trust transition is pending")
        var pending: CheckedContinuation<AgentSnapshot, Error>?
        gateway.handler = { _ in
            try await withCheckedThrowingContinuation { pending = $0; transitionStarted.fulfill() }
        }
        let update = Task { try await coordinator.updateCatalogSecurityState(try Self.security()) }
        await fulfillment(of: [transitionStarted], timeout: 1)
        lifetime.beginQuit()
        lifetime.cancelQuit()
        pending?.resume(returning: AgentSnapshot(revision: .init(rawValue: 5)))
        do { try await update.value; XCTFail("Old security sequence must stay cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gateway.commands, ["trust"])
    }

    func testLateSnapshotDoesNotRestartPollingAfterAcknowledgedQuit() async throws {
        let gateway = QuitGateway()
        let coordinator = makeCoordinator(gateway, interval: .milliseconds(1))
        defer { coordinator.stop() }
        let lifetime = DirectForegroundLifetime()
        lifetime.register(coordinator)
        let started = expectation(description: "Snapshot is pending")
        var pending: CheckedContinuation<AgentSnapshot, Error>?
        gateway.handler = { _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        coordinator.windowDidAppear(UUID())
        await fulfillment(of: [started], timeout: 1)
        let quit = expectation(description: "Quit completes without waiting for snapshot")
        let delegate = WALIDirectApplicationDelegate(lifetime: lifetime, quitAgent: {}, reply: { permit in
            XCTAssertTrue(permit); quit.fulfill()
        }, reportFailure: { _ in XCTFail("Unexpected failure") })
        XCTAssertEqual(delegate.requestQuit(), .terminateLater)
        await fulfillment(of: [quit], timeout: 1)
        let noReconnect = expectation(description: "No new request after late reply")
        noReconnect.isInverted = true
        gateway.nextRequest = noReconnect
        gateway.handler = nil
        pending?.resume(returning: AgentSnapshot(revision: .init(rawValue: 9)))
        await fulfillment(of: [noReconnect], timeout: 0.05)
        XCTAssertEqual(gateway.commands, ["snapshot"])
    }

    private func makeCoordinator(_ gateway: QuitGateway, interval: Duration = .seconds(3_600)) -> WALIAppCoordinator {
        WALIAppCoordinator(
            connection: gateway,
            lifecycle: AgentLifecycleController(registrations: [], defaults: .standard, requiresExplicitConsent: false),
            snapshotInterval: interval
        )
    }

    private static var install: PreparedCatalogInstall {
        PreparedCatalogInstall(canonicalManifest: Data(), canonicalMetadata: Data(), signatureBase64URL: "test",
                               keyID: "test", quarantineReference: UUID(), manifestDigest: "test",
                               wallpaperID: "test", releaseID: "test", edition: 1)
    }

    private static func security() throws -> CatalogSecuritySnapshot {
        let document = CatalogSignedDocument(revision: 1, canonicalBody: Data(), signatureBase64URL: "test", keyID: "test")
        return CatalogSecuritySnapshot(trustTransition: document, revocations: document, trustedKeys: [],
            revocationList: try CatalogRevocationList(schema: .current, keyID: CatalogKeyID("test"), revision: 1,
                                                     issuedAt: Date(), revocations: []))
    }
}

@MainActor
final class DirectAgentInactivityTests: XCTestCase {
    func testKnownInactiveAgentQuitsWithoutContactingOrRegisteringServices() async throws {
        for status in [SMAppService.Status.notRegistered, .notFound, .requiresApproval] {
            let agent = QuitRegistration(status: status), helper = QuitRegistration(status: .enabled)
            let lifecycle = makeLifecycle([agent, helper])
            let lifetime = DirectForegroundLifetime()
            let replied = expectation(description: "Inactive foreground quits")
            var requests = 0
            let delegate = WALIDirectApplicationDelegate(lifetime: lifetime, quitAgent: {
                if try lifetime.canQuitWithoutAgent(using: lifecycle) { return }
                requests += 1
            }, reply: { permit in XCTAssertTrue(permit); replied.fulfill() }, reportFailure: { _ in XCTFail("Unexpected failure") })
            XCTAssertEqual(delegate.requestQuit(), .terminateLater)
            await fulfillment(of: [replied], timeout: 1)
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(agent.registrations + helper.registrations, 0)
            XCTAssertEqual(helper.status, .enabled)
        }
    }

    func testUnknownRunningPreviouslyActiveAndHelperOnlyApprovalRequireAgentQuit() throws {
        let agent = QuitRegistration(status: .enabled), helper = QuitRegistration(status: .requiresApproval)
        let lifecycle = makeLifecycle([agent, helper])
        XCTAssertTrue(lifecycle.requiresApproval)
        XCTAssertFalse(lifecycle.canQuitWithoutAgent, "Helper approval cannot bypass a running agent")
        agent.status = .notRegistered
        XCTAssertFalse(lifecycle.canQuitWithoutAgent, "Previously enabled service cannot become an assumed successful Quit")
        let running = makeLifecycle([QuitRegistration(status: .requiresApproval)], running: ["test.agent"])
        XCTAssertFalse(running.canQuitWithoutAgent)
        XCTAssertFalse(makeLifecycle(nil).canQuitWithoutAgent)
        XCTAssertFalse(AgentLifecycleController(registrations: [agent], defaults: .standard,
            requiresExplicitConsent: false).canQuitWithoutAgent)
    }

    func testPendingReinstallFailsQuitPromptlyAndCancellationCannotContinueRegistration() async throws {
        let agent = QuitRegistration(status: .enabled), helper = QuitRegistration(status: .enabled)
        let lifecycle = makeLifecycle([agent, helper])
        let unregisterStarted = expectation(description: "Native unregister is pending")
        var pending: CheckedContinuation<Void, Never>?
        agent.unregisterAction = { await withCheckedContinuation { pending = $0; unregisterStarted.fulfill() } }
        let reinstall = Task { try await lifecycle.reinstallAgent() }
        await fulfillment(of: [unregisterStarted], timeout: 1)
        reinstall.cancel()
        let lifetime = DirectForegroundLifetime()
        XCTAssertThrowsError(try lifetime.canQuitWithoutAgent(using: lifecycle)) {
            guard case AgentLifecycleError.operationInProgress = $0 else { return XCTFail("Expected in-progress failure") }
        }
        XCTAssertThrowsError(try lifecycle.ensureRunning())
        pending?.resume()
        do { try await reinstall.value; XCTFail("Cancelled reinstall must not continue") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(lifecycle.isReinstalling)
        XCTAssertEqual(agent.registrations, 0)
        XCTAssertEqual(helper.unregistrations, 0)
        XCTAssertEqual(helper.registrations, 0)
    }

    func testFailedQuitDefersVisibleResumeUntilNativeReinstallCompletes() async throws {
        for closesWindow in [false, true] {
            let agent = QuitRegistration(status: .enabled), helper = QuitRegistration(status: .enabled)
            let lifecycle = makeLifecycle([agent, helper])
            let gateway = QuitGateway()
            let coordinator = WALIAppCoordinator(connection: gateway, lifecycle: lifecycle, snapshotInterval: .seconds(3_600))
            defer { coordinator.stop() }
            let lifetime = DirectForegroundLifetime()
            lifetime.register(coordinator)
            let unregisterStarted = expectation(description: "Native unregister is pending")
            var pending: CheckedContinuation<Void, Never>?
            agent.unregisterAction = { await withCheckedContinuation { pending = $0; unregisterStarted.fulfill() } }
            let reinstall = Task { try await lifecycle.reinstallAgent() }
            await fulfillment(of: [unregisterStarted], timeout: 1)
            let window = UUID()
            coordinator.windowDidAppear(window)
            lifetime.beginQuit()
            reinstall.cancel()
            XCTAssertThrowsError(try lifetime.canQuitWithoutAgent(using: lifecycle))
            lifetime.cancelQuit()
            XCTAssertNotNil(lifecycle.onReinstallCompleted)
            XCTAssertTrue(gateway.commands.isEmpty)
            if closesWindow { coordinator.windowDidDisappear(window) }
            let resumed = expectation(description: "Open window resumes after setup cancellation")
            resumed.isInverted = closesWindow
            gateway.nextRequest = resumed
            pending?.resume()
            do { try await reinstall.value; XCTFail("Reinstall should be cancelled") } catch {}
            await fulfillment(of: [resumed], timeout: closesWindow ? 0.05 : 1)
            XCTAssertEqual(agent.registrations, closesWindow ? 0 : 1)
            XCTAssertEqual(helper.unregistrations, 0)
            XCTAssertEqual(helper.registrations, 0)
        }
    }

    private func makeLifecycle(_ registrations: [any AgentServiceRegistration]?, running: Set<String> = []) -> AgentLifecycleController {
        AgentLifecycleController(registrations: registrations, defaults: .standard, requiresExplicitConsent: false,
                                 expectedAgentIdentifier: "test.agent", runningAgentIdentifiers: { running })
    }
}

@MainActor
private final class QuitGateway: AgentGateway {
    var isConnected = true
    var commands: [String] = []
    var invalidations = 0
    var nextRequest: XCTestExpectation?
    var handler: (@MainActor (AgentCommand) async throws -> AgentSnapshot)?
    func send(_ command: AgentCommand, expectedRevision: EngineRevision?, idempotencyKey: UUID) async throws -> AgentSnapshot {
        let label: String = switch command {
        case .snapshot: "snapshot"
        case .installCatalogRelease: "install"
        case .updateCatalogTrustTransition: "trust"
        case .updateCatalogRevocations: "revocations"
        default: "action"
        }
        commands.append(label)
        let requested = nextRequest
        nextRequest = nil
        requested?.fulfill()
        if let handler { return try await handler(command) }
        return AgentSnapshot(revision: .init(rawValue: 1))
    }
    func invalidate() { invalidations += 1; isConnected = false }
}

@MainActor
private final class QuitRegistration: AgentServiceRegistration {
    var status: SMAppService.Status
    var registrations = 0
    var unregistrations = 0
    var unregisterAction: (@MainActor () async -> Void)?
    init(status: SMAppService.Status) { self.status = status }
    func register() throws { registrations += 1; status = .enabled }
    func unregister() async throws {
        unregistrations += 1
        await unregisterAction?()
        status = .notRegistered
    }
}
#endif
