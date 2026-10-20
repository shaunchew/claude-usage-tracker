// Parsing and aggregation of Claude Code session logs, plus the usage meters and their
// calibration. No UI code here, so the `--dump` mode and the tests can exercise it directly.
import Foundation

// MARK: - Config

struct Weights: Codable {
    var input = 1.0
    var output = 5.0
    var cacheWrite5m = 1.25
    var cacheWrite1h = 2.0
    var cacheRead = 0.1
}

/// Budgets in weighted tokens. Anthropic does not publish limits in tokens, so these are
/// rough starting points; calibration replaces them with figures from your own account.
struct PlanBudget: Codable {
    var fiveHour: Double
    var weekly: Double
}

struct Config: Codable {
    /// nil = $CLAUDE_CONFIG_DIR/projects if set, else ~/.claude/projects.
    var projectsDir: String? = nil
    /// Written by `ClaudeUsage --tap` from the status line. nil = <state dir>/limits.json.
    var limitsFile: String? = nil
    /// IANA zone name; nil = system zone.
    var timeZone: String? = nil
    /// 1 = Sunday ... 2 = Monday (Calendar convention). Used only until a status-line reading gives the real reset.
    var weekStartWeekday = 2
    var weekStartHour = 0
    var refreshSeconds = 60.0
    var historyDays = 35
    var weights = Weights()
    /// Substring of the model id -> multiplier, roughly following relative API prices.
    var modelMultipliers: [String: Double] = ["opus": 1.0, "sonnet": 0.6, "haiku": 0.2]
    /// Key into planBudgets: "pro", "max5x" or "max20x".
    var plan = "pro"
    var planBudgets: [String: PlanBudget] = [
        "pro": PlanBudget(fiveHour: 5e6, weekly: 50e6),
        "max5x": PlanBudget(fiveHour: 25e6, weekly: 250e6),
        "max20x": PlanBudget(fiveHour: 100e6, weekly: 1000e6),
    ]
    /// A status-line reading older than this is no longer "live".
    var liveMaxAgeMinutes = 15.0
    /// How many calibration samples are averaged per meter.
    var calibrationSamples = 5
    var alwaysOnTop = false
    var topSessions = 5

    static let path = expand(ProcessInfo.processInfo.environment["CLAUDE_USAGE_CONFIG"] ?? "~/.config/claude-usage-tracker/config.json")
    /// Holds config.json, limits.json and calibration.json.
    static var stateDir: String { (path as NSString).deletingLastPathComponent }

    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path) else { return Config() }
        // Merge the user's partial file over the defaults (one level deep for planBudgets).
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))) as? [String: Any] ?? [:]
        let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var merged = defaults.merging(user) { _, new in new }
        if let d = defaults["planBudgets"] as? [String: Any], let u = user["planBudgets"] as? [String: Any] {
            merged["planBudgets"] = d.merging(u) { _, new in new }
        }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(Config.self, from: mergedData) else {
            FileHandle.standardError.write("config: could not parse \(path), using defaults\n".data(using: .utf8)!)
            return Config()
        }
        return cfg
    }

    var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    var resolvedProjectsDir: String {
        if let p = projectsDir { return expand(p) }
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return (expand(dir) as NSString).appendingPathComponent("projects")
        }
        return expand("~/.claude/projects")
    }

    var resolvedLimitsFile: String { limitsFile.map(expand) ?? (Config.stateDir as NSString).appendingPathComponent("limits.json") }

    var planBudget: PlanBudget { planBudgets[plan] ?? planBudgets["pro"] ?? PlanBudget(fiveHour: 5e6, weekly: 50e6) }

    var planLabel: String {
        switch plan {
        case "pro": return "Pro"
        case "max5x": return "Max 5x"
        case "max20x": return "Max 20x"
        default: return plan
        }
    }

    func multiplier(for model: String) -> Double {
        let m = model.lowercased()
        return modelMultipliers.first { m.contains($0.key) }?.value ?? 1.0
    }

    func weighted(_ u: Usage, model: String) -> Double {
        // Split cache writes by TTL when the log has the breakdown; otherwise treat them as 5-minute writes.
        let w1h = Double(u.cacheWrite1h ?? 0)
        let w5m = Double(u.cache_creation_input_tokens ?? 0) - w1h
        let base = Double(u.input_tokens ?? 0) * weights.input
            + Double(u.output_tokens ?? 0) * weights.output
            + max(w5m, 0) * weights.cacheWrite5m + w1h * weights.cacheWrite1h
            + Double(u.cache_read_input_tokens ?? 0) * weights.cacheRead
        return base * multiplier(for: model)
    }
}

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// MARK: - Log line shapes

