import Foundation
import Testing
@testable import WALIWire

@Test func storeGrantRejectsEmptyOversizedAndUnknownRevision() throws {
    #expect(throws: (any Error).self) { try StoreImportGrantCodec.encode(StoreImportGrant(bookmark: Data())) }
    #expect(throws: (any Error).self) { try StoreImportGrantCodec.encode(StoreImportGrant(bookmark: Data(repeating: 1, count: StoreImportGrant.maximumBookmarkBytes + 1))) }
    let unknown = StoreImportGrant(messageVersion: 99, bookmark: Data([1]))
    #expect(throws: (any Error).self) { try StoreImportGrantCodec.encode(unknown) }
    let valid = StoreImportGrant(bookmark: Data([1, 2, 3]))
    #expect(try StoreImportGrantCodec.decode(from: StoreImportGrantCodec.encode(valid)) == valid)
}

@Test func storeWorkerRequiresAnExactAttemptAndBothBoundedGrants() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let base = TranscoderRequest(jobID: id, attemptGeneration: 2, sourceBookmark: Data([1]), sourceURL: URL(fileURLWithPath: "/source.mov"), stagingDirectoryURL: URL(fileURLWithPath: "/staging/00000000-0000-0000-0000-000000000001-2"))
    let request = StoreTranscoderRequest(request: base, stagingBookmark: Data([2]))
    #expect(try StoreTranscoderWireCodec.decodeRequest(from: StoreTranscoderWireCodec.encodeRequest(request)) == request)
    #expect(throws: (any Error).self) { try StoreTranscoderWireCodec.encodeRequest(StoreTranscoderRequest(request: base, stagingBookmark: Data())) }
    #expect(throws: (any Error).self) { try StoreTranscoderWireCodec.encodeRequest(StoreTranscoderRequest(messageVersion: 1, request: base, stagingBookmark: Data([2]))) }
    #expect(throws: (any Error).self) { try StoreTranscoderWireCodec.decodeRequest(from: TranscoderWireCodec.encodeRequest(base)) }
}

@Test func storeHandshakeIsBoundedAndRejectsOldPeerRevision() throws {
    let handshake = StoreWorkerHandshake()
    #expect(try StoreTranscoderWireCodec.decodeHandshake(from: StoreTranscoderWireCodec.encodeHandshake(handshake)) == handshake)
    #expect(throws: (any Error).self) { try StoreTranscoderWireCodec.encodeHandshake(StoreWorkerHandshake(messageVersion: 1)) }
    #expect(throws: (any Error).self) { try StoreTranscoderWireCodec.decodeHandshake(from: Data(repeating: 1, count: 4097)) }
    #expect(NSStringFromSelector(#selector(WALIAppLifecycleXPCProtocol.agentWillTerminate(reply:))) == "agentWillTerminateWithReply:")
}

@Test func presentationDemandIsBoundedUniqueAndHasNoCallerPath() throws {
    let id = UUID()
    let request = AgentRequest(command: .preparePresentation(itemIDs: [id]))
    #expect(try WireCodec.decodeRequest(from: WireCodec.encodeRequest(request)).command == request.command)
    for ids in [[], [id, id], (0..<33).map { _ in UUID() }] {
        #expect(throws: (any Error).self) { try WireCodec.encodeRequest(AgentRequest(command: .preparePresentation(itemIDs: ids))) }
    }
    let hostile = Data(#"{"preparePresentation":{"itemIDs":["../../Library/Objects"]}}"#.utf8)
    #expect(throws: (any Error).self) { try WireCodec.decode(AgentCommand.self, from: hostile) }
}
