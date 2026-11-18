import Foundation
import MacOSCleanerCore

enum MCPCleanupTool: String, CaseIterable {
    case scan
    case listFindings = "list_findings"
    case showPlan = "show_plan"
    case checkFinding = "check_finding"
    case execute
    case history
    case undo

    var descriptor: [String: Any] {
        switch self {
        case .scan:
            MCPKit.tool(
                rawValue,
                "Scan the Mac for cleanup opportunities (duplicate files, caches, old downloads). "
                    + "Changes nothing. Default duplicate strategy folds exact duplicates into APFS "
                    + "clones, which deletes nothing.",
                [
                    "paths": MCPKit.stringArray("Folders to scan. Omit to scan the whole home folder."),
                    "duplicate_strategy": MCPKit.string("apfs_clone (default, deletes nothing) or move_to_trash.")
                ],
                annotations: MCPKit.readOnlyAnnotations
            )
        case .listFindings:
            MCPKit.tool(
                rawValue,
                "List findings from the last scan with their ids, categories, target paths, "
                    + "summaries and reclaimable bytes.",
                [
                    "query": MCPKit.string("Filter by summary, category, or file path substring."),
                    "category": MCPKit.string("Filter by FindingCategory rawValue (e.g. duplicate, cache, developerArtifact)."),
                    "limit": MCPKit.integer("How many to return (1-200, default 20)."),
                    "offset": MCPKit.integer("Pagination offset (default 0).")
                ],
                annotations: MCPKit.readOnlyAnnotations
            )
        case .showPlan:
            MCPKit.tool(
                rawValue,
                "Show the proposed actions with target and keeper paths, optionally for one finding.",
                [
                    "finding_id": MCPKit.string("Finding id (or its first characters) from list_findings."),
                    "limit": MCPKit.integer("How many actions to return (1-200, default 20)."),
                    "offset": MCPKit.integer("Pagination offset (default 0).")
                ],
                annotations: MCPKit.readOnlyAnnotations
            )
        case .checkFinding:
            MCPKit.tool(
                rawValue,
                "Re-read a finding's files from disk now: still present, not swapped with symlinks, "
                    + "still the scanned identity, still byte-identical. Always check before executing.",
                ["finding_id": MCPKit.string("Finding id from list_findings.")],
                required: ["finding_id"],
                annotations: MCPKit.readOnlyAnnotations
            )
        case .execute:
            MCPKit.tool(
                rawValue,
                "Run proposed clone-fold actions (apfs_clone strategy — nothing is deleted) after "
                    + "the user agrees. Without confirm: true this is a dry run that only describes "
                    + "what would happen. Ask the user first, then call again with confirm: true. "
                    + "Destructive actions (move_to_trash results, package-manager cleanups) and "
                    + "high-risk actions are refused here by policy; they must be approved in the "
                    + "Tidybyte app.",
                [
                    "action_ids": MCPKit.stringArray("Action ids to run; omit for every pending clone-fold action."),
                    "confirm": MCPKit.boolean("true to actually execute; false or missing for a dry run.")
                ],
                annotations: MCPKit.mutationAnnotations
            )
        case .history:
            MCPKit.tool(
                rawValue,
                "List recent operations that can be undone.",
                [:],
                annotations: MCPKit.readOnlyAnnotations
            )
        case .undo:
            MCPKit.tool(
                rawValue,
                "Restore what one executed operation changed (pass its id from history). Without "
                    + "confirm: true it only describes the restore. Ask the user first. Operations "
                    + "that move an artifact to the Trash are refused here; undo them in the app.",
                [
                    "operation_log_id": MCPKit.string("Operation id from history."),
                    "confirm": MCPKit.boolean("true to actually undo; false or missing for a dry run.")
                ],
                required: ["operation_log_id"],
                annotations: MCPKit.mutationAnnotations
            )
        }
    }
}

enum MCPPromptCatalog {
    struct Argument: Sendable {
        var name: String
        var description: String
        var required: Bool
    }

    struct Entry: Sendable {
        var name: String
        var description: String
        var arguments: [Argument]
        var render: @Sendable ([String: String]) -> String
    }

