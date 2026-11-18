import Foundation
@testable import MacOSCleanerCore
@testable import MacOSCleanerMCPLibrary
import XCTest

private enum MCPTestSupport {
    static func makeKit() throws -> MCPKit {
        MCPKit(store: try SQLiteStore.inMemory())
    }

    static func handle(_ kit: MCPKit, _ request: sending [String: Any]) async throws -> [String: Any] {
        let response = await kit.handle(request: request)
        return try XCTUnwrap(response).payload
    }

    static func toolCall(id: String, name: String, arguments: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    }

    static func textResult(of response: [String: Any]) throws -> String {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }
}

/// MCP server dispatcher tests: the JSON-RPC contract (initialize, ping,
/// tools/list, unknown methods, notifications) and the mandatory
/// dry-run-then-confirm gating — without touching the filesystem.
final class MCPServerTests: XCTestCase {
    private func makeKit() throws -> MCPKit { try MCPTestSupport.makeKit() }
    private func handle(_ kit: MCPKit, _ request: sending [String: Any]) async throws -> [String: Any] {
        try await MCPTestSupport.handle(kit, request)
    }
    private static func toolCall(id: String, name: String, arguments: [String: Any] = [:]) -> [String: Any] {
        MCPTestSupport.toolCall(id: id, name: name, arguments: arguments)
    }
    private func textResult(of response: [String: Any]) throws -> String {
        try MCPTestSupport.textResult(of: response)
    }

