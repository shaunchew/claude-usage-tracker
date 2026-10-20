// Minimal test runner (no XCTest needed): `make test`.
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { failures += 1; print("FAIL line \(line): \(msg)") }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cut-tests-\(UUID().uuidString)")
let proj = dir.appendingPathComponent("projects/-home-x-proj")
try! FileManager.default.createDirectory(at: proj.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)

let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
// Fixed "now": Wednesday 2026-10-21 12:00 UTC.
let now = iso.date(from: "2026-10-21T12:00:00.000Z")!
func ts(_ hoursAgo: Double) -> String { iso.string(from: now - hoursAgo * 3600) }

func line(id: String, req: String, session: String, hoursAgo: Double, model: String = "claude-opus-5-5",
          input: Int = 0, output: Int = 0, cw: Int = 0, cr: Int = 0) -> String {
    """
    {"type":"assistant","timestamp":"\(ts(hoursAgo))","requestId":"\(req)","sessionId":"\(session)","cwd":"/home/x/proj","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cw),"cache_read_input_tokens":\(cr)}}}
    """
}

let main = proj.appendingPathComponent("s1.jsonl")
let sub = proj.appendingPathComponent("s1/subagents/agent-a.jsonl")
let mainText = [
    #"{"type":"custom-title","customTitle":"my session","sessionId":"s1"}"#,
    line(id: "m1", req: "r1", session: "s1", hoursAgo: 1, input: 100, output: 10),
    line(id: "m1", req: "r1", session: "s1", hoursAgo: 1, input: 100, output: 10),   // duplicate line
    line(id: "m2", req: "r2", session: "s1", hoursAgo: 2, cr: 1000),
    line(id: "m0", req: "r0", session: "s1", hoursAgo: 30, input: 200),              // this week, before the 5h window
    line(id: "m3", req: "r3", session: "s1", hoursAgo: 24 * 30, input: 999),          // last month: outside week
].joined(separator: "\n") + "\n"
try! mainText.write(to: main, atomically: true, encoding: .utf8)
try! (line(id: "m4", req: "r4", session: "s1", hoursAgo: 3, model: "claude-haiku-4-5", output: 100) + "\n")
    .write(to: sub, atomically: true, encoding: .utf8)

var cfg = Config()
cfg.projectsDir = proj.deletingLastPathComponent().path
cfg.timeZone = "UTC"
cfg.limitsFile = dir.appendingPathComponent("none.json").path
cfg.planBudgets["pro"] = PlanBudget(fiveHour: 1000, weekly: 10000)

// Projects dir follows CLAUDE_CONFIG_DIR when no explicit path is configured.
setenv("CLAUDE_CONFIG_DIR", "/tmp/alt-claude", 1)
check(Config().resolvedProjectsDir == "/tmp/alt-claude/projects", "CLAUDE_CONFIG_DIR respected")
unsetenv("CLAUDE_CONFIG_DIR")
check(Config().resolvedProjectsDir.hasSuffix("/.claude/projects"), "default projects dir")

let t = Tracker(config: cfg, calibrationPath: nil)
t.refresh(now: now)
var a = t.aggregate(now: now)

// Dedupe and weighting: m1 = 100*1 + 10*5 = 150; m2 = 1000*0.1 = 100; m4 = 100*5*0.2 (haiku) = 100; m0 = 200.
check(a.weekly.tokens.messages == 4, "dedupe: expected 4 messages this week, got \(a.weekly.tokens.messages)")
check(near(a.weekly.tokens.weighted, 550), "weighted: expected 550, got \(a.weekly.tokens.weighted)")
check(a.sessions.count == 1 && a.sessions.first?.title == "my session", "subagent folded into parent session with title")
check(a.sessions.first?.project == "proj", "project name from cwd")
check(a.weekly.windowStart == iso.date(from: "2026-10-19T00:00:00.000Z")!, "week starts Monday 00:00, got \(String(describing: a.weekly.windowStart))")
check(a.daily.count == 14 && a.daily.last?.day == "2026-10-21", "14 daily buckets ending today")
check(a.monthsUTC["2026-09"]?.input == 999, "older event still counted in monthly totals")

// Estimated meters: 5h window opens at the first message 3 h ago (09:00), so 350 of 1000.
check(a.fiveHour.source == "estimated" && a.weekly.source == "estimated", "no tap data: estimated")
check(a.fiveHour.windowStart == iso.date(from: "2026-10-21T09:00:00.000Z")!, "5h window start, got \(String(describing: a.fiveHour.windowStart))")
check(a.fiveHour.resetsAt == iso.date(from: "2026-10-21T14:00:00.000Z")!, "5h window reset")
check(near(a.fiveHour.usedPercent, 35) && near(a.fiveHour.leftPercent, 65), "5h % from budget, got \(a.fiveHour.usedPercent)")
check(near(a.weekly.usedPercent, 5.5), "weekly % from budget, got \(a.weekly.usedPercent)")
check(a.fiveHour.budgetLabel == "Pro default", "budget label, got \(a.fiveHour.budgetLabel)")
check(a.fiveHour.tokens.raw == 100 + 10 + 1000 + 100, "raw breakdown in 5h window, got \(a.fiveHour.tokens.raw)")

// No open 5h window once the last message is over 5 hours old.
check(t.estimatedFiveHourWindow(now: now + 6 * 3600) == nil, "5h window closes")

