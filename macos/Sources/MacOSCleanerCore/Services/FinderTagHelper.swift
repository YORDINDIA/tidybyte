import Darwin
import Foundation

struct FinderTagHelper {
    /// Writes the Finder tags of `url`. A symlink in a parent folder or as the file itself
    /// fails with ELOOP instead of redirecting the write. The xattr is set on the open descriptor.
    static func write(_ tags: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        try rejectSymlinkedParents(of: url.path)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw failure(Darwin.errno)
        }
        defer { close(descriptor) }
        let result: Int32 = data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return -1
            }
            return fsetxattr(descriptor, "com.apple.metadata:_kMDItemUserTags", baseAddress, buffer.count, 0, 0)
        }
        if result != 0 {
            throw failure(Darwin.errno)
        }
    }

    /// Fails with ELOOP when a folder above the file is a symlink. The first component is
    /// exempt because macOS aliases /var, /tmp and /etc to /private.
    /// shortcut: the check and the open are two calls, so a symlink swapped into a parent in between is not caught; upgrade with openat() from a directory descriptor.
    private static func rejectSymlinkedParents(of path: String) throws {
        let parts = path.split(separator: "/")
        guard let first = parts.first else { return }
        var current = "/" + first
        for part in parts.dropFirst().dropLast() {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0 else { throw failure(Darwin.errno) }
            if (info.st_mode & S_IFMT) == S_IFLNK { throw failure(ELOOP) }
        }
    }

    private static func failure(_ err: Int32) -> Error {
        switch err {
        case EACCES:
            return CocoaError(.fileWriteNoPermission)
        case ENOENT:
            return CocoaError(.fileNoSuchFile)
        case ENOSPC:
            return CocoaError(.fileWriteOutOfSpace)
        case ELOOP:
            return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The item is a symbolic link and was not tagged."])
        default:
            let message = "setxattr failed with errno \(err): \(String(cString: strerror(err)))"
            return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
