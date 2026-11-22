import Foundation
import Darwin

/// Lock a permanent sidecar inode so atomic replacement of the data file
/// cannot change the lock. Closing the descriptor (including on exit) releases it.
enum FileWriteLock {
    static func acquire(for file: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = file.path + ".flock"
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            let fd = open(path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd >= 0 { return fd }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            usleep(5_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw POSIXError(.ETIMEDOUT)
    }

    /// 写入临时文件、F_FULLFSYNC、rename，再同步父目录。
    /// 用于 config.json / history.json，避免 APFS 掉电后出现 0 字节文件。
    static func writeAtomically(_ data: Data, to file: URL, permissions: mode_t = 0o600) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".write-" + UUID().uuidString)
        var fd: Int32 = -1
        do {
            fd = open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, permissions)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if count == 0 { throw POSIXError(.EIO) }
                    written += count
                }
            }
            if fcntl(fd, F_FULLFSYNC, 0) != 0 {
                // 某些非 APFS 文件系统不支持 F_FULLFSYNC，退化为 fsync。
                guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            fd = -1
            guard rename(staging.path, file.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Best-effort directory sync: the file itself is already durable.
            let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY)
            if dirFD >= 0 {
                _ = fsync(dirFD)
                _ = close(dirFD)
            }
        } catch {
            if fd >= 0 { _ = close(fd) }
            _ = unlink(staging.path)
            throw error
        }
    }
}