struct Usage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation: CacheCreation?
    struct CacheCreation: Decodable { var ephemeral_1h_input_tokens: Int? }
    var cacheWrite1h: Int? { cache_creation?.ephemeral_1h_input_tokens }
}

private struct LogLine: Decodable {
    var type: String?
    var timestamp: String?
    var requestId: String?
    var sessionId: String?
    var cwd: String?
    var customTitle: String?
    var aiTitle: String?
    var message: Message?
    struct Message: Decodable { var id: String?; var model: String?; var usage: Usage? }
}

// MARK: - Status-line limits (written by `--tap`)

struct Limits: Codable {
    struct Window: Codable { var used_percentage: Double?; var resets_at: Double? }
    var five_hour: Window?
    var seven_day: Window?
    var captured_at: Double?

    static func read(_ path: String) -> Limits? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Limits.self, from: data)
    }

    /// Reads the status-line JSON Claude Code passes on stdin and keeps only `rate_limits`
    /// (percentages and reset times) plus a capture time. Returns false if there were none.
    static func tap(input: Data, to path: String, now: Date = Date()) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any] else { return false }
        func window(_ k: String) -> Window? {
            guard let w = rl[k] as? [String: Any] else { return nil }
            return Window(used_percentage: (w["used_percentage"] as? NSNumber)?.doubleValue,
                          resets_at: (w["resets_at"] as? NSNumber)?.doubleValue)
        }
        let l = Limits(five_hour: window("five_hour"), seven_day: window("seven_day"), captured_at: now.timeIntervalSince1970)
        guard l.five_hour != nil || l.seven_day != nil, let data = try? JSONEncoder().encode(l) else { return false }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}

// MARK: - Calibration

/// Budgets back-solved from real percentages: typed in from /usage ("manual") or taken
/// from a status-line reading ("live"). The meter budget is the average of recent samples.
struct Calibration: Codable {
    struct Sample: Codable { var at: Date; var budget: Double; var source: String }
    var fiveHour: [Sample] = []
    var weekly: [Sample] = []
    /// captured_at of the last status-line reading used, so each reading is used once.
    var lastLiveCapture: Double?
    /// Latest weekly reset seen from the status line; rolled forward to place the week when not live.
    var weeklyReset: Double?

    static func load(_ path: String?) -> Calibration {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return Calibration() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Calibration.self, from: data)) ?? Calibration()
    }

    func save(_ path: String?) {
        guard let path else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func average(_ s: [Sample]) -> Double? { s.isEmpty ? nil : s.map(\.budget).reduce(0, +) / Double(s.count) }

    /// Adds a sample, keeping at most `keep`. Live readings arrive every few seconds while a
    /// session is busy, so a live sample less than 30 minutes after the previous live one replaces it.
    static func add(_ sample: Sample, to list: inout [Sample], keep: Int) {
        if sample.source == "live", let last = list.last, last.source == "live", sample.at.timeIntervalSince(last.at) < 1800 {
            list[list.count - 1] = sample
        } else {
            list.append(sample)
        }
        if list.count > keep { list.removeFirst(list.count - keep) }
    }
}

// MARK: - Aggregates (what the UI shows and --dump prints)

struct Totals: Codable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, messages = 0
    var weighted = 0.0
    var raw: Int { input + output + cacheWrite + cacheRead }
}

struct DayBucket: Codable { var day: String; var weighted: Double; var raw: Int }

