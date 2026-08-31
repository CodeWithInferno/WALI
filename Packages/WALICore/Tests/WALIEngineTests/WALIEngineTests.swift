import Testing
@testable import WALIEngine

@Test("WALIEngine package marker proves its model dependency")
func engineModuleIsAvailableThroughModel() {
    #expect(WALIEngineModule.name == "WALIEngine")
    #expect(WALIEngineModule.modelModuleName == "WALIModel")
}
