import Foundation

public enum GuestRPCError: Error, Equatable {
    /// The guest answered with a refusal. The agent refuses only before spawning anything.
    case refused(String?)
    /// No answer: the request may or may not have reached the guest.
    case unreachable(String)
}

/// The guest agent's RPC (`/ready`, `/bind`, `/execute`, `/cancel`, `/revoke`, `/notify`).
public protocol GuestRPC: AnyObject {
    func call(_ route: String, _ body: [String: Any]?) throws -> [String: Any]
}
