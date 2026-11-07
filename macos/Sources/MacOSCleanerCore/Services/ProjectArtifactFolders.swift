/// Folder names shared by project reporting and cleanup classification.
/// The rule engine still applies its project-root and safety checks.
enum ProjectArtifactFolders {
    static let projectBound: Set<String> = [
        "node_modules", ".venv", "venv", ".tox", "dist", "build", "target", ".build", ".gradle"
    ]

    static let reportable = projectBound.union([
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".vite", "coverage", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".ruff_cache", ".dart_tool", "DerivedData"
    ])
}
