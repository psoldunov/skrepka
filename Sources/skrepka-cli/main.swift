import Foundation
import SkrepkaCLI

/// The CLI's entry point, and nothing else.
///
/// Everything it does is in `SkrepkaCLI`, because a test target cannot import
/// an executable one and the argument parsing and the report rendering are
/// exactly what is worth asserting on.
exit(await CLIRunner.run(Array(CommandLine.arguments.dropFirst())))