struct SessionRow: Codable {
    var sessionId: String
    var title: String
    var project: String
    var weighted: Double
    var raw: Int
    var messages: Int
    var lastActive: Date
}

/// One usage meter: the 5-hour session window or the weekly window.
struct Meter: Codable {
    var name: String
    var source: String               // "live" (fresh status-line reading) | "estimated" (weighted ÷ budget)
    var usedPercent: Double
    var leftPercent: Double
    var windowStart: Date?
    var resetsAt: Date?              // nil when no 5-hour window is open
    var tokens: Totals               // inside the window
    var budget: Double               // weighted tokens for 100%
    var calibratedAt: Date?          // nil = plan default
    var budgetLabel: String          // "calibrated Oct 20" | "Pro default"
}

struct Forecast: Codable {
    var ratePerHour: Double          // blended weighted tokens/hour
    var hoursRemaining: Double
    var projectedWeighted: Double    // window total at the weekly reset
    var projectedPercent: Double
    var runsOutAt: Date?             // only if projected to pass 100% before the reset
}

struct Aggregates: Codable {
    var generatedAt: Date
    var timeZone: String
    var plan: String
    var fiveHour: Meter
    var weekly: Meter
    var forecast: Forecast
    var today: Totals
    var daily: [DayBucket]           // last 14 days, oldest first
    var sessions: [SessionRow]       // top this week by weighted usage
    var limits: Limits?
    var monthsUTC: [String: Totals]  // raw totals by UTC month
}

// MARK: - Tracker

private struct Event {
    var ts: Date
    var session: String
    var model: String
    var usage: Usage
    var weighted: Double
}

private struct SessionMeta { var title: String?; var cwd: String? }

/// Holds parsed events and per-file read offsets so each refresh reads only new lines.
/// Not thread-safe: call from one queue.
final class Tracker {
    let config: Config
    /// nil = keep calibration in memory only (tests).
    let calibrationPath: String?
    private(set) var calibration: Calibration
    private var offsets: [String: UInt64] = [:]
    private var events: [Event] = []
    private var seen = Set<String>()
    private var meta: [String: SessionMeta] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    init(config: Config, calibrationPath: String? = (Config.stateDir as NSString).appendingPathComponent("calibration.json")) {
        self.config = config
        self.calibrationPath = calibrationPath
        calibration = Calibration.load(calibrationPath)
    }

