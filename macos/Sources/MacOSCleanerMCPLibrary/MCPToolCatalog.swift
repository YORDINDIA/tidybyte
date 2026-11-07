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
                ]
            )
        case .listFindings:
            MCPKit.tool(
                rawValue,
                "List findings from the last scan with their ids, summaries and reclaimable bytes.",
                [
                    "query": MCPKit.string("Filter by summary or file path substring."),
                    "limit": MCPKit.integer("How many to return (default 20).")
                ]
            )
        case .showPlan:
            MCPKit.tool(
                rawValue,
                "Show the proposed actions, optionally for one finding.",
                ["finding_id": MCPKit.string("Finding id (or its first characters) from list_findings.")]
            )
        case .checkFinding:
            MCPKit.tool(
                rawValue,
                "Re-read a finding's files from disk now: still present, still the scanned "
                    + "identity, still byte-identical. Always check before executing a stale plan.",
                ["finding_id": MCPKit.string("Finding id from list_findings.")],
                required: ["finding_id"]
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
                ]
            )
        case .history:
            MCPKit.tool(rawValue, "List recent operations that can be undone.", [:])
        case .undo:
            MCPKit.tool(
                rawValue,
                "Restore what one executed operation changed (pass its id from history). Without "
                    + "confirm: true it only describes the restore. Ask the user first.",
                [
                    "operation_log_id": MCPKit.string("Operation id from history."),
                    "confirm": MCPKit.boolean("true to actually undo; false or missing for a dry run.")
                ],
                required: ["operation_log_id"]
            )
        }
    }
}

extension MCPKit {
    static var toolDescriptions: [[String: Any]] {
        MCPCleanupTool.allCases.map(\.descriptor)
    }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
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
