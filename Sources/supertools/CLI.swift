import Foundation
import SuperToolsControl

public struct CLIInvocation {
    public var request: ControlRequest?
    public var socketPath: String
    public var help: Bool
}
public enum CLIParser {
    public static let help = """
    Usage: handytoolbelt [--socket PATH] COMMAND
      schema | status
      call COMMAND [--json JSON | --file PATH | --stdin]
      config get
      config validate (--file FILE | --stdin)
      config apply (--file FILE | --stdin) --revision REV
      config undo --revision REV
      display text TEXT [--duration SECONDS]
      display toast TEXT [--duration SECONDS]
      display progress begin TITLE --steps 'First,Second,Third'
      display progress update ID --step N --state STATE [--message TEXT]
      display progress finish ID [--failed] [--message TEXT]
      display dismiss [ID]
      automations list | run ID_OR_NAME | status RUN_ID | cancel RUN_ID
    --help shows this help. --socket PATH overrides the private local socket.
    The HandyToolbelt app must already be running. Responses are JSON.
    """ + "\n\nAll protocol commands (generic call):\n" + ControlContract.commandHelp
    public static func parse(_ arguments: [String], readFile: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }, readStdin: () throws -> Data = { FileHandle.standardInput.readDataToEndOfFile() }) throws -> CLIInvocation {
        func bad(_ message: String) -> ControlError { ControlError(code: "usage", message: message) }
        var args = arguments; var socket = ControlEndpoint.defaultPath
        if args.first == "--socket" { guard args.count > 1, !args[1].isEmpty, !args[1].hasPrefix("--") else { throw bad("--socket requires a path.") }; socket = args[1]; args.removeFirst(2) }
        if args == ["--help"] || args == ["-h"] { return CLIInvocation(request: nil, socketPath: socket, help: true) }
        guard !args.isEmpty else { throw bad("A command is required. Use --help.") }
        var cursor = 0
        func next(_ name: String) throws -> String { guard cursor < args.count, !args[cursor].isEmpty else { throw bad("Missing \(name).") }; defer { cursor += 1 }; return args[cursor] }
        let first = try next("command")
        var command = first; var parameters: JSONObject = [:]; var allowed: Set<String> = []; var flags: [String: String] = [:]; var toggles: Set<String> = []
        var inputRequired = false; var inputKey: String?
        switch first {
        case "schema", "status": break
        case "call": command = try next("command"); allowed = ["--json", "--file", "--stdin"]
        case "config":
            let sub = try next("config command"); command = "config.\(sub)"
            switch sub { case "get": break; case "validate", "apply": allowed = ["--file", "--stdin"]; inputRequired = true; inputKey = "configuration"; if sub == "apply" { allowed.insert("--revision") }; case "undo": allowed = ["--revision"]; default: throw bad("Unknown config command: \(sub).") }
        case "display":
            let sub = try next("display command"); command = "display.\(sub)"
            switch sub {
            case "text", "toast": parameters["text"] = .string(try next("text")); allowed = ["--duration"]
            case "dismiss": if cursor < args.count, !args[cursor].hasPrefix("--") { parameters["id"] = .string(try next("ID")) }
            case "progress":
                let action = try next("progress command"); command += ".\(action)"
                switch action { case "begin": parameters["title"] = .string(try next("title")); allowed = ["--steps"]; case "update": parameters["id"] = .string(try next("ID")); allowed = ["--step", "--state", "--message"]; case "finish": parameters["id"] = .string(try next("ID")); allowed = ["--failed", "--message"]; parameters["failed"] = .bool(false); default: throw bad("Unknown progress command: \(action).") }
            default: throw bad("Unknown display command: \(sub).")
            }
        case "automations":
            let sub = try next("automations command"); command = "automations.\(sub)"
            switch sub { case "list": break; case "run": parameters["automation"] = .string(try next("automation ID or name")); case "status", "cancel": parameters["id"] = .string(try next("run ID")); default: throw bad("Unknown automations command: \(sub).") }
        default: throw bad("Unknown command: \(first). Use call COMMAND for full JSON commands.")
        }
        while cursor < args.count {
            let flag = args[cursor]; cursor += 1
            guard allowed.contains(flag), flags[flag] == nil, !toggles.contains(flag) else { throw bad("Unknown, duplicate, or unexpected argument: \(flag).") }
            if flag == "--stdin" || flag == "--failed" { toggles.insert(flag) }
            else { guard cursor < args.count, !args[cursor].hasPrefix("--") else { throw bad("\(flag) requires a value.") }; flags[flag] = args[cursor]; cursor += 1 }
        }
        let inputs = [flags["--json"] != nil, flags["--file"] != nil, toggles.contains("--stdin")].filter { $0 }.count
        guard inputs <= 1, !inputRequired || inputs == 1 else { throw bad("Supply exactly one input source: --json, --file, or --stdin (as supported by the command).") }
        if inputs == 1 {
            let data: Data
            if let json = flags["--json"] { data = Data(json.utf8) } else if let file = flags["--file"] { data = try readFile(file) } else { data = try readStdin() }
            guard !data.isEmpty else { throw bad("JSON input is empty.") }
            let value: JSONValue
            do { value = try JSONDecoder().decode(JSONValue.self, from: data) } catch { throw bad("Input is not valid JSON: \(error.localizedDescription)") }
            guard let object = value.objectValue else { throw bad("JSON input must be an object.") }
            if let inputKey { parameters[inputKey] = .object(object) } else { parameters = object }
        }
        if first != "call" {
            if command == "config.apply" || command == "config.undo" { guard let revision = flags["--revision"], !revision.isEmpty else { throw bad("--revision is required.") }; parameters["expectedRevision"] = .string(revision) }
            if let value = flags["--duration"] { guard let duration = Double(value), duration.isFinite else { throw bad("--duration must be a finite number.") }; parameters["duration"] = .number(duration) }
            if command == "display.progress.begin" { guard let steps = flags["--steps"] else { throw bad("--steps is required.") }; let values = steps.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }; guard values.allSatisfy({ !$0.isEmpty }) else { throw bad("--steps must contain nonempty comma-separated labels.") }; parameters["steps"] = .array(values.map(JSONValue.string)) }
            if command == "display.progress.update" { guard let value = flags["--step"], let step = Int(value) else { throw bad("--step must be an integer (1-based).") }; guard let state = flags["--state"] else { throw bad("--state is required.") }; parameters["step"] = .number(Double(step)); parameters["state"] = .string(state) }
            if toggles.contains("--failed") { parameters["failed"] = .bool(true) }; if let message = flags["--message"] { parameters["message"] = .string(message) }
        }
        if first != "call", let known = ControlCommand(rawValue: command) {
            let errors = known.inputErrors(parameters)
            guard errors.isEmpty else { throw bad(errors.joined(separator: " ")) }
        }
        return CLIInvocation(request: ControlRequest(command: command, parameters: parameters), socketPath: socket, help: false)
    }
}
