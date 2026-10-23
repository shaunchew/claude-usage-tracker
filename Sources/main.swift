import AppKit
import Foundation

let args = CommandLine.arguments

// `ClaudeUsage --tap`: called from the Claude Code status line with its JSON on stdin.
// Saves only rate_limits (percentages and reset times) for the meters. Always exits 0
// and prints nothing, so it can never break the status line.
if args.contains("--tap") {
    _ = Limits.tap(input: FileHandle.standardInput.readDataToEndOfFile(), to: Config.load().resolvedLimitsFile)
    exit(0)
}

// `ClaudeUsage --dump`: print the aggregates as JSON and exit (no UI).
if args.contains("--dump") {
    let tracker = Tracker(config: Config.load())
    let t0 = Date()
    let agg = tracker.update()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try! enc.encode(agg))
    FileHandle.standardError.write(String(format: "\nparsed in %.2fs\n", Date().timeIntervalSince(t0)).data(using: .utf8)!)
    exit(0)
}

// `ClaudeUsage --calibrate 5h=40 week=22`: same as the Calibrate action, from a terminal.
if let i = args.firstIndex(of: "--calibrate") {
    var five: Double?, week: Double?
    for a in args[(i + 1)...] {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2, let v = Double(kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else { continue }
        if kv[0] == "5h" { five = v } else if kv[0] == "week" { week = v }
    }
    let tracker = Tracker(config: Config.load())
    tracker.refresh()
    let problems = tracker.calibrate(fiveHourPercent: five, weeklyPercent: week)
    let a = tracker.update()
    problems.forEach { print($0) }
    print("5-hour budget \(compact(a.fiveHour.budget)) (\(a.fiveHour.budgetLabel)), weekly budget \(compact(a.weekly.budget)) (\(a.weekly.budgetLabel))")
    exit(problems.isEmpty ? 0 : 1)
}

// `ClaudeUsage --snapshot out.png [--demo]`: render the panel offscreen to a PNG and exit.
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let demo = args.contains("--demo")
    // --hover-day N renders the trend tooltip over bar N (0 = oldest), to check its layout.
    let hover = args.firstIndex(of: "--hover-day").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
    let ok = MainActor.assumeIsolated { renderSnapshot(to: args[i + 1], demo: demo, hoverDay: hover) }
    exit(ok ? 0 : 1)
}

// One copy at a time: a login item plus a manual launch should not give two panels.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