    static let entries: [Entry] = [
        Entry(
            name: "diagnose-slowdown",
            description: "Investigate high CPU, memory pressure, thermal throttling, or runaway processes on this Mac.",
            arguments: [
                Argument(
                    name: "focus",
                    description: "Optional focus area: cpu, memory, disk, network, thermal, or all.",
                    required: false)
            ],
            render: { args in
                let focus = args["focus"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let focusNote = if let focus, !focus.isEmpty {
                    "Focus especially on \(focus)."
                } else {
                    "Cover all subsystems."
                }
                return """
                Diagnose why this Mac may be running slowly. \(focusNote)
                1. Call `monitor_hardware` and `monitor_status` to inspect CPU load, memory pressure, \
                thermal pressure, swap, GPU, sensors, and fans.
                2. Call `monitor_top` sorted by `cpu` and again sorted by `memory` to identify top consumers.
                3. For suspicious PIDs, call `monitor_inspect` to check command lines, open files, and sockets.
                4. Call `monitor_history` (`24h`) if persistent spikes occurred earlier.
                Summarize root causes and safe next steps without terminating any process directly.
                """
            }
        ),
        Entry(
            name: "review-safe-duplicates",
            description: "Scan a folder, inspect exact duplicate groups, verify hashes on disk, "
                + "and safely fold APFS clones without deleting anything.",
            arguments: [
                Argument(
                    name: "path",
                    description: "Optional folder path to scan (defaults to home folder when omitted).",
                    required: false)
            ],
            render: { args in
                let path = args["path"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let scope = if let path, !path.isEmpty {
                    "paths: [\"\(path)\"]"
                } else {
                    "the user's home folder"
                }
                return """
                Review duplicate files safely in \(scope):
                1. Call `scan` with `duplicate_strategy: "apfs_clone"`.
                2. Call `list_findings` with `category: "duplicate"` to see groups and reclaimable space.
                3. Call `show_plan` to review target and keeper paths, then call `check_finding` on each \
                group before execution.
                4. Call `execute` WITHOUT `confirm` first to show a dry run, ask the user for approval, \
                and only then call `execute` with `confirm: true`.
                """
            }
        ),
        Entry(
            name: "reclaim-dev-bloat",
            description: "Audit developer artifacts, idle dev servers, coding agent sessions, and reclaimable caches.",
            arguments: [
                Argument(
                    name: "path",
                    description: "Optional workspace directory to scan.",
                    required: false)
            ],
            render: { args in
                let path = args["path"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let scope = if let path, !path.isEmpty {
                    "on [\"\(path)\"]"
                } else {
                    "on the home folder"
                }
                return """
                Audit developer bloat and running services \(scope):
                1. Call `monitor_ports` (`idle_only: true`) and `monitor_agents` to spot idle dev servers \
                and active coding agents.
                2. Call `scan` \(scope) and inspect `list_findings` for `developerArtifact`, `cache`, \
                `packageManagerCleanup`, and `dockerCleanup`.
                3. Present reclaimable space estimates from `show_plan` and note that destructive cleanups \
                must be reviewed and approved inside the Tidybyte app.
                """
            }
        )
    ]

    static var promptDescriptions: [[String: Any]] {
        entries.map { entry in
            [
                "name": entry.name,
                "description": entry.description,
                "arguments": entry.arguments.map { arg in
                    ["name": arg.name, "description": arg.description, "required": arg.required] as [String: Any]
                }
            ]
        }
    }

    static func get(name: String, arguments: [String: String]) -> [String: Any]? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return [
            "description": entry.description,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": entry.render(arguments)
                    ]
                ]
            ]
        ]
    }
}

enum MCPResourceCatalog {
    static let monitorLiveURI = "tidybyte://monitor/live"
    static let scanSummaryURI = "tidybyte://scan/summary"

    static var resourceDescriptions: [[String: Any]] {
        var resources: [[String: Any]] = []
        #if !APP_STORE
        resources.append([
            "uri": monitorLiveURI,
            "name": "Live System Monitor Snapshot",
            "description": "Current CPU, memory pressure, thermal state, disk, network, GPU, sensors, "
                + "power, and top app telemetry as JSON.",
            "mimeType": "application/json"
        ])
        #endif
        resources.append([
            "uri": scanSummaryURI,
            "name": "Latest Scan Summary",
            "description": "Summary of the most recent cleanup scan, findings breakdown, and pending plan actions.",
            "mimeType": "application/json"
        ])
        return resources
    }
}

extension MCPKit {
    static var readOnlyAnnotations: [String: Any] {
        [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true
        ]
    }

    static var mutationAnnotations: [String: Any] {
        [
            "readOnlyHint": false,
            "destructiveHint": false,
            "idempotentHint": false
        ]
    }

    static var toolDescriptions: [[String: Any]] {
        MCPCleanupTool.allCases.map(\.descriptor)
    }

    static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String] = [],
        annotations: [String: Any] = readOnlyAnnotations
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ],
            "annotations": annotations
        ]
    }

    static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    static func stringArray(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }
}
