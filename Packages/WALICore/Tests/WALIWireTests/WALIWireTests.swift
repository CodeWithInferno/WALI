import Testing
@testable import WALIWire

@Test("WALIWire package marker proves its model dependency")
func wireModuleIsAvailableThroughModel() {
    #expect(WALIWireModule.name == "WALIWire")
    #expect(WALIWireModule.modelModuleName == "WALIModel")
}
