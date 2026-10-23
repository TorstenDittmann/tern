import Foundation
import Darwin

/// Local control API for coding agents: newline-delimited JSON-RPC 2.0 over a Unix socket.
/// The socket is created 0600 and every peer's uid is checked, so only processes running as
/// this user can connect. Nothing listens on a network port. Off unless the user turns it on.
@MainActor
final class AgentServer {
    static let shared = AgentServer()

    nonisolated static var socketURL: URL {
        if let path = ProcessInfo.processInfo.environment["TERN_SOCKET"] { return URL(fileURLWithPath: path) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tern/agent.sock")
    }

    /// nonisolated so `Command.title` can read it; UserDefaults is thread-safe.
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "agentAPI") }
        set { UserDefaults.standard.set(newValue, forKey: "agentAPI") }
    }

    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: AgentConnection] = [:]

    var isRunning: Bool { acceptSource != nil }
    var connectionCount: Int { connections.count }

    func start() throws {
        guard acceptSource == nil else { return }
        let url = Self.socketURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        unlink(path) // a stale socket from a previous run

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AgentError(code: -32000, message: "Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError() }
        // umask closes the window between bind() and chmod() where the socket would be world-writable.
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            let error = Self.posixError()
            Darwin.close(fd)
            throw error
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.accept(on: fd) }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            unlink(path)
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        connections.values.forEach { $0.disconnect() }
        connections.removeAll()
        acceptSource?.cancel()
        acceptSource = nil
    }

    /// Starts the server when the setting (or the smoke test) asks for it. Failure is logged, not fatal.
    func startIfEnabled() {
        guard Self.isEnabled || ProcessInfo.processInfo.environment["TERN_SOCKET"] != nil else { return }
        do { try start() } catch { NSLog("Tern agent API failed to start: \(error)") }
    }

    func toggle() {
        Self.isEnabled.toggle()
        if Self.isEnabled { startIfEnabled() } else { stop() }
    }

    private func accept(on listener: Int32) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(client)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let connection = AgentConnection(fd: client, server: self)
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }

    fileprivate func connectionDidClose(_ connection: AgentConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// One connected client. Reads lines on the main queue, writes replies on its own queue so a
/// slow reader never blocks the UI.
@MainActor
final class AgentConnection {
    private let fd: Int32
    private weak var server: AgentServer?
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private let writer = DispatchQueue(label: "dev.tern.agent.write")
    private static let maxLine = 16 << 20

    init(fd: Int32, server: AgentServer) {
        self.fd = fd
        self.server = server
    }

    func start() {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        let fd = fd, writer = writer
        // Close on the writer queue so a reply still being written never hits a reused descriptor.
        source.setCancelHandler { writer.async { Darwin.close(fd) } }
        source.resume()
        self.source = source
    }

    func disconnect() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        server?.connectionDidClose(self)
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n < 0, errno == EAGAIN || errno == EINTR { break }
            return disconnect() // 0 = peer closed, anything else = error
        }

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
            Task { @MainActor [weak self] in
                if let reply = await AgentRPC.handle(line) { self?.send(reply) }
            }
        }
        if buffer.count > Self.maxLine { disconnect() }
    }

    func send(_ message: Data) {
        guard source != nil else { return }
        var out = message
        out.append(0x0A)
        let fd = fd
        writer.async {
            out.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EAGAIN || errno == EINTR { usleep(1000); continue }
                    return
                }
            }
        }
    }
}
