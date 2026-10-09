/// Named places where a durable write can be interrupted. The crash probe kills the process at one
/// of them; tests throw an injected error (ENOSPC) at one of them. Production code passes no hook.
public struct FaultPoint: Hashable, CustomStringConvertible {
    public enum Site: String, CaseIterable { case workspace, draft, checkpoint, snapshot, journal }
    /// `afterCommit` exists only for workspace writes: the journal committed, the writer not yet answered.
    public enum Stage: String, CaseIterable { case beforeTemp, halfWritten, beforeSync, beforeRename, afterRename, afterCommit }

    public let site: Site
    public let stage: Stage
    public init(_ site: Site, _ stage: Stage) { self.site = site; self.stage = stage }
    public init?(name: String) {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count == 2, let site = Site(rawValue: parts[0]), let stage = Stage(rawValue: parts[1]) else { return nil }
        self.init(site, stage)
    }
    public var description: String { "\(site.rawValue).\(stage.rawValue)" }
}

public typealias FaultHook = (FaultPoint) throws -> Void