    /// Scan for new or grown files and parse only the appended bytes.
    func refresh(now: Date = Date()) {
        let root = URL(fileURLWithPath: config.resolvedProjectsDir)
        let cutoff = now.addingTimeInterval(-Double(config.historyDays) * 86400)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = rv.fileSize.map(UInt64.init) else { continue }
            let path = url.path
            let start = offsets[path] ?? 0
            if size == start { continue }
            if size < start { offsets[path] = 0 }  // truncated/rewritten: start over
            if offsets[path] == nil, let m = rv.contentModificationDate, m < cutoff {
                offsets[path] = size; continue  // old file: skip history, but pick up anything appended later
            }
            offsets[path] = read(path, from: offsets[path] ?? 0, cutoff: cutoff)
        }
        events.removeAll { $0.ts < cutoff }
    }

    /// Refresh, fold in any new status-line reading, and aggregate. What the app calls each tick.
    func update(now: Date = Date()) -> Aggregates {
        refresh(now: now)
        let limits = Limits.read(config.resolvedLimitsFile)
        if let limits { autoCalibrate(limits, now: now) }
        return aggregate(now: now, limits: limits)
    }

    /// Reads from `offset` in 4 MB chunks (keeps peak memory low) and returns the new offset.
    private func read(_ path: String, from offset: UInt64, cutoff: Date) -> UInt64 {
        guard let fh = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? fh.close() }
        var pos = offset
        while true {
            let consumed: Int = autoreleasepool {
                try? fh.seek(toOffset: pos)
                guard let data = try? fh.read(upToCount: 4 << 20), !data.isEmpty else { return 0 }
                if data.count == 4 << 20, data.lastIndex(of: 0x0A) == nil {
                    // A single line longer than the chunk: read it whole.
                    try? fh.seek(toOffset: pos)
                    guard let rest = try? fh.readToEnd() else { return 0 }
                    return parse(rest, path: path, cutoff: cutoff)
                }
                return parse(data, path: path, cutoff: cutoff)
            }
            if consumed == 0 { return pos }
            pos += UInt64(consumed)
        }
    }

    /// Parses complete lines in `data`; returns the number of bytes consumed. A partially
    /// written last line is left for the next read.
    private func parse(_ data: Data, path: String, cutoff: Date) -> Int {
        guard let lastNL = data.lastIndex(of: 0x0A) else { return 0 }
        let usageNeedle = Data("\"usage\"".utf8)
        let titleNeedle = Data("-title\"".utf8)
        let decoder = JSONDecoder()
        var lineStart = data.startIndex
        while lineStart <= lastNL {
            let nl = data[lineStart...lastNL].firstIndex(of: 0x0A) ?? lastNL
            let line = data[lineStart..<nl]
            lineStart = nl + 1
            let hasUsage = line.range(of: usageNeedle) != nil
            guard hasUsage || line.range(of: titleNeedle) != nil,
                  let d = try? decoder.decode(LogLine.self, from: line) else { continue }
            if let sid = d.sessionId {
                if let t = d.customTitle { meta[sid, default: .init()].title = t }
                else if let t = d.aiTitle, meta[sid]?.title == nil { meta[sid, default: .init()].title = t }
                if let c = d.cwd { meta[sid, default: .init()].cwd = c }
            }
            guard hasUsage, let m = d.message, let u = m.usage, let tsStr = d.timestamp,
                  let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr), ts >= cutoff else { continue }
            // Same message is logged on several lines (one per content block): count it once.
            let key = "\(m.id ?? "")|\(d.requestId ?? "")"
            guard seen.insert(key).inserted else { continue }
            let model = m.model ?? ""
            let sid = d.sessionId ?? (path as NSString).lastPathComponent
            events.append(Event(ts: ts, session: sid, model: model, usage: u, weighted: config.weighted(u, model: model)))
        }
        return lastNL - data.startIndex + 1
    }

    // MARK: Windows

    private func totals(from start: Date, to end: Date) -> Totals {
        var t = Totals()
        for e in events where e.ts >= start && e.ts <= end { add(&t, e) }
        return t
    }

    private func add(_ t: inout Totals, _ e: Event) {
        t.input += e.usage.input_tokens ?? 0; t.output += e.usage.output_tokens ?? 0
        t.cacheWrite += e.usage.cache_creation_input_tokens ?? 0; t.cacheRead += e.usage.cache_read_input_tokens ?? 0
        t.messages += 1; t.weighted += e.weighted
    }

    /// The 5-hour window as Claude Code runs it: opens at the first message after the previous
    /// window closed (start rounded down to the hour) and lasts 5 hours. nil if none is open.
    func estimatedFiveHourWindow(now: Date) -> (start: Date, end: Date)? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = config.zone
        var window: (start: Date, end: Date)?
        for ts in events.lazy.map(\.ts).filter({ $0 > now - 24 * 3600 && $0 <= now }).sorted() {
            if let w = window, ts < w.end { continue }
            let start = cal.dateInterval(of: .hour, for: ts)?.start ?? ts
            window = (start, start + 5 * 3600)
        }
        guard let w = window, w.end > now else { return nil }
        return w
    }

    /// Weekly window: the real reset from a status-line reading (rolled forward if it has
    /// passed), else the configured week start.
    func weekWindow(now: Date, limits: Limits?) -> (start: Date, end: Date) {
        if let r = limits?.seven_day?.resets_at ?? calibration.weeklyReset, r > 0 {
            var end = Date(timeIntervalSince1970: r)
            while end <= now { end += 7 * 86400 }
            return (end - 7 * 86400, end)
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = config.zone
        let comps = DateComponents(hour: config.weekStartHour, minute: 0, second: 0, weekday: config.weekStartWeekday)
        let start = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime, direction: .backward) ?? now
        return (start, cal.date(byAdding: .day, value: 7, to: start)!)
    }

    // MARK: Calibration

    private func budgetFor(_ samples: [Sample], fallback: Double) -> (Double, Date?) {
        guard let avg = Calibration.average(samples) else { return (fallback, nil) }
        return (avg, samples.last?.at)
    }
    private typealias Sample = Calibration.Sample

    /// Back-solves both budgets from a status-line reading the first time it is seen.
    func autoCalibrate(_ limits: Limits, now: Date = Date()) {
        guard let cap = limits.captured_at, cap > (calibration.lastLiveCapture ?? 0) else { return }
        let capDate = Date(timeIntervalSince1970: cap)
        calibration.lastLiveCapture = cap
        if let r = limits.seven_day?.resets_at { calibration.weeklyReset = r }
        let keep = config.calibrationSamples
        // Low percentages are mostly rounding noise, so skip them.
        if let w = limits.five_hour, let pct = w.used_percentage, pct >= 5, let r = w.resets_at, r > cap {
            let end = Date(timeIntervalSince1970: r)
            let used = totals(from: end - 5 * 3600, to: capDate).weighted
            if used > 0 { Calibration.add(Sample(at: capDate, budget: used * 100 / pct, source: "live"), to: &calibration.fiveHour, keep: keep) }
        }
        if let w = limits.seven_day, let pct = w.used_percentage, pct >= 2, let r = w.resets_at, r > cap {
            let end = Date(timeIntervalSince1970: r)
            let used = totals(from: end - 7 * 86400, to: capDate).weighted
            if used > 0 { Calibration.add(Sample(at: capDate, budget: used * 100 / pct, source: "live"), to: &calibration.weekly, keep: keep) }
        }
        calibration.save(calibrationPath)
    }

    /// The user typed the percentages shown by /usage. Either may be nil. Returns a short
    /// message for each meter that could not be calibrated.
    @discardableResult
    func calibrate(fiveHourPercent: Double?, weeklyPercent: Double?, now: Date = Date()) -> [String] {
        var problems: [String] = []
        let limits = Limits.read(config.resolvedLimitsFile)
        let keep = config.calibrationSamples
        if let pct = fiveHourPercent {
            let w = liveWindow(limits?.five_hour, length: 5 * 3600, now: now) ?? estimatedFiveHourWindow(now: now)
            let used = w.map { totals(from: $0.start, to: now).weighted } ?? 0
            if pct > 0, used > 0 { Calibration.add(Sample(at: now, budget: used * 100 / pct, source: "manual"), to: &calibration.fiveHour, keep: keep) }
            else { problems.append("5-hour: needs a % above 0 and some usage in the current window") }
        }
        if let pct = weeklyPercent {
            let w = weekWindow(now: now, limits: limits)
            let used = totals(from: w.start, to: now).weighted
            if pct > 0, used > 0 { Calibration.add(Sample(at: now, budget: used * 100 / pct, source: "manual"), to: &calibration.weekly, keep: keep) }
            else { problems.append("Weekly: needs a % above 0 and some usage this week") }
        }
        calibration.save(calibrationPath)
        return problems
    }

    private func liveWindow(_ w: Limits.Window?, length: Double, now: Date) -> (start: Date, end: Date)? {
        guard let r = w?.resets_at, r > now.timeIntervalSince1970 else { return nil }
        let end = Date(timeIntervalSince1970: r)
        return (end - length, end)
    }

    // MARK: Aggregation

    func aggregate(now: Date = Date(), limits: Limits? = nil) -> Aggregates {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = config.zone
        let fresh = limits?.captured_at.map { now.timeIntervalSince1970 - $0 <= config.liveMaxAgeMinutes * 60 } ?? false
        let capDate = limits?.captured_at.map { Date(timeIntervalSince1970: $0) }
        let dateLabel = Date.FormatStyle(timeZone: config.zone).month(.abbreviated).day()

        func meter(_ name: String, live: Limits.Window?, window: (start: Date, end: Date)?, samples: [Sample], fallback: Double) -> Meter {
            let (budget, calibratedAt) = budgetFor(samples, fallback: fallback)
            let tokens = window.map { totals(from: $0.start, to: now) } ?? Totals()
            var used = tokens.weighted * 100 / budget
            var source = "estimated"
            if fresh, let pct = live?.used_percentage, let r = live?.resets_at, r > now.timeIntervalSince1970, let capDate {
                // Real % at capture, plus anything logged since then.
                let since = window.map { totals(from: max($0.start, capDate), to: now).weighted } ?? 0
                used = pct + since * 100 / budget
                source = "live"
            }
            let label = calibratedAt.map { "calibrated \($0.formatted(dateLabel))" } ?? "\(config.planLabel) default"
            return Meter(name: name, source: source, usedPercent: used, leftPercent: max(0, 100 - used),
                         windowStart: window?.start, resetsAt: window?.end, tokens: tokens, budget: budget,
                         calibratedAt: calibratedAt, budgetLabel: label)
        }

        let fiveWindow = (fresh ? liveWindow(limits?.five_hour, length: 5 * 3600, now: now) : nil) ?? estimatedFiveHourWindow(now: now)
        let week = weekWindow(now: now, limits: limits)
        let fiveHour = meter("5-hour session", live: limits?.five_hour, window: fiveWindow,
                             samples: calibration.fiveHour, fallback: config.planBudget.fiveHour)
        let weekly = meter("Weekly", live: limits?.seven_day, window: week,
                           samples: calibration.weekly, fallback: config.planBudget.weekly)

        let dayStart = cal.startOfDay(for: now)
        var today = Totals()
        var months: [String: Totals] = [:]
        var bySession: [String: SessionRow] = [:]
        var daily: [Date: (Double, Int)] = [:]
        let firstDay = cal.date(byAdding: .day, value: -13, to: dayStart)!
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "yyyy-MM"; monthFmt.timeZone = TimeZone(identifier: "UTC")

        for e in events where e.ts <= now {
            add(&months[monthFmt.string(from: e.ts), default: Totals()], e)
            if e.ts >= dayStart { add(&today, e) }
            if e.ts >= firstDay {
                let d = cal.startOfDay(for: e.ts)
                var t = Totals(); add(&t, e)
                daily[d, default: (0, 0)].0 += t.weighted
                daily[d, default: (0, 0)].1 += t.raw
            }
            guard e.ts >= week.start else { continue }
            var row = bySession[e.session] ?? {
                let m = meta[e.session]
                let project = m?.cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
                return SessionRow(sessionId: e.session, title: m?.title ?? String(e.session.prefix(8)),
                                  project: project, weighted: 0, raw: 0, messages: 0, lastActive: e.ts)
            }()
            var t = Totals(); add(&t, e)
            row.weighted += t.weighted; row.raw += t.raw; row.messages += 1
            row.lastActive = max(row.lastActive, e.ts)
            bySession[e.session] = row
        }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.timeZone = config.zone
        let days = (0..<14).map { i -> DayBucket in
            let d = cal.date(byAdding: .day, value: i, to: firstDay)!
            let v = daily[d] ?? (0, 0)
            return DayBucket(day: dayFmt.string(from: d), weighted: v.0, raw: v.1)
        }

        let top = bySession.values.sorted { $0.weighted > $1.weighted }.prefix(config.topSessions)
        return Aggregates(generatedAt: now, timeZone: config.zone.identifier, plan: config.planLabel,
                          fiveHour: fiveHour, weekly: weekly,
                          forecast: makeForecast(now: now, week: week, meter: weekly),
                          today: today, daily: days, sessions: Array(top), limits: limits, monthsUTC: months)
    }

    /// End-of-week forecast. The run-rate blends the week-to-date average (70%) with the
    /// last 24 hours (30%), so one heavy hour moves it a little rather than a lot.
    private func makeForecast(now: Date, week: (start: Date, end: Date), meter: Meter) -> Forecast {
        let elapsedH = max(now.timeIntervalSince(week.start) / 3600, 0)
        let remainingH = max(week.end.timeIntervalSince(now) / 3600, 0)
        let wtdRate = elapsedH > 0 ? meter.tokens.weighted / elapsedH : 0
        let recentH = min(24, elapsedH)
        let recentRate = recentH > 0 ? totals(from: now - recentH * 3600, to: now).weighted / recentH : 0
        let rate = elapsedH < 6 ? recentRate : 0.7 * wtdRate + 0.3 * recentRate
        let k = 100 / meter.budget  // percent per weighted token
        let projectedPct = meter.usedPercent + k * rate * remainingH
        var runsOut: Date?
        if meter.usedPercent >= 100 { runsOut = now }
        else if projectedPct >= 100, rate > 0 { runsOut = now + (100 - meter.usedPercent) / (k * rate) * 3600 }
        return Forecast(ratePerHour: rate, hoursRemaining: remainingH,
                        projectedWeighted: meter.tokens.weighted + rate * remainingH,
                        projectedPercent: projectedPct, runsOutAt: runsOut)
    }
}

