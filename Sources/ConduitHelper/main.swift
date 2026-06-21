// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.first == "--daemon" {
    HelperDaemon.run()
}

if
    let commandName = rawArgs.first,
    let command = HelperCommand(rawValue: commandName)
{
    let arguments = HelperArguments(command: command, values: Array(rawArgs.dropFirst()))
    do {
        try HelperTool.run(arguments: arguments)
        exit(EXIT_SUCCESS)
    } catch {
        fputs("ConduitHelper error: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else {
    fputs("Usage: ConduitHelper <command> [args...]\n", stderr)
    fputs("       ConduitHelper --daemon\n", stderr)
    exit(EXIT_FAILURE)
}
