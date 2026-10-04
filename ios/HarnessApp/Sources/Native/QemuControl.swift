import Foundation

/// Connected Unix descriptors survive background suspension without TCP accept/reconnect.
@MainActor
final class RuntimeLineChannel {
    private let handle: FileHandle
    private var buffer = Data()
    var onLine: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = try? handle.read(upToCount: 8192)
            Task { @MainActor [weak self] in self?.receive(data ?? Data()) }
        }
    }

    func send(_ line: String) throws { try handle.write(contentsOf: Data((line + "\n").utf8)) }

    func close() {
        handle.readabilityHandler = nil
        try? handle.close()
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { close(); onClose?(); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer.prefix(upTo: newline), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            onLine?(line)
        }
        if buffer.count > 65_536 { buffer.removeAll(keepingCapacity: true) }
    }
}

@MainActor
final class QemuControl {
    static let shared = QemuControl()
    private var channel: RuntimeLineChannel?
    private var greeted = false
    private var negotiation: Task<Void, Error>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    enum Failure: Error { case unavailable, rejected }

    func attach(descriptor: Int32) {
        close()
        channel = RuntimeLineChannel(descriptor: descriptor)
        channel?.onLine = { [weak self] in self?.receive($0) }
        channel?.onClose = { [weak self] in self?.close() }
    }

    func command(_ name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        if negotiation == nil {
            negotiation = Task { [weak self] in
                guard let self else { throw Failure.unavailable }
                let deadline = Date().addingTimeInterval(4)
                while !greeted && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                guard greeted else { throw Failure.unavailable }
                _ = try await exchange("qmp_capabilities", arguments: [:])
            }
        }
        do { try await negotiation?.value }
        catch { negotiation = nil; throw error }
        return try await exchange(name, arguments: arguments)
    }

    func monitor(_ command: String) async throws -> String {
        let result = try await self.command("human-monitor-command", arguments: ["command-line": command])
        guard let value = result["return"] as? String else { throw Failure.rejected }
        return value
    }

    private func exchange(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let channel else { throw Failure.unavailable }
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["execute": name, "arguments": arguments, "id": id])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try channel.send(String(decoding: data, as: UTF8.self)) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: Failure.unavailable); return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.unavailable)
            }
        }
    }

    private func receive(_ line: String) {
        guard let packet = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        if packet["QMP"] != nil { greeted = true }
        guard let id = packet["id"] as? String, let result = pending.removeValue(forKey: id) else { return }
        if packet["error"] != nil { result.resume(throwing: Failure.rejected) }
        else { result.resume(returning: packet) }
    }

    func close() {
        channel?.close()
        channel = nil
        greeted = false
        negotiation?.cancel()
        negotiation = nil
        failPending()
    }

    private func failPending() {
        for continuation in pending.values { continuation.resume(throwing: Failure.unavailable) }
        pending.removeAll()
    }
}
