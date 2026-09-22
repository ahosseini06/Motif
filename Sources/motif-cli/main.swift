import Foundation
import MotifKit

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    motif-cli <command>
      selftest                      solver + optical-flow sign checks
      synth <dir>                   render the synthetic ground-truth clips
      eval <dir> [--no-depth]       score motion analysis against synthetic ground truth
      analyze <file|dir> [--no-depth] [--verbose]
                                    print segments, chips and vectors
      ingest <folder> <project.motif> [--describe] [--fake]
                                    build a project headlessly
      describe <project.motif>      run the description stage (needs GEMINI_API_KEY)
      bench <file|dir>              x-realtime per clip
      shot-test [project.motif]     designed shots → channels → search, against known moves
      search <project.motif> [--desc "…"] [--move "…"]
                                    ranked search, as the app runs it
    """)
    exit(2)
}

guard let command = args.first else { usage() }
var rest = Array(args.dropFirst())
/// Options that take a value: `--desc "a dog"`.
func option(_ name: String) -> String? {
    guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
    let value = rest[i + 1]
    rest.removeSubrange(i...(i + 1))
    return value
}
let descQuery = option("--desc"), moveQuery = option("--move")
let flags = Set(rest.filter { $0.hasPrefix("--") })
let positional = rest.filter { !$0.hasPrefix("--") }

do {
    switch command {
    case "selftest": try await Commands.selftest()
    case "synth": try await Commands.synth(dir: positional.first ?? "Eval/synth")
    case "eval": try await Commands.eval(dir: positional.first ?? "Eval/synth", useDepth: !flags.contains("--no-depth"), verbose: flags.contains("--verbose"))
    case "analyze", "bench":
        guard let path = positional.first else { usage() }
        try await Commands.analyze(path: path, useDepth: !flags.contains("--no-depth"), verbose: flags.contains("--verbose"), bench: command == "bench")
    case "ingest":
        guard positional.count == 2 else { usage() }
        try await Commands.ingest(folder: positional[0], project: positional[1], describe: flags.contains("--describe") || flags.contains("--fake"), fake: flags.contains("--fake"))
    case "describe":
        guard let project = positional.first else { usage() }
        try await Commands.describe(project: project, fake: flags.contains("--fake"))
    case "shot-test": try Commands.shotTest(project: positional.first)
    case "search":
        guard let project = positional.first else { usage() }
        try Commands.search(project: project, description: descQuery ?? "", movement: moveQuery ?? "")
    default: usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
