import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// Everything the CLI says and everything it reads back.
///
/// Written through `FileHandle` rather than `print`, and that is a portability
/// requirement rather than a preference: flushing `print`'s buffer means
/// touching `stdout`, which on Glibc is a mutable global and is therefore not
/// concurrency-safe under Swift 6. `FileHandle` writes straight through, so a
/// line appears the moment it is produced — which matters most for the pairing
/// prompt, where the question has to be on screen before the answer is typed.
public enum CLIConsole {
    public static func say(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    /// A prompt with no trailing newline, so the cursor sits after the question.
    public static func ask(_ prompt: String) {
        FileHandle.standardOutput.write(Data(prompt.utf8))
    }

    public static func fail(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    /// A line of advice under an error — what to do about it, on stderr with
    /// the error it belongs to so a redirected stdout still carries only the
    /// command's own output.
    public static func advise(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Reads `yes` or `no` from stdin, asking again on anything else.
    ///
    /// Blocking, on purpose. A pairing confirmation is the one moment the CLI
    /// genuinely waits for the person in front of it, and there is nothing else
    /// in flight to keep running while it does.
    ///
    /// End of input — a piped stdin that ran out, a `^D` — is a refusal rather
    /// than a hang. Pairing defaults to no everywhere else for the same reason.
    public static func confirm(_ question: String) -> Bool {
        while true {
            ask("\(question) [yes/no]: ")
            guard
                let answer = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespaces).lowercased()
            else {
                say("")
                return false
            }
            switch answer {
            case "y", "yes": return true
            case "n", "no": return false
            default: say("Answer yes or no.")
            }
        }
    }
}