// Incremental: a partial trailing line is not consumed until it is complete.
let fh = try! FileHandle(forWritingTo: main)
fh.seekToEndOfFile()
let next = line(id: "m5", req: "r5", session: "s1", hoursAgo: 0.5, input: 50)
fh.write(Data(next.prefix(40).utf8))
t.refresh(now: now)
check(t.aggregate(now: now).weekly.tokens.messages == 4, "partial line ignored")
fh.write(Data((next.dropFirst(40) + "\n").utf8))
try! fh.close()
t.refresh(now: now)
a = t.aggregate(now: now)
check(a.weekly.tokens.messages == 5 && near(a.weekly.tokens.weighted, 600), "appended line picked up once, got \(a.weekly.tokens.messages)")

// Forecast: week-to-date 600 over 60 h (10/h), last 24 h 400 (16.7/h) -> 0.7*10 + 0.3*16.67 = 12/h.
// 108 h left (to Mon 00:00) -> +1296 weighted -> 6% + 12.96% = 18.96%.
check(near(a.forecast.ratePerHour, 12, 1e-3), "blended rate, got \(a.forecast.ratePerHour)")
check(near(a.forecast.projectedPercent, 18.96, 1e-3), "projected %, got \(a.forecast.projectedPercent)")
check(a.forecast.runsOutAt == nil, "no run-out under 100%")

// Manual calibration: 5h used 400 weighted; user says 20% -> budget 2000.
t.calibrate(fiveHourPercent: 20, weeklyPercent: nil, now: now)
a = t.aggregate(now: now)
check(near(a.fiveHour.budget, 2000) && near(a.fiveHour.usedPercent, 20), "manual calibration, got \(a.fiveHour.budget)")
check(a.fiveHour.budgetLabel.hasPrefix("calibrated "), "calibrated label")
t.calibrate(fiveHourPercent: 40, weeklyPercent: nil, now: now)  // -> 1000; average with 2000
check(near(t.aggregate(now: now).fiveHour.budget, 1500), "budget averaged over samples")

// Live reading from the status line: fresh tap -> live meters, week follows the real reset,
// and the budgets are back-solved from it.
let reset7 = now + 30 * 3600, reset5 = now + 2 * 3600
let limits = Limits(five_hour: .init(used_percentage: 10, resets_at: reset5.timeIntervalSince1970),
                    seven_day: .init(used_percentage: 20, resets_at: reset7.timeIntervalSince1970),
                    captured_at: now.timeIntervalSince1970)
let t3 = Tracker(config: cfg, calibrationPath: nil)
t3.refresh(now: now)
t3.autoCalibrate(limits, now: now)
a = t3.aggregate(now: now, limits: limits)
check(a.weekly.source == "live" && a.fiveHour.source == "live", "fresh tap: live")
check(a.weekly.resetsAt == reset7, "week ends at the plan reset")
check(near(a.weekly.usedPercent, 20) && near(a.fiveHour.usedPercent, 10), "live % shown, got \(a.weekly.usedPercent)")
// Weekly window = reset7 - 7d = 2026-10-15 18:00 -> all 600 weighted this week -> budget 3000.
check(near(a.weekly.budget, 3000), "auto-calibrated weekly budget, got \(a.weekly.budget)")
// 5h window = 07:00-14:00... start reset5 - 5h = 09:00 -> 400 weighted at 10% -> 4000.
check(near(a.fiveHour.budget, 4000), "auto-calibrated 5h budget, got \(a.fiveHour.budget)")

// A stale reading is "estimated" but still places the week.
check(t3.aggregate(now: now + 600, limits: limits).weekly.source == "live", "10 min old: still live")
a = t3.aggregate(now: now + 3600, limits: limits)
check(a.weekly.source == "estimated" && a.weekly.resetsAt == reset7, "stale tap: estimated, week still from reset")

// Run-out time when the forecast passes 100%.
var tight = cfg; tight.planBudgets["pro"] = PlanBudget(fiveHour: 1000, weekly: 1000)
let t5 = Tracker(config: tight, calibrationPath: nil)
t5.refresh(now: now)
let f5 = t5.aggregate(now: now).forecast
check(f5.projectedPercent > 100 && f5.runsOutAt != nil, "run-out time when over 100%")
// 60% used, 1.2%/h -> 100% in 33.3 h.
check(near(f5.runsOutAt!.timeIntervalSince(now) / 3600, 400 / 12, 1e-3), "run-out hour, got \(f5.runsOutAt!.timeIntervalSince(now) / 3600)")

// Tap keeps only rate_limits.
let tapFile = dir.appendingPathComponent("limits.json").path
let sl = #"{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.2},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1790000000},"seven_day":{"used_percentage":40,"resets_at":1790500000}}}"#
check(Limits.tap(input: Data(sl.utf8), to: tapFile, now: now), "tap writes")
let tapped = Limits.read(tapFile)
check(tapped?.five_hour?.used_percentage == 12.5 && tapped?.seven_day?.resets_at == 1790500000 && tapped?.captured_at == now.timeIntervalSince1970, "tap fields")
check(!(String(data: FileManager.default.contents(atPath: tapFile)!, encoding: .utf8)!.contains("cost")), "tap drops other fields")
check(!Limits.tap(input: Data(#"{"model":{}}"#.utf8), to: tapFile), "no rate_limits: nothing written")

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "all tests passed" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
