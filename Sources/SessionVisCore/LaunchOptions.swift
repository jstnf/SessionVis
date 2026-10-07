import Foundation

/// Command line: `SessionVis --dir <directory> [--replay <transcript.jsonl> [--speed <factor>]]`.
public struct LaunchOptions: Equatable, Sendable {
    public var directory: String?
    public var replayTranscript: String?
    public var speed: Double

    public init(directory: String? = nil, replayTranscript: String? = nil, speed: Double = 10) {
        self.directory = directory; self.replayTranscript = replayTranscript; self.speed = speed
    }

    /// `args` excludes the program name. Unknown flags are skipped along with a following value that does not look like a path.
    public static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--replay":
                if i + 1 < args.count { o.replayTranscript = (args[i + 1] as NSString).expandingTildeInPath; i += 1 }
            case "--dir", "-d":
                if i + 1 < args.count { o.directory = (args[i + 1] as NSString).expandingTildeInPath; i += 1 }
            case "--speed":
                if i + 1 < args.count { if let v = Double(args[i + 1]) { o.speed = v }; i += 1 }
            default:
                if a.hasPrefix("-") {
                    if i + 1 < args.count, !args[i + 1].hasPrefix("-"), !args[i + 1].hasPrefix("/"), !args[i + 1].hasPrefix("~") { i += 1 }
                } else if o.directory == nil {
                    o.directory = (a as NSString).expandingTildeInPath
                }
            }
            i += 1
        }
        return o
    }
}
