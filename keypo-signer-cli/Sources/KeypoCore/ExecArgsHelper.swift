import Foundation

/// Utilities for preparing command arguments captured by swift-argument-parser.
public enum ExecArgsHelper {
    /// Strip `--` artifact from `.captureForPassthrough` and coalesce `sh -c` arguments.
    ///
    /// `.captureForPassthrough` includes `--` as the first element. After stripping it,
    /// if the command is `sh -c` or `bash -c`, remaining arguments are joined into a
    /// single command string (since `sh -c` expects one argument).
    public static func prepareExecArgs(_ args: [String]) -> [String] {
        var execArgs = args
        if execArgs.first == "--" { execArgs.removeFirst() }
        if execArgs.count > 2,
           ["sh", "bash", "/bin/sh", "/bin/bash"].contains(execArgs[0]),
           execArgs[1] == "-c" {
            execArgs = [execArgs[0], "-c", execArgs[2...].joined(separator: " ")]
        }
        return execArgs
    }
}
