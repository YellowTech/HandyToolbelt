import Foundation
import Darwin

public enum ControlEndpoint { public static var defaultPath: String { "/tmp/supertools-\(getuid())/control.sock" } }
private let limit = 1_048_576
private func failure(_ code: String, _ message: String) -> ControlError { ControlError(code: code, message: message) }
private func checked(_ path: String, socket: Bool) throws -> stat {
    var s = stat()
    guard lstat(path, &s) == 0 else { throw failure("unavailable", "HandyToolbelt is unavailable. Open HandyToolbelt, then retry. (\(String(cString: strerror(errno))))") }
    guard s.st_uid == getuid(), (s.st_mode & S_IFMT) == (socket ? S_IFSOCK : S_IFDIR), (s.st_mode & 0o077) == 0 else { throw failure("unsafeEndpoint", "Endpoint must be owned by this user, private, and have the expected file type.") }
    return s
}
private func address(_ path: String) throws -> sockaddr_un {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw failure("invalidEndpoint", "Socket path must be absolute and contain no NUL bytes.") }
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { throw failure("invalidEndpoint", "Socket path is too long.") }
    withUnsafeMutableBytes(of: &a.sun_path) { dest in dest.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return a
}
private func socketFD() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw failure("transport", "Could not create local socket.") }
    var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    return fd
}
private func waitFD(_ fd: Int32, _ events: Int16, _ deadline: Date) throws {
    var p = pollfd(fd: fd, events: events, revents: 0)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw failure("timeout", "Local control request timed out.") }
        let n = poll(&p, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
        if n > 0 { guard p.revents & Int16(POLLNVAL) == 0 else { throw failure("transport", "Connection closed.") }; return }
        if n == 0 { throw failure("timeout", "Local control request timed out.") }
        if errno != EINTR { throw failure("transport", "Local socket I/O failed.") }
    }
}
private func connectFD(_ fd: Int32, _ path: String, deadline: Date) throws {
    var a = try address(path)
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if r != 0 {
        guard errno == EINPROGRESS else { throw failure(errno == ECONNREFUSED ? "refused" : "unavailable", "HandyToolbelt is unavailable. Open HandyToolbelt, then retry.") }
        try waitFD(fd, Int16(POLLOUT), deadline)
        var e: Int32 = 0; var length = socklen_t(MemoryLayout.size(ofValue: e)); getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &length)
        guard e == 0 else { throw failure(e == ECONNREFUSED ? "refused" : "unavailable", "HandyToolbelt is unavailable. Open HandyToolbelt, then retry.") }
    }
    var uid: uid_t = 0; var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw failure("unsafePeer", "Local control peer belongs to another user.") }
}
private func readLine(_ fd: Int32, deadline: Date) throws -> Data {
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        try waitFD(fd, Int16(POLLIN), deadline)
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { throw failure("invalidRequest", "Connection closed before a complete JSON line.") }
        if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure("transport", "Could not read request.") }
        if let newline = buffer[..<count].firstIndex(of: 10) {
            guard data.count + newline <= limit else { throw failure("tooLarge", "JSON line exceeds 1 MiB.") }
            data.append(contentsOf: buffer[..<newline]); return data
        }
        guard data.count + count <= limit else { throw failure("tooLarge", "JSON line exceeds 1 MiB.") }; data.append(contentsOf: buffer[..<count])
    }
}
private func writeLine<T: Encodable>(_ value: T, fd: Int32, deadline: Date) throws {
    var data = try JSONEncoder().encode(value)
    guard data.count <= limit else { throw failure("tooLarge", "JSON line exceeds 1 MiB.") }; data.append(10)
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < data.count {
            try waitFD(fd, Int16(POLLOUT), deadline)
            let n = write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure("transport", "Could not write response.") }
            guard n > 0 else { throw failure("transport", "Connection closed.") }; offset += n
        }
    }
}
public enum ControlClient {
    public static func request(_ request: ControlRequest, socketPath: String = ControlEndpoint.defaultPath, timeout: Double = 5) throws -> ControlResponse {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw failure("invalidTimeout", "Timeout must be between 0 and 60 seconds.") }
        _ = try checked((socketPath as NSString).deletingLastPathComponent, socket: false); _ = try checked(socketPath, socket: true)
        let fd = try socketFD(); defer { close(fd) }; let deadline = Date().addingTimeInterval(timeout)
        try connectFD(fd, socketPath, deadline: deadline); try writeLine(request, fd: fd, deadline: deadline)
        let response = try JSONDecoder().decode(ControlResponse.self, from: readLine(fd, deadline: deadline))
        guard response.id == request.id else { throw failure("invalidResponse", "Response ID does not match request.") }; return response
    }
}
public final class ControlServer {
    private let path: String
    private let handler: (ControlRequest, @escaping (ControlResponse) -> Void) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: Set<Int32> = []
    private var identity: (dev_t, ino_t)?
    private var generation = UUID()
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return listener >= 0 }
    public init(socketPath: String = ControlEndpoint.defaultPath, handler: @escaping (ControlRequest, @escaping (ControlResponse) -> Void) -> Void) { path = socketPath; self.handler = handler }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }; if listener >= 0 { return }
        let dir = (path as NSString).deletingLastPathComponent
        if mkdir(dir, 0o700) != 0 && errno != EEXIST { throw failure("unsafeEndpoint", "Cannot create private endpoint directory.") }; _ = try checked(dir, socket: false)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            let old = try checked(path, socket: true)
            let probe = try socketFD(); defer { close(probe) }
            var probeAddress = try address(path)
            let connected = withUnsafePointer(to: &probeAddress) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            // A pending connection, full backlog, or any uncertain error is not proof of staleness.
            // Never wait for the probe on the app's main thread.
            guard connected != 0, errno == ECONNREFUSED else { throw failure("alreadyRunning", "A control server is already running or its endpoint is busy.") }
            var current = stat(); guard lstat(path, &current) == 0, old.st_dev == current.st_dev, old.st_ino == current.st_ino else { throw failure("unsafeEndpoint", "Endpoint changed during stale socket check.") }
            guard unlink(path) == 0 else { throw failure("transport", "Cannot remove stale socket.") }
        } else if errno != ENOENT { throw failure("unsafeEndpoint", "Cannot inspect endpoint.") }
        var a = try address(path); let fd = try socketFD()
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(fd); throw failure("transport", "Cannot bind local control socket.") }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); unlink(path); throw failure("transport", "Cannot listen on local control socket.") }
        var s = stat()
        guard lstat(path, &s) == 0 else { close(fd); unlink(path); throw failure("transport", "Cannot inspect bound socket.") }
        identity = (s.st_dev, s.st_ino); listener = fd; generation = UUID()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }; source.setCancelHandler { close(fd) }; self.source = source; source.resume()
    }
    private func acceptClients(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }; guard listener == fd else { return }
        while true {
            let client = accept(fd, nil, nil); if client < 0 { return }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard clients.count < 8, getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            _ = fcntl(client, F_SETFL, O_NONBLOCK); var yes: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            clients.insert(client)
            let requestGeneration = generation
            DispatchQueue.global(qos: .utility).async { self.serve(client, generation: requestGeneration) }
        }
    }
    private func serve(_ fd: Int32, generation requestGeneration: UUID) {
        defer { lock.lock(); clients.remove(fd); close(fd); lock.unlock() }
        let deadline = Date().addingTimeInterval(5)
        do {
            let request: ControlRequest
            do { request = try JSONDecoder().decode(ControlRequest.self, from: readLine(fd, deadline: deadline)) }
            catch { let e = error as? ControlError; try? writeLine(ControlResponse.failure(id: "", code: e?.code ?? "invalidJSON", message: e?.message ?? "Expected a valid control request JSON object."), fd: fd, deadline: Date().addingTimeInterval(1)); return }
            let semaphore = DispatchSemaphore(value: 0); let replyLock = NSLock(); var response: ControlResponse?
            DispatchQueue.main.async { [weak self] in
                guard let self else { semaphore.signal(); return }
                self.lock.lock(); let active = self.listener >= 0 && self.generation == requestGeneration && deadline.timeIntervalSinceNow > 0; self.lock.unlock()
                guard active else { semaphore.signal(); return }
                self.handler(request) { value in replyLock.lock(); if response == nil { response = value; semaphore.signal() }; replyLock.unlock() }
            }
            _ = semaphore.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
            replyLock.lock(); let value = response; replyLock.unlock()
            try writeLine(value ?? .failure(id: request.id, code: "timeout", message: "Command timed out."), fd: fd, deadline: Date().addingTimeInterval(1))
        } catch { }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }; guard listener >= 0 else { return }; listener = -1; generation = UUID()
        source?.cancel(); source = nil
        for fd in clients { shutdown(fd, SHUT_RDWR) }
        var s = stat(); if let identity, lstat(path, &s) == 0, identity.0 == s.st_dev, identity.1 == s.st_ino { unlink(path) }; identity = nil
    }
    deinit { stop() }
}
