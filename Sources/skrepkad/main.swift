import Foundation
import SkrepkaDaemon

/// The daemon's entry point, and nothing else.
///
/// Everything it does is in `SkrepkaDaemon`, because `swift test` cannot import
/// an executable target and a composition root with no tests is the one place a
/// wiring mistake hides longest.

let options: DaemonOptions
do {
    options = try DaemonOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("skrepkad: \(error)\n".utf8))
    FileHandle.standardOutput.write(Data((DaemonOptions.usage + "\n").utf8))
    exit(DaemonRunner.Exit.usage)
}

switch options.command {
case .help:
    FileHandle.standardOutput.write(Data((DaemonOptions.usage + "\n").utf8))
case .version:
    FileHandle.standardOutput.write(Data("skrepkad \(DaemonVersion.current)\n".utf8))
case .run:
    exit(await DaemonRunner.run(options))
}
