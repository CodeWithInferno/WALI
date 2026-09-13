import Foundation
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class AgentQuitReplyTests: XCTestCase {
    func testSuccessfulQuitRepliesBeforeCompletingTermination() async throws {
        let events = QuitReplyEvents()
        let completed = expectation(description: "Quit completion after reply")
        let endpoint = AgentServiceEndpoint(handler: { request in
            events.append("handled")
            return AgentResponse(requestID: request.requestID, result: .snapshot(.init(revision: .init(rawValue: 0))))
        }, afterQuitReply: {
            events.append("completed")
            completed.fulfill()
        })
        let request = AgentRequest(command: .quit)
        endpoint.perform(try WireCodec.encodeRequest(request)) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(try? data.map(WireCodec.decodeResponse)?.requestID, request.requestID)
            events.append("replied")
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(events.values, ["handled", "replied", "completed"])
    }

    func testFailureReplyDoesNotCompleteQuit() async throws {
        let request = AgentRequest(command: .quit)
        try await assertNoCompletion(request: request, response: .init(
            requestID: request.requestID,
            result: .failure(.init(code: .internalFailure, message: "Unable to quit"))
        ), encodingFails: false)
    }

    func testUnrelatedSuccessfulRequestDoesNotCompleteQuit() async throws {
        let request = AgentRequest(command: .snapshot)
        try await assertNoCompletion(request: request, response: .init(
            requestID: request.requestID, result: .snapshot(.init(revision: .init(rawValue: 0)))
        ), encodingFails: false)
    }

    func testMismatchedReplyDoesNotCompleteQuit() async throws {
        try await assertNoCompletion(request: .init(command: .quit), response: .init(
            requestID: UUID(), result: .snapshot(.init(revision: .init(rawValue: 0)))
        ), encodingFails: true)
    }

    func testIncompatibleReplyDoesNotCompleteQuit() async throws {
        let request = AgentRequest(command: .quit)
        try await assertNoCompletion(request: request, response: .init(
            protocolVersion: WALIProtocol.currentVersion + 1,
            requestID: request.requestID, result: .snapshot(.init(revision: .init(rawValue: 0)))
        ), encodingFails: true)
    }

    func testEncodingFailureDoesNotCompleteQuit() async throws {
        let request = AgentRequest(command: .quit)
        try await assertNoCompletion(request: request, response: .init(
            requestID: request.requestID, result: .snapshot(.init(
                revision: .init(rawValue: 0), notice: .init(
                    kind: .error, title: "Large notice",
                    message: String(repeating: "x", count: WALIProtocol.maximumMessageBytes)
                )
            ))
        ), encodingFails: true)
    }

    private func assertNoCompletion(
        request: AgentRequest,
        response: AgentResponse,
        encodingFails: Bool
    ) async throws {
        let replied = expectation(description: "Response delivered")
        let completed = expectation(description: "Quit must remain incomplete")
        completed.isInverted = true
        let endpoint = AgentServiceEndpoint(handler: { _ in response }, afterQuitReply: {
            completed.fulfill()
        })
        endpoint.perform(try WireCodec.encodeRequest(request)) { data, error in
            if encodingFails {
                XCTAssertNil(data)
                XCTAssertNotNil(error)
            } else {
                XCTAssertNotNil(data)
                XCTAssertNil(error)
            }
            replied.fulfill()
        }
        await fulfillment(of: [replied, completed], timeout: 0.1)
    }
}

private final class QuitReplyEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var values: [String] { lock.withLock { entries } }
}
