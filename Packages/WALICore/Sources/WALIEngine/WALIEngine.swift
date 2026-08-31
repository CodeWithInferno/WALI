import WALIModel

/// Metadata that confirms the WALI engine module is available.
package enum WALIEngineModule {
    /// The stable module name used by scaffold verification.
    package static let name = "WALIEngine"

    /// The model module linked by this transport-neutral engine module.
    package static let modelModuleName = WALIModelModule.name
}
