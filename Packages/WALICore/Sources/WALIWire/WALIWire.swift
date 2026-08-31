import WALIModel

/// Metadata that confirms the WALI wire module is available.
package enum WALIWireModule {
    /// The stable module name used by scaffold verification.
    package static let name = "WALIWire"

    /// The model module linked by this transport-neutral wire module.
    package static let modelModuleName = WALIModelModule.name
}
