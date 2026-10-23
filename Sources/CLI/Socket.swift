import Foundation
import Darwin

// The Unix socket Tern's agent API listens on, shared by the one-shot CLI and `tern mcp`.

func socketPath() -> String {
    if let path = ProcessInfo.processInfo.environment["TERN_SOCKET"] { return path }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Tern/agent.sock").path
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { close(fd); return nil }
    return fd
}

/// Writes all of `data`, retrying short writes. False when the connection is gone.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

/// Reads newline-terminated messages, keeping anything after a message for the next call.
final class LineReader {
    let fd: Int32
    private var pending = Data()

    init(fd: Int32) { self.fd = fd }

    func next() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            pending.append(contentsOf: chunk[0..<n])
        }
    }
}
