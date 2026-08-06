import Foundation

/// Entry point. Normally launches the SwiftUI app; the `--probe` and `--scan`
/// flags run the scan engine headless, which is how the engine gets verified
/// against `du`/`df` without going through the UI.
@main
struct Main {
    @MainActor
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())

        // Ignore the argument Xcode/LLDB injects when launching.
        args.removeAll { $0 == "-NSDocumentRevisionsDebugMode" || $0 == "YES" }

        switch args.first {
        case "--probe":
            CLI.probe(path: args.count > 1 ? args[1] : ".")
        case "--scan":
            CLI.scan(path: args.count > 1 ? args[1] : NSHomeDirectory())
        case "--treemap":
            CLI.renderTreemap(arguments: Array(args.dropFirst()))
        case "--uishot":
            UIShot.run(arguments: Array(args.dropFirst()))
        case "--selftest":
            SelfTest.run()
        case "--help", "-h":
            CLI.usage()
        case "--version":
            print("Wizzzee \(AppInfo.version)")
        default:
            WizzzeeApp.main()
        }
    }
}
