import Foundation

/// The single, bounded Objective-C surface exported by the local agent.
@objc public protocol WALIAgentXPCProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}
