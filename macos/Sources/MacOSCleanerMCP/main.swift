import Darwin
import Foundation
import MacOSCleanerCore
import MacOSCleanerMCPLibrary

// Tidybyte MCP server: newline-delimited JSON-RPC over stdio.
// Ignore SIGPIPE so a closed stdout pipe returns EPIPE instead of killing the process.
signal(SIGPIPE, SIG_IGN)

func makeStore() throws -> SQLiteStore {
    if let override = ProcessInfo.processInfo.environment["TIDYBYTE_DB"] {
        return try SQLiteStore(databaseURL: URL(fileURLWithPath: override))
    }
    return try SQLiteStore()
}

let kit: MCPKit
do {
    kit = try MCPKit(store: makeStore())
} catch {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("tidybyte-mcp-\(UUID().uuidString).sqlite")
    kit = try MCPKit(store: SQLiteStore(databaseURL: temporary))
}

/// The request the loop is running, so a cancellation can reach it while the
/// loop is still inside that request.
actor InFlightRequest {
    private var id: String?
    private var task: Task<Data?, Never>?
    private var earlyCancels: [String] = []
    private static let earlyCancelLimit = 16

    func start(id: String, task: Task<Data?, Never>) {
        self.id = id
        self.task = task
        if let index = earlyCancels.firstIndex(of: id) {
            earlyCancels.remove(at: index)
            task.cancel()
        }
    }

    func finish() {
        id = nil
        task = nil
    }

    func cancel(requestID: String) {
        if id == requestID {
            task?.cancel()
            return
        }
        guard !earlyCancels.contains(requestID) else { return }
        earlyCancels.append(requestID)
        if earlyCancels.count > Self.earlyCancelLimit { earlyCancels.removeFirst() }
    }
}

/// Type-tagged request key so boolean `true`/`false` never collides with integer `1`/`0`.
func requestKey(_ id: Any?) -> String {
    guard let id else { return "null" }
    if let string = id as? String { return "s:\(string)" }
    if let number = id as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return "b:\(number.boolValue)"
        }
        return "n:\(number.stringValue)"
    }
    return "o:\(String(describing: id))"
}

/// The request id a `notifications/cancelled` line names, or nil for any other line.
func cancelledRequestID(in line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["id"] == nil, (object["method"] as? String) == "notifications/cancelled",
          let requestID = (object["params"] as? [String: Any])?["requestId"], !(requestID is NSNull)
    else { return nil }
    return requestKey(requestID)
}

let inFlight = InFlightRequest()

let lines = AsyncStream<String> { continuation in
    Task.detached(priority: .userInitiated) {
        while let line = readLine(strippingNewline: true) {
            if let requestID = cancelledRequestID(in: line) {
                await inFlight.cancel(requestID: requestID)
            }
            continuation.yield(line)
        }
        continuation.finish()
    }
}

for await line in lines {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        MCPKit.emit(MCPKit.errorPayload(id: NSNull(), code: -32700, message: "Parse error"))
        continue
    }
    guard let object = request as? [String: Any] else {
        MCPKit.emit(MCPKit.errorPayload(id: NSNull(), code: -32600, message: "Invalid Request"))
        continue
    }
    if object["id"] == nil {
        continue
    }
    nonisolated(unsafe) let requestObject = object
    let task = Task { () -> Data? in
        guard let response = await kit.handle(request: requestObject) else { return nil }
        return MCPKit.dataForPayload(response.payload)
    }
    await inFlight.start(id: requestKey(object["id"]), task: task)
    if let responseData = await task.value, !task.isCancelled {
        MCPKit.emitRaw(responseData)
    }
    await inFlight.finish()
}
