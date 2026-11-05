import Foundation
import MacOSCleanerCore
import MacOSCleanerMCPLibrary

// Tidybyte MCP server: newline-delimited JSON-RPC over stdio. Point an
// MCP client at the built binary; tools and the dry-run/confirm flow live
// in MCPKit (destructive actions are refused there by policy and must be
// approved in the app).
//
// TIDYBYTE_DB redirects the SQLite database (tests / e2e runs) so
// scripted servers never touch the user's real history.

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
    // Same fallback rule as the app bootstrap: a temporary database beats
    // refusing to start — scans still work, history is session-only.
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("tidybyte-mcp-\(UUID().uuidString).sqlite")
    kit = try MCPKit(store: SQLiteStore(databaseURL: temporary))
}

/// The request the loop is running, so a cancellation can reach it while the
/// loop is still inside that request.
actor InFlightRequest {
    private var id: String?
    private var task: Task<Data?, Never>?
    /// The reader runs ahead of the loop, so a cancellation can arrive before
    /// its request is registered. Those ids are kept here and applied by
    /// `start`; dropping them would let a cancelled request run to completion.
    /// Bounded, because an id that never starts (a client typo) must not grow
    /// this set for the life of the process.
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

    /// Cancels only the request the client named, so a late cancellation cannot
    /// hit the request that started after it.
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

/// Identity that matches a cancellation to its request: the JSON-RPC id as text.
func requestKey(_ id: Any?) -> String {
    String(describing: id ?? NSNull())
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

// readLine blocks, so it runs on its own thread and feeds the request loop
// through a stream. The loop still processes ONE request at a time (MCPKit's
// state stays serial). The reader applies cancellations as they arrive, so a
// `notifications/cancelled` aborts the in-flight request instead of waiting for
// it to finish.
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
        // Unparseable bytes — JSON-RPC "Parse error".
        MCPKit.emit(MCPKit.errorPayload(id: NSNull(), code: -32700, message: "Parse error"))
        continue
    }
    // Well-formed JSON that is not a request object (an array/scalar) is an
    // "Invalid Request" (-32600), not a parse error. MCP removed batch
    // support, so arrays are rejected outright.
    guard let object = request as? [String: Any] else {
        MCPKit.emit(MCPKit.errorPayload(id: NSNull(), code: -32600, message: "Invalid Request"))
        continue
    }
    if object["id"] == nil {
        // Notifications get no reply. Cancellations were applied by the reader.
        continue
    }
    // Serialize the response inside the task so only Sendable Data crosses
    // back; the request object is loop-local and unreachable by the reader,
    // so passing it in unchecked is sound. dataForPayload sanitizes first:
    // JSONSerialization throws for NaN readings, which aborts the server.
    nonisolated(unsafe) let requestObject = object
    let task = Task { () -> Data? in
        guard let response = await kit.handle(request: requestObject) else { return nil }
        return MCPKit.dataForPayload(response.payload)
    }
    await inFlight.start(id: requestKey(object["id"]), task: task)
    // MCP: the receiver of a cancellation stops processing and sends no
    // response for that request, so a cancelled task writes nothing.
    if let responseData = await task.value, !task.isCancelled {
        MCPKit.emitRaw(responseData)
    }
    await inFlight.finish()
}
