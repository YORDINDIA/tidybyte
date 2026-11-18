import Darwin
import Foundation

struct FinderTagHelper {
    private static let tagXattrKey = "com.apple.metadata:_kMDItemUserTags"

    /// Reads raw Finder tag strings (including color suffixes such as `Red\n6`)
    /// from the file's extended attribute without following symlinks.
    static func read(from url: URL) throws -> [String] {
        try rejectSymlinkedParents(of: url.path)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw failure(Darwin.errno) }
        if (info.st_mode & S_IFMT) == S_IFLNK { throw failure(ELOOP) }
        let size = getxattr(url.path, tagXattrKey, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if Darwin.errno == ENOATTR { return [] }
            throw failure(Darwin.errno)
        }
        guard size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        let bytesRead = getxattr(url.path, tagXattrKey, &buffer, size, 0, XATTR_NOFOLLOW)
        guard bytesRead >= 0 else {
            if Darwin.errno == ENOATTR { return [] }
            throw failure(Darwin.errno)
        }
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(buffer.prefix(bytesRead)), format: nil
        ) as? [String] else {
            return []
        }
        return plist
    }

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
            return fsetxattr(descriptor, tagXattrKey, baseAddress, buffer.count, 0, 0)
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
            return CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The item is a symbolic link and was not tagged.",
                        comment: "Finder tag symlink error"
                    )
                ]
            )
        default:
            let message = "setxattr failed with errno \(err): \(String(cString: strerror(err)))"
            return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
