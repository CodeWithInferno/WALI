import Testing
@testable import WALIModel

@Test("WALIModel provides its package-only module marker")
func modelModuleIsAvailable() {
    #expect(WALIModelModule.name == "WALIModel")
}
