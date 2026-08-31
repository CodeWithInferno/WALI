import Foundation
import WALIModel
import WALIWire

final class TranscoderListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.resume()
        return true
    }
}

/// Starts the process-scoped listener for the WALI transcoder service.
public enum WALITranscoderServiceRunner {
    /// Starts the service listener and transfers control to the XPC runtime.
    public static func run() {
        let delegate = TranscoderListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}

