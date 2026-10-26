import XCTest
import Foundation
import Darwin
@testable import SuperToolsControl
@testable import supertools

final class ControlTests: XCTestCase {
    func endpoint() throws -> String {
        let directory = "/tmp/st-test-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return directory + "/control.sock"
    }
    func testParserMappingsAndEscaping() throws {
        let text = "quote \" and \n and 🐈"
        let parsed = try CLIParser.parse(["display", "text", text, "--duration", "0.5"])
        XCTAssertEqual(parsed.request?.command, "display.text")
        XCTAssertEqual(parsed.request?.parameters["text"], .string(text))
        let data = try JSONEncoder().encode(parsed.request!)
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: data).parameters["text"], .string(text))
        let call = try CLIParser.parse(["--socket", "/tmp/test", "call", "custom", "--json", "{\"a\":[true,null,2]}"])
        XCTAssertEqual(call.socketPath, "/tmp/test"); XCTAssertEqual(call.request?.parameters["a"], .array([.bool(true), .null, .number(2)]))
        XCTAssertEqual(try CLIParser.parse(["config", "apply", "--stdin", "--revision", "r"], readStdin: { Data("{}".utf8) }).request?.parameters, ["configuration": .object([:]), "expectedRevision": .string("r")])
        XCTAssertEqual(try CLIParser.parse(["display", "progress", "update", "00000000-0000-0000-0000-000000000001", "--step", "1", "--state", "completed"]).request?.parameters["step"], .number(1))
    }
    func testGenericCallsPreserveParametersAndLeadingSocketOnly() throws {
        let parameters: JSONObject = ["configuration": .object(["example": .bool(true)]), "expectedRevision": .string("revision"), "title": .string("Title"), "steps": .array([.string("One")]), "step": .number(1), "state": .string("running")]
        let json = String(decoding: try JSONEncoder().encode(parameters), as: UTF8.self)
        for command in ["config.apply", "config.undo", "display.progress.begin", "display.progress.update"] {
            let invocation = try CLIParser.parse(["call", command, "--json", json])
            XCTAssertEqual(invocation.request?.command, command)
            XCTAssertEqual(invocation.request?.parameters, parameters)
        }
        XCTAssertEqual(try CLIParser.parse(["display", "text", "--socket"]).request?.parameters["text"], .string("--socket"))
        XCTAssertEqual(try CLIParser.parse(["--socket", "/tmp/example", "display", "text", "--socket"]).socketPath, "/tmp/example")
        XCTAssertThrowsError(try CLIParser.parse(["status", "--socket", "/tmp/example"]))
    }
    func testParserRejectsInvalidInput() {
        for args in [[], ["bogus"], ["status", "extra"], ["status", "--stdin"], ["call", "x", "--json", "[]"], ["call", "x", "--json", "{}", "--stdin"], ["config", "apply", "--stdin"], ["config", "undo"], ["display", "text", "x", "--duration", "nan"], ["display", "text", "x", "--duration", "0.1"], ["display", "progress", "update", "id", "--step", "0", "--state", "running"], ["display", "progress", "begin", "title", "--steps", "a,,b"], ["status", "--socket", "x", "--socket", "y"]] {
            XCTAssertThrowsError(try CLIParser.parse(args, readStdin: { Data() }), "\(args)")
        }
    }
    func testRoundtripConcurrentAndRestart() throws {
        let path = try endpoint()
        let server = ControlServer(socketPath: path) { request, reply in
            XCTAssertTrue(Thread.isMainThread)
            reply(.success(id: request.id, result: .object(request.parameters)))
        }
        try server.start(); try server.start(); XCTAssertTrue(server.isRunning)
        let finished = expectation(description: "requests"); finished.expectedFulfillmentCount = 6
        for index in 0..<6 {
            DispatchQueue.global().async {
                do { let response = try ControlClient.request(ControlRequest(command: "echo", parameters: ["index": .number(Double(index))]), socketPath: path); XCTAssertTrue(response.ok); XCTAssertEqual(response.result?.objectValue?["index"], .number(Double(index))) } catch { XCTFail("\(error)") }; finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 8)
        let other = ControlServer(socketPath: path) { _, _ in }
        XCTAssertThrowsError(try other.start()); XCTAssertTrue(server.isRunning)
        server.stop(); server.stop(); XCTAssertFalse(server.isRunning); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try server.start(); server.stop()
    }
    func testUnsafeEndpointAndUnavailable() throws {
        let path = try endpoint()
        XCTAssertThrowsError(try ControlClient.request(ControlRequest(command: "status"), socketPath: path))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let server = ControlServer(socketPath: path) { _, _ in }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "keep")
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp/no-such-target")
        XCTAssertThrowsError(try server.start())
        XCTAssertThrowsError(try ControlClient.request(ControlRequest(command: "status"), socketPath: path))
    }
    func rawConnect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { close(fd); throw ControlError(code: "test", message: "connect failed") }
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var tv = timeval(tv_sec: 7, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout.size(ofValue: tv)))
        return fd
    }
    func rawResponse(_ fd: Int32) throws -> ControlResponse {
        var data = Data(); var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 { if byte == 10 { break }; data.append(byte) }
        return try JSONDecoder().decode(ControlResponse.self, from: data)
    }
    func testMalformedOversizeAndIdleDeadline() throws {
        let path = try endpoint(); let server = ControlServer(socketPath: path) { _, _ in XCTFail("invalid request reached handler") }; try server.start(); defer { server.stop() }
        let done = expectation(description: "raw requests")
        DispatchQueue.global().async {
            do {
                let malformed = try self.rawConnect(path); defer { close(malformed) }; _ = "nope\n".withCString { write(malformed, $0, 5) }
                XCTAssertEqual(try self.rawResponse(malformed).error?.code, "invalidJSON")
                let oversized = try self.rawConnect(path); defer { close(oversized) }; let payload = Data(repeating: 120, count: 1_048_577)
                payload.withUnsafeBytes { raw in var offset = 0; while offset < payload.count { let n = write(oversized, raw.baseAddress!.advanced(by: offset), payload.count - offset); if n <= 0 { break }; offset += n } }
                XCTAssertEqual(try self.rawResponse(oversized).error?.code, "tooLarge")
                let idle = try self.rawConnect(path); defer { close(idle) }
                XCTAssertEqual(try self.rawResponse(idle).error?.code, "timeout")
            } catch { XCTFail("\(error)") }; done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
    func testStaleSocketAndPrivateDirectory() throws {
        let path = try endpoint(); let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        XCTAssertEqual(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        close(fd); chmod(path, 0o600)
        let server = ControlServer(socketPath: path) { _, _ in }; try server.start(); server.stop()
        chmod((path as NSString).deletingLastPathComponent, 0o755)
        XCTAssertThrowsError(try server.start())
    }
    func testClientTimeout() throws {
        let path = try endpoint(); let server = ControlServer(socketPath: path) { _, _ in }; try server.start(); defer { server.stop() }
        let done = expectation(description: "deadline")
        DispatchQueue.global().async { do { _ = try ControlClient.request(ControlRequest(command: "wait"), socketPath: path, timeout: 0.1); XCTFail("Expected timeout") } catch { XCTAssertEqual((error as? ControlError)?.code, "timeout") }; done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    func testQueuedRequestsDoNotSurviveRestartOrDeadline() throws {
        for expire in [false, true] {
            let path = try endpoint(); var calls = 0
            let server = ControlServer(socketPath: path) { request, reply in calls += 1; reply(.success(id: request.id, result: .null)) }
            try server.start()
            let sent = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do {
                    let fd = try self.rawConnect(path); defer { close(fd) }
                    var data = try JSONEncoder().encode(ControlRequest(command: "queued")); data.append(10)
                    data.withUnsafeBytes { _ = write(fd, $0.baseAddress!, data.count) }; sent.signal()
                    _ = try? self.rawResponse(fd)
                } catch { XCTFail("\(error)"); sent.signal() }
            }
            XCTAssertEqual(sent.wait(timeout: .now() + 1), .success)
            // Keep the main queue occupied while the transport queues its handler.
            Thread.sleep(forTimeInterval: expire ? 5.2 : 0.2)
            if !expire { server.stop(); try server.start() }
            let drained = expectation(description: "main queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            XCTAssertEqual(calls, 0)
            server.stop()
        }
    }

}
