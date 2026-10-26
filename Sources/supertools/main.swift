import Foundation
import SuperToolsControl

func output(_ response: ControlResponse) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(response) { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
}
do {
    let invocation = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
    if invocation.help { print(CLIParser.help); exit(0) }
    let response = try ControlClient.request(invocation.request!, socketPath: invocation.socketPath)
    output(response)
    if !response.ok { exit(1) }
} catch {
    let error = error as? ControlError ?? ControlError(code: "input", message: error.localizedDescription)
    output(.failure(id: "", code: error.code, message: error.message))
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(error.code == "usage" || error.code == "input" ? 2 : 3)
}
