public extension ActionType {
    var isExecutable: Bool {
        switch self {
        case .moveToTrash, .move, .rename, .tag, .createAlias, .createSymlink, .archive,
             .runPackageManagerCleanup, .cloneDeduplicate:
            true
        case .restore, .offloadLocalCopy, .runProviderCleanup, .inspectOnly, .unfoldClone:
            false
        }
    }
}