// MARK: - Demo data (README screenshot)

extension Aggregates {
    /// Made-up figures so the screenshot shows no real session or project names.
    static func demo(now: Date = Date()) -> Aggregates {
        func totals(_ w: Double, msgs: Int) -> Totals {
            Totals(input: Int(w * 0.002), output: Int(w * 0.03), cacheWrite: Int(w * 0.25), cacheRead: Int(w * 4.5), messages: msgs, weighted: w)
        }
        let five = Meter(name: "5-hour session", source: "live", usedPercent: 46, leftPercent: 54,
                         windowStart: now - 2.5 * 3600, resetsAt: now + 2.5 * 3600, tokens: totals(11.5e6, msgs: 212),
                         budget: 25e6, calibratedAt: now - 3600, budgetLabel: "calibrated \(now.formatted(.dateTime.month(.abbreviated).day()))")
        let week = Meter(name: "Weekly", source: "live", usedPercent: 78, leftPercent: 22,
                         windowStart: now - 4 * 86400, resetsAt: now + 3 * 86400, tokens: totals(195e6, msgs: 2140),
                         budget: 250e6, calibratedAt: now - 3600, budgetLabel: five.budgetLabel)
        let daily = [0.0, 3, 8, 12, 5, 0, 0, 18, 26, 41, 22, 52, 61, 34].enumerated().map { i, v in
            DayBucket(day: String(format: "2026-01-%02d", i + 1), weighted: v * 1e6, raw: Int(v * 5e6))
        }
        let names = [("Refactor billing service", "billing-api"), ("Fix flaky checkout tests", "web-shop"),
                     ("Write onboarding docs", "handbook"), ("Spike: vector search", "search-lab"), ("Triage open issues", "web-shop")]
        let sessions = names.enumerated().map { i, n in
            SessionRow(sessionId: "demo\(i)", title: n.0, project: n.1, weighted: [58e6, 41e6, 27e6, 19e6, 9e6][i],
                       raw: 0, messages: 0, lastActive: now - Double(i * i + 1) * 1800)
        }
        return Aggregates(generatedAt: now, timeZone: TimeZone.current.identifier, plan: "Max 5x", fiveHour: five, weekly: week,
                          forecast: Forecast(ratePerHour: 1.6e6, hoursRemaining: 72, projectedWeighted: 310e6,
                                             projectedPercent: 124, runsOutAt: now + 34 * 3600),
                          today: totals(34e6, msgs: 520), daily: daily, sessions: sessions, limits: nil, monthsUTC: [:])
    }
}

// MARK: - Formatting helpers shared by UI and dump

func compact(_ v: Double) -> String {
    let a = abs(v)
    switch a {
    case 1e9...: return String(format: "%.2fB", v / 1e9)
    case 1e6...: return String(format: "%.1fM", v / 1e6)
    case 1e3...: return String(format: "%.0fK", v / 1e3)
    default: return String(format: "%.0f", v)
    }
}
