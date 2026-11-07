/// Folder names shared by project reporting and cleanup classification.
/// The rule engine still applies its project-root and safety checks.
enum ProjectArtifactFolders {
    static let projectBound: Set<String> = [
        "node_modules", ".venv", "venv", ".tox", "dist", "build", "target", ".build", ".gradle"
    ]

    static let lowRisk: Set<String> = [
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".nuxt",
        ".turbo", ".parcel-cache", ".vite", "coverage", ".dart_tool"
    ]

    static let reportable = projectBound.union(lowRisk).union(["DerivedData"])
}