    func testInitializeEchoesClientProtocolVersion() async throws {
        let kit = try makeKit()
        let response = try await handle(kit, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2024-11-05"]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "tidybyte-mcp")
        XCTAssertEqual(response["id"] as? Int, 1)
    }

    func testPingAndToolsList() async throws {
        let kit = try makeKit()
        let ping = try await handle(kit, ["jsonrpc": "2.0", "id": "p", "method": "ping"])
        XCTAssertTrue((ping["result"] as? [String: Any])?.isEmpty == true)

        let listed = try await handle(kit, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(listed["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #if APP_STORE
        let expectedNames = ["scan", "list_findings", "show_plan", "check_finding", "execute", "history", "undo"]
        XCTAssertEqual(names, expectedNames, "App Store builds expose the 7 core cleanup tools")
        XCTAssertEqual(tools.count, 7)
        #else
        let expectedNames = [
            "scan", "list_findings", "show_plan", "check_finding", "execute", "history", "undo",
            "monitor_status", "monitor_top", "monitor_ports", "monitor_agents", "monitor_limits",
            "monitor_history", "monitor_inspect", "monitor_hardware"
        ]
        XCTAssertEqual(names, expectedNames, "The 15-tool surface is part of the agent-facing contract")
        XCTAssertEqual(tools.count, 15)
        #endif

        let mutationTools: Set<String> = ["execute", "undo"]
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any], "\(name) must declare annotations")
            let readOnly = try XCTUnwrap(annotations["readOnlyHint"] as? Bool)
            let destructive = try XCTUnwrap(annotations["destructiveHint"] as? Bool)
            XCTAssertEqual(readOnly, !mutationTools.contains(name), "Unexpected readOnlyHint for \(name)")
            XCTAssertFalse(destructive, "MCP tools never perform destructive mutations directly: \(name)")
        }
    }

    func testUnknownMethodReturnsProtocolError() async throws {
        let kit = try makeKit()
        let response = try await handle(kit, ["jsonrpc": "2.0", "id": 3, "method": "unknown/method"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testResourcesListAndRead() async throws {
        let kit = try makeKit()
        let listed = try await handle(kit, ["jsonrpc": "2.0", "id": "r1", "method": "resources/list"])
        let resources = try XCTUnwrap((listed["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        let uris = resources.compactMap { $0["uri"] as? String }
        XCTAssertTrue(uris.contains("tidybyte://scan/summary"))
        #if APP_STORE
        XCTAssertFalse(uris.contains("tidybyte://monitor/live"))
        #else
        XCTAssertTrue(uris.contains("tidybyte://monitor/live"))
        #endif

        let beforeScan = try await handle(kit, [
            "jsonrpc": "2.0", "id": "r2", "method": "resources/read",
            "params": ["uri": "tidybyte://scan/summary"]
        ])
        let beforeContents = try XCTUnwrap((beforeScan["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        let beforeText = try XCTUnwrap(beforeContents.first?["text"] as? String)
        let beforeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(beforeText.utf8)) as? [String: Any])
        XCTAssertEqual(beforeJSON["status"] as? String, "no_scan")

        let (scannedKit, root) = try await scanTrashStrategyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let afterScan = try await handle(scannedKit, [
            "jsonrpc": "2.0", "id": "r3", "method": "resources/read",
            "params": ["uri": "tidybyte://scan/summary"]
        ])
        let afterContents = try XCTUnwrap((afterScan["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        let afterText = try XCTUnwrap(afterContents.first?["text"] as? String)
        let afterJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(afterText.utf8)) as? [String: Any])
        XCTAssertEqual(afterJSON["status"] as? String, "ready")
        XCTAssertEqual(afterJSON["files_count"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(afterJSON["findings_count"] as? Int ?? 0, 1)

        let liveRead = try await handle(kit, [
            "jsonrpc": "2.0", "id": "r4", "method": "resources/read",
            "params": ["uri": "tidybyte://monitor/live"]
        ])
        #if APP_STORE
        XCTAssertEqual((liveRead["error"] as? [String: Any])?["code"] as? Int, -32602)
        #else
        let liveContents = try XCTUnwrap((liveRead["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        let liveText = try XCTUnwrap(liveContents.first?["text"] as? String)
        let liveJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(liveText.utf8)) as? [String: Any])
        XCTAssertNotNil(liveJSON["cpu"])
        XCTAssertNotNil(liveJSON["memory"])
        XCTAssertNotNil(liveJSON["top_apps"])
        #endif

        let missing = try await handle(kit, [
            "jsonrpc": "2.0", "id": "r5", "method": "resources/read",
            "params": ["uri": "tidybyte://does-not-exist"]
        ])
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testPromptsListAndGet() async throws {
        let kit = try makeKit()
        let listed = try await handle(kit, ["jsonrpc": "2.0", "id": "p1", "method": "prompts/list"])
        let prompts = try XCTUnwrap((listed["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
        XCTAssertEqual(
            prompts.compactMap { $0["name"] as? String },
            ["diagnose-slowdown", "review-safe-duplicates", "reclaim-dev-bloat"]
        )

        let slowdown = try await handle(kit, [
            "jsonrpc": "2.0", "id": "p2", "method": "prompts/get",
            "params": ["name": "diagnose-slowdown", "arguments": ["focus": "thermal"]]
        ])
        let messages = try XCTUnwrap((slowdown["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        let promptText = try XCTUnwrap((messages.first?["content"] as? [String: Any])?["text"] as? String)
        XCTAssertTrue(promptText.contains("thermal"))
        XCTAssertTrue(promptText.contains("monitor_hardware"))
        XCTAssertTrue(promptText.contains("monitor_inspect"))

        let duplicates = try await handle(kit, [
            "jsonrpc": "2.0", "id": "p3", "method": "prompts/get",
            "params": ["name": "review-safe-duplicates", "arguments": ["path": "/tmp/demo"]]
        ])
        let dupMessages = try XCTUnwrap((duplicates["result"] as? [String: Any])?["messages"] as? [[String: Any]])
        let dupText = try XCTUnwrap((dupMessages.first?["content"] as? [String: Any])?["text"] as? String)
        XCTAssertTrue(dupText.contains("/tmp/demo"))
        XCTAssertTrue(dupText.contains("check_finding"))

        let unknown = try await handle(kit, [
            "jsonrpc": "2.0", "id": "p4", "method": "prompts/get",
            "params": ["name": "nonexistent-prompt"]
        ])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testNotificationProducesNoResponse() async throws {
        let kit = try makeKit()
        let response = await kit.handle(request: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(response, "Requests without an id are notifications and get no reply")
    }

    func testExecuteBeforeScanFailsAsToolError() async throws {
        let kit = try makeKit()
        let response = try await handle(kit, Self.toolCall(id: "4", name: "execute", arguments: ["confirm": true]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try textResult(of: response)
        XCTAssertTrue(text.contains("No scan"), "Agent-visible guidance expected, got: \(text)")
    }

    func testExecuteDocumentsItsConfirmGate() async throws {
        // Without a scan the call refuses to run at all — nothing can execute
        // before the user has seen a plan. The tool's own description must
        // carry the dry-run/confirm contract for the agent.
        let kit = try makeKit()
        let response = try await handle(kit, Self.toolCall(id: "5", name: "execute"))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)

        let listed = try await handle(kit, ["jsonrpc": "2.0", "id": 6, "method": "tools/list"])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let executeTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "execute" })
        let description = try XCTUnwrap(executeTool["description"] as? String)
        XCTAssertTrue(description.contains("confirm"), "execute must document its confirm gate")
    }

    // MARK: - Enforced execute policy

    /// Creates a fixture with two byte-identical files and scans it through
    /// the MCP surface with the trash duplicate strategy, producing real
    /// destructive plan actions.
    private func scanTrashStrategyFixture() async throws -> (MCPKit, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-Destructive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("duplicate contents for the destructive-policy test".utf8)
        try data.write(to: root.appendingPathComponent("one.bin"))
        try data.write(to: root.appendingPathComponent("two.bin"))
        let kit = MCPKit(store: try SQLiteStore.inMemory())
        _ = try await handle(kit, Self.toolCall(id: "s1", name: "scan", arguments: [
            "paths": [root.path], "duplicate_strategy": "move_to_trash"
        ]))
        return (kit, root)
    }

    func testShowPlanAllowsAnOmittedFindingID() async throws {
        let (kit, root) = try await scanTrashStrategyFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = try await handle(kit, ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let descriptor = try XCTUnwrap(tools.first { $0["name"] as? String == "show_plan" })
        let schema = try XCTUnwrap(descriptor["inputSchema"] as? [String: Any])
        XCTAssertFalse((schema["required"] as? [String] ?? []).contains("finding_id"))

        let response = try await handle(kit, Self.toolCall(id: "plan", name: "show_plan"))
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(try textResult(of: response).contains("proposed actions"))
    }

    func testConfirmedExecuteRefusesDestructiveActions() async throws {
        // The client-supplied confirm flag is the agent's say-so, never proof
        // a human approved: destructive actions are refused by code, and the
        // dry run still describes them so the agent can direct the user to
        // the app.
        let (kit, root) = try await scanTrashStrategyFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let dryRun = try await handle(kit, Self.toolCall(id: "e1", name: "execute"))
        XCTAssertEqual((dryRun["result"] as? [String: Any])?["isError"] as? Bool, false)
        let dryText = try textResult(of: dryRun)
        XCTAssertTrue(dryText.contains("Dry run"), "Expected a dry run, got: \(dryText)")

        let confirmed = try await handle(kit, Self.toolCall(id: "e2", name: "execute", arguments: ["confirm": true]))
        XCTAssertEqual((confirmed["result"] as? [String: Any])?["isError"] as? Bool, true)
        let text = try textResult(of: confirmed)
        XCTAssertTrue(text.contains("Tidybyte app"), "Destructive execute must be refused, got: \(text)")
    }

    func testShortUndoIDPrefixIsRejected() async throws {
        // An empty or very short id prefix would match every recorded
        // operation; the server requires the 8-character short ids it emits.
        let kit = try makeKit()
        let response = try await handle(kit, Self.toolCall(id: "u1", name: "undo", arguments: ["operation_log_id": "abc"]))
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        let text = try textResult(of: response)
        XCTAssertTrue(text.contains("8-character"), "Expected the short-id guidance, got: \(text)")
    }

    func testUnknownToolIsAProtocolError() async throws {
        let kit = try makeKit()
        let response = try await handle(kit, Self.toolCall(id: "7", name: "format_disk"))
        XCTAssertNil(response["result"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String)?.contains("Unknown tool") == true)
    }

    /// JSONSerialization raises Objective-C exceptions for NaN and infinity
    /// doubles — `try?` cannot catch those, and one non-finite monitor reading
    /// aborted the whole server. Serialization must sanitize first.
    func testPayloadWithNonFiniteNumbersSerializesWithoutCrashing() throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "result": [
                "cpu": Double.nan,
                "load": Double.infinity,
                "negative": -Double.infinity,
                "readings": [0.25, Double.nan, 1.5],
                "nested": ["usage": Double.signalingNaN],
                "fine": 3
            ]
        ]
        let data = try XCTUnwrap(MCPKit.dataForPayload(payload), "A NaN payload must serialize, not crash")
        let roundTrip = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = try XCTUnwrap(roundTrip?["result"] as? [String: Any])
        // A non-finite reading becomes JSON null, so a missing value stays visibly missing.
        XCTAssertTrue(result["cpu"] is NSNull)
        XCTAssertTrue(((result["readings"] as? [Any])?[1]) is NSNull)
        XCTAssertEqual(result["fine"] as? Int, 3)
        XCTAssertTrue((result["nested"] as? [String: Any])?["usage"] is NSNull)
    }

    /// Full round-trip of a monitor tool through the dispatcher: read-only
    /// sampling with real system readings rendered as JSON text. The NaN test
    /// above covers serialization; this covers the routing and the contract.
    func testMonitorStatusRoundTripReturnsJSONReadings() async throws {
        let kit = try makeKit()
        let response = try await handle(kit, Self.toolCall(id: "m1", name: "monitor_status"))
        #if APP_STORE
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        #else
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)
        let text = try textResult(of: response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertNotNil(json["cpu_percent"], "status must carry the headline CPU reading")
        XCTAssertNotNil(json["memory_total_bytes"])
        XCTAssertNotNil(json["uptime_seconds"])
        #endif
    }
}

final class MCPServerWave2ContractTests: XCTestCase {
    func testListFindingsAndShowPlanPaginationAndPathDetails() async throws {
        let root = try TestFixtures.makeTemporaryDirectory(named: "MCP-Pagination-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...3 {
            let payload = Data("duplicate group payload #\(index)".utf8)
            try payload.write(to: root.appendingPathComponent("group\(index)-a.bin"))
            try payload.write(to: root.appendingPathComponent("group\(index)-b.bin"))
        }

        let kit = try MCPTestSupport.makeKit()
        let scanCall = MCPTestSupport.toolCall(
            id: "pg-scan", name: "scan",
            arguments: ["paths": [root.path], "duplicate_strategy": "move_to_trash"]
        )
        let scanResponse = try await MCPTestSupport.handle(kit, scanCall)
        XCTAssertEqual((scanResponse["result"] as? [String: Any])?["isError"] as? Bool, false)

        let page1 = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "lf-1", name: "list_findings", arguments: ["category": "duplicate", "limit": 1, "offset": 0])
        )
        let page1Text = try MCPTestSupport.textResult(of: page1)
        XCTAssertTrue(page1Text.contains("3 findings (showing 1-1):"), "got: \(page1Text)")
        XCTAssertTrue(page1Text.contains("| files:"), "list_findings must show target paths: \(page1Text)")

        let page2 = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "lf-2", name: "list_findings", arguments: ["category": "duplicate", "limit": 1, "offset": 1])
        )
        let page2Text = try MCPTestSupport.textResult(of: page2)
        XCTAssertTrue(page2Text.contains("3 findings (showing 2-2):"), "got: \(page2Text)")
        XCTAssertNotEqual(page1Text, page2Text)

        let outOfRangeFindings = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "lf-99", name: "list_findings", arguments: ["category": "duplicate", "limit": 1, "offset": 99])
        )
        XCTAssertTrue(try MCPTestSupport.textResult(of: outOfRangeFindings).contains("No findings at offset 99"))

        let badLimit = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "lf-bad", name: "list_findings", arguments: ["limit": 0])
        )
        XCTAssertEqual((badLimit["result"] as? [String: Any])?["isError"] as? Bool, true)

        let plan1 = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "sp-1", name: "show_plan", arguments: ["limit": 1, "offset": 0])
        )
        let plan1Text = try MCPTestSupport.textResult(of: plan1)
        XCTAssertTrue(plan1Text.contains("proposed actions (showing 1-1):"), "got: \(plan1Text)")
        XCTAssertTrue(plan1Text.contains("| targets:"), "show_plan must show target paths: \(plan1Text)")

        let plan2 = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "sp-2", name: "show_plan", arguments: ["limit": 1, "offset": 1])
        )
        let plan2Text = try MCPTestSupport.textResult(of: plan2)
        XCTAssertTrue(plan2Text.contains("proposed actions (showing 2-2):"), "got: \(plan2Text)")
        XCTAssertNotEqual(plan1Text, plan2Text)

        let outOfRangePlan = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "sp-99", name: "show_plan", arguments: ["limit": 1, "offset": 99])
        )
        XCTAssertTrue(try MCPTestSupport.textResult(of: outOfRangePlan).contains("No plan actions at offset 99"))
    }

    func testMonitorHardwareAndHistoryTools() async throws {
        let kit = try MCPTestSupport.makeKit()

        let hardwareResp = try await MCPTestSupport.handle(kit, MCPTestSupport.toolCall(id: "hw-1", name: "monitor_hardware"))
        #if APP_STORE
        XCTAssertEqual((hardwareResp["error"] as? [String: Any])?["code"] as? Int, -32602)
        let historyResp = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "mh-ok", name: "monitor_history", arguments: ["metric": "cpu", "range": "24h"])
        )
        XCTAssertEqual((historyResp["error"] as? [String: Any])?["code"] as? Int, -32602)
        #else
        XCTAssertEqual((hardwareResp["result"] as? [String: Any])?["isError"] as? Bool, false)
        let hardwareData = Data(try MCPTestSupport.textResult(of: hardwareResp).utf8)
        let hardwareJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: hardwareData) as? [String: Any])
        for key in ["thermal_pressure", "cpu", "memory", "disk", "network", "gpu", "neural_engine",
                    "sensors", "fans", "power", "audio", "bluetooth"] {
            XCTAssertNotNil(hardwareJSON[key], "monitor_hardware missing \(key)")
        }

        let invalidHistoryArgs: [(String, [String: String])] = [
            ("mh-bad-m", ["metric": "bogus"]),
            ("mh-bad-r", ["range": "5x"]),
            ("mh-empty-app", ["app_name": "   "]),
            ("mh-bad-app-m", ["metric": "temperature", "app_name": "Finder"])
        ]
        for (id, args) in invalidHistoryArgs {
            let call: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "monitor_history", "arguments": args]
            ]
            let resp = try await MCPTestSupport.handle(kit, call)
            XCTAssertEqual((resp["result"] as? [String: Any])?["isError"] as? Bool, true, id)
        }

