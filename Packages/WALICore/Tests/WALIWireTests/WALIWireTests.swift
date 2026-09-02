import Testing
import Foundation
import WALIModel
@testable import WALIWire

@Test("WALIWire package marker proves its model dependency")
func wireModuleIsAvailableThroughModel() {
    #expect(WALIWireModule.name == "WALIWire")
    #expect(WALIWireModule.modelModuleName == "WALIModel")
}

@Test("Catalog install messages carry an opaque reference and bounded signed body")
func catalogInstallWireRoundTrip() throws {
    let install = AgentCatalogInstallRequest(
        canonicalManifest: Data("{}".utf8),
        canonicalMetadata: Data("{}".utf8),
        signatureBase64URL: String(repeating: "A", count: 86),
        keyID: "catalog-root-1",
        quarantineReference: UUID()
    )
    let request = AgentRequest(command: .installCatalogRelease(install))

    let decoded = try WireCodec.decodeRequest(from: WireCodec.encodeRequest(request))
    #expect(decoded == request)
}

@Test("Catalog wire rejects oversized canonical bodies before XPC")
func catalogInstallWireRejectsOversizedBody() throws {
    let install = AgentCatalogInstallRequest(
        canonicalManifest: Data(repeating: 0, count: AgentCatalogInstallRequest.maximumManifestBytes + 1),
        canonicalMetadata: Data("{}".utf8),
        signatureBase64URL: String(repeating: "A", count: 86),
        keyID: "catalog-root-1",
        quarantineReference: UUID()
    )

    #expect(throws: WireCodecError.collectionTooLarge) {
        try WireCodec.encodeRequest(AgentRequest(command: .installCatalogRelease(install)))
    }
}
