import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Reads and writes files only the user can read, so that a crash or a kill at any moment
/// leaves either the old file or the new one, never a mix (ADR-001 §6, S1).
///
/// The folder must be a real folder (not a link) owned by the user, with mode 0700, and each
/// file a regular file with mode 0600. The modes are set explicitly rather than through a
/// process-wide umask, so the services HeadsUp starts keep the user's own umask.
public enum SecureFile {
    public struct FileError: Error, Equatable, CustomStringConvertible {
        public let operation: String
        public let path: String
        public let code: Int32

        /// The raw error, for the log.
        public var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }

        /// The error in plain words, for the UI.
        public var plainWords: String { Strings.Files.plainWords(errno: code) }
    }

    /// Checks `folder` if it exists: it must be a folder, not a link, owned by the user.
    /// A folder others can read or write is narrowed to 0700. Returns false if it doesn't exist.
    @discardableResult
    public static func checkFolder(_ folder: URL) throws(FileError) -> Bool {
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw FileError(operation: "lstat", path: folder.path, code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw FileError(operation: "check", path: folder.path, code: ENOTDIR)
        }
        guard info.st_uid == getuid() else {
            throw FileError(operation: "check", path: folder.path, code: EPERM)
        }
        if info.st_mode & 0o077 != 0, chmod(folder.path, 0o700) != 0 {
            throw FileError(operation: "chmod", path: folder.path, code: errno)
        }
        return true
    }

    /// Creates `folder` with mode 0700 if it doesn't exist. Missing parents are created with
    /// the usual modes; only `folder` itself is private.
    public static func makeFolder(_ folder: URL) throws(FileError) {
        if try checkFolder(folder) { return }
        let parent = folder.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw FileError(operation: "mkdir", path: parent.path, code: Int32(underlying?.code ?? Int(EACCES)))
        }
        if mkdir(folder.path, 0o700) != 0 && errno != EEXIST {
            throw FileError(operation: "mkdir", path: folder.path, code: errno)
        }
        // mkdir's mode passes through the umask: set it exactly, and check what is there.
        if chmod(folder.path, 0o700) != 0 {
            throw FileError(operation: "chmod", path: folder.path, code: errno)
        }
        try checkFolder(folder)
    }

    /// Reads `file`, or returns nil if it doesn't exist. It must be a regular file, not a link;
    /// a file others can read is narrowed to 0600.
    public static func read(_ file: URL) throws(FileError) -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw FileError(operation: "open", path: file.path, code: errno)
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FileError(operation: "fstat", path: file.path, code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw FileError(operation: "check", path: file.path, code: EINVAL)
        }
        if info.st_mode & 0o077 != 0, fchmod(fd, 0o600) != 0 {
            throw FileError(operation: "chmod", path: file.path, code: errno)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileError(operation: "read", path: file.path, code: errno)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    /// Replaces `file` with `data` atomically, with mode 0600.
    ///
    /// The data goes to a new temporary file next to it (`O_CREAT | O_EXCL`), is flushed
    /// to disk, then renamed over `file`. On any failure the temporary file is removed and
    /// `file` is left as it was.
    public static func write(_ data: Data, to file: URL) throws(FileError) {
        let folder = file.deletingLastPathComponent()
        try makeFolder(folder)

        let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileError(operation: "open", path: temporary.path, code: errno) }

        do throws(FileError) {
            if fchmod(fd, 0o600) != 0 { throw FileError(operation: "chmod", path: temporary.path, code: errno) }
            try writeAll(data, to: fd, path: temporary.path)
            if fsync(fd) != 0 { throw FileError(operation: "fsync", path: temporary.path, code: errno) }
        } catch {
            close(fd)
            unlink(temporary.path)
            throw error
        }
        // close is called once only: after a failed close the descriptor is already released.
        if close(fd) != 0 {
            let code = errno
            unlink(temporary.path)
            throw FileError(operation: "close", path: temporary.path, code: code)
        }

        if rename(temporary.path, file.path) != 0 {
            let code = errno
            unlink(temporary.path)
            throw FileError(operation: "rename", path: file.path, code: code)
        }
        // Flush the folder too, so the rename itself survives a power loss.
        let folderFD = open(folder.path, O_RDONLY | O_CLOEXEC)
        if folderFD >= 0 {
            fsync(folderFD)
            close(folderFD)
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws(FileError) {
        let result: FileError? = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = posixWrite(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return FileError(operation: "write", path: path, code: errno)
                }
                offset += written
            }
            return nil
        }
        if let result { throw result }
    }
}

// `read` and `write` are also method names above; these reach the C functions.
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buffer, count)
}

private func posixRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(fd, buffer, count)
}