        let historyCall = MCPTestSupport.toolCall(id: "mh-ok", name: "monitor_history", arguments: ["metric": "cpu", "range": "24h"])
        let historyResp = try await MCPTestSupport.handle(kit, historyCall)
        XCTAssertEqual((historyResp["result"] as? [String: Any])?["isError"] as? Bool, false)
        let historyData = Data(try MCPTestSupport.textResult(of: historyResp).utf8)
        let historyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: historyData) as? [String: Any])
        XCTAssertEqual(historyJSON["metric"] as? String, "cpu")
        XCTAssertEqual(historyJSON["range"] as? String, "24h")
        XCTAssertNotNil(historyJSON["points"] as? [[String: Any]])
        #endif
    }

    func testMonitorInspectValidationAndSelfProcess() async throws {
        let kit = try MCPTestSupport.makeKit()

        let badCall = MCPTestSupport.toolCall(id: "mi-zero", name: "monitor_inspect", arguments: ["pid": 0])
        let badPID = try await MCPTestSupport.handle(kit, badCall)
        #if APP_STORE
        XCTAssertEqual((badPID["error"] as? [String: Any])?["code"] as? Int, -32602)
        #else
        XCTAssertEqual((badPID["result"] as? [String: Any])?["isError"] as? Bool, true)

        let missingCall = MCPTestSupport.toolCall(id: "mi-miss", name: "monitor_inspect", arguments: ["pid": 999_999_999])
        let missingPID = try await MCPTestSupport.handle(kit, missingCall)
        XCTAssertEqual((missingPID["result"] as? [String: Any])?["isError"] as? Bool, true)

        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        let inspectResp = try await MCPTestSupport.handle(
            kit, MCPTestSupport.toolCall(id: "mi-self", name: "monitor_inspect", arguments: ["pid": selfPID])
        )
        XCTAssertEqual((inspectResp["result"] as? [String: Any])?["isError"] as? Bool, false)
        let inspectData = Data(try MCPTestSupport.textResult(of: inspectResp).utf8)
        let inspectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: inspectData) as? [String: Any])
        XCTAssertEqual(inspectJSON["pid"] as? Int, selfPID)
        XCTAssertNotNil(inspectJSON["command_line"])
        XCTAssertNotNil(inspectJSON["open_files"])
        #endif
    }
}
