import Darwin
import Foundation

public enum TrashBinError: Error, LocalizedError, Sendable {
    case notATrashFolder(URL)
    case unreadable
    case removalFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notATrashFolder(let url):
            String(localized: "\(url.path) is not a Trash folder.", comment: "Empty Trash refusal")
        case .unreadable:
            String(
                localized: "Tidybyte needs Full Disk Access to empty the Trash. You can also empty it in Finder.",
                comment: "Empty Trash without access")
        case .removalFailed(let name):
            String(
                localized: "Could not remove “\(name)” from the Trash.",
                comment: "Empty Trash item removal failure")
        }
    }
}

/// Permanently erases the contents of a Trash folder. This is the one
/// irreversible command in the app; callers confirm it explicitly first.
public enum TrashBin {
    public static var userTrash: URL {
        PathSafetyPolicy.realHomeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Removes every item inside `trashURL`, never the folder itself.
    /// Refuses anything that is not a real folder named `.Trash`.
    ///
    /// The folder is opened once and every deletion afterwards works relative
    /// to that open descriptor (`unlinkat`), never by re-resolving the path:
    /// a symlink swapped in at the validated path mid-operation cannot
    /// redirect this irreversible removal.
    /// - Returns: the number of items removed.
    @discardableResult
    public static func empty(trashURL: URL = userTrash) throws -> Int {
        var trashStat = stat()
        if lstat(trashURL.path, &trashStat) != 0 {
            if errno == ENOENT { return 0 }
            throw TrashBinError.unreadable
        }
        guard trashURL.lastPathComponent == ".Trash", (trashStat.st_mode & S_IFMT) == S_IFDIR else {
            throw TrashBinError.notATrashFolder(trashURL)
        }
        let fd = open(trashURL.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else {
            if errno == ENOENT { return 0 }
            throw TrashBinError.unreadable
        }
        // fdopendir adopts the descriptor on success; it stays open until closedir.
        guard let dir = fdopendir(fd) else {
            close(fd)
            throw TrashBinError.unreadable
        }
        defer { closedir(dir) }
        var stats = stat()
        guard fstat(fd, &stats) == 0, (stats.st_mode & S_IFMT) == S_IFDIR else {
            throw TrashBinError.notATrashFolder(trashURL)
        }
        return try removeEntries(in: dirfd(dir), names: collectEntryNames(from: dir))
    }

    private static func removeEntries(in directoryFD: Int32, names: [String]) throws -> Int {
        var removedCount = 0
        var failedNames: [String] = []
        for name in names {
            do {
                try removeEntry(named: name, directoryFD: directoryFD)
                removedCount += 1
            } catch TrashBinError.removalFailed(let failed) {
                failedNames.append(failed)
            } catch {
                failedNames.append(name)
            }
        }
        if !failedNames.isEmpty {
            throw TrashBinError.removalFailed(failedNames.joined(separator: ", "))
        }
        return removedCount
    }

    private static func collectEntryNames(from dir: UnsafeMutablePointer<DIR>) -> [String] {
        // Collect first, then delete: mutating the directory while readdir
        // iterates it is undefined behavior.
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = entryName(entry)
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Deletes one entry relative to an open directory descriptor, recursing
    /// into subdirectories through their own descriptors. Symlinks are
    /// unlinked, never followed.
    private static func removeEntry(named name: String, directoryFD: Int32) throws {
        try name.withCString { cName in
            var stats = stat()
            guard fstatat(directoryFD, cName, &stats, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw TrashBinError.removalFailed(name)
            }
            if (stats.st_mode & S_IFMT) == S_IFDIR {
                let childFD = openat(directoryFD, cName, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
                guard childFD >= 0 else { throw TrashBinError.removalFailed(name) }
                guard let childDir = fdopendir(childFD) else {
                    close(childFD)
                    throw TrashBinError.removalFailed(name)
                }
                // Closed on every exit path, including a failed recursion.
                defer { closedir(childDir) }
                let childDirFD = dirfd(childDir)
                _ = try removeEntries(in: childDirFD, names: collectEntryNames(from: childDir))
                guard unlinkat(directoryFD, cName, AT_REMOVEDIR) == 0 else {
                    throw TrashBinError.removalFailed(name)
                }
            } else {
                guard unlinkat(directoryFD, cName, 0) == 0 else {
                    throw TrashBinError.removalFailed(name)
                }
            }
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
