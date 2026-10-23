import AppKit
import Combine
import SwiftUI

// MARK: - Store

/// Refreshes the tracker on a background queue and publishes aggregates on the main thread.
final class UsageStore: ObservableObject {
    @Published var agg: Aggregates?
    @Published var refreshing = false
    /// Mirrors the Always on Top setting so the panel's pin button can show it.
    @Published var alwaysOnTop = false
    let config: Config
    private let tracker: Tracker
    private let queue = DispatchQueue(label: "usage.refresh", qos: .utility)
    private var timer: Timer?

    init(config: Config) {
        self.config = config
        tracker = Tracker(config: config)
    }

    func start() {
        refresh()
        let t = Timer(timeInterval: config.refreshSeconds, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = min(5, config.refreshSeconds / 4)  // lets macOS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        refreshing = true
        queue.async { [tracker] in
            let a = tracker.update()
            DispatchQueue.main.async { self.agg = a; self.refreshing = false }
        }
    }

    /// Back-solves the budgets from the percentages the user read off /usage, then refreshes.
    func calibrate(fiveHour: Double?, weekly: Double?, done: @escaping ([String]) -> Void) {
        queue.async { [tracker] in
            tracker.refresh()
            let problems = tracker.calibrate(fiveHourPercent: fiveHour, weeklyPercent: weekly)
            let a = tracker.update()
            DispatchQueue.main.async { self.agg = a; done(problems) }
        }
    }
}

// MARK: - Panel view

struct PanelView: View {
    @ObservedObject var store: UsageStore
    var snapshot = false
    var onRefresh: () -> Void = {}
    var onCalibrate: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onHide: () -> Void = {}
    /// Called with the mouse movement since the drag began (nil when it ends).
    var onDrag: (CGSize?) -> Void = { _ in }
    /// Index of the trend bar under the mouse. Settable so the snapshot can show the tooltip.
    @State var hoverDay: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = store.agg { content(a) } else { Text("Reading Claude Code logs…").font(.callout) }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        // Drag the panel from anywhere that is not a button. NSEvent.mouseLocation is in screen
        // coordinates, so moving the window does not feed back into the drag.
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { _ in onDrag(.zero) }
            .onEnded { _ in onDrag(nil) })
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var background: some View {
        if snapshot { Color(white: 0.13).opacity(0.97) } else { VisualEffect() }
    }

    @ViewBuilder private func content(_ a: Aggregates) -> some View {
        HStack(spacing: 4) {
            Text("Claude usage").font(.headline).lineLimit(1).fixedSize()
            Spacer()
            Text("updated \(hhmm(a.generatedAt))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            iconButton("arrow.clockwise", help: "Refresh now", action: onRefresh)
                .rotationEffect(.degrees(store.refreshing ? 180 : 0))
                .animation(.easeInOut(duration: 0.4), value: store.refreshing)
            iconButton("slider.horizontal.3", help: "Calibrate from /usage", action: onCalibrate)
            iconButton(store.alwaysOnTop ? "pin.fill" : "pin", help: store.alwaysOnTop ? "Stop floating above other windows" : "Always on top", action: onTogglePin)
            iconButton("minus", help: "Hide panel (click the menu-bar icon to bring it back)", action: onHide)
        }

        meter(a.fiveHour, resetFormat: "HH:mm")
        meter(a.weekly, resetFormat: "EEE HH:mm")
        forecast(a)
        trend(a.daily)
        sessions(a.sessions)

        Text("\(a.plan) plan · weighted tokens (cache reads ×0.1). Estimates are a proxy, not the real meter.")
            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        let icon = Image(systemName: symbol).font(.caption.weight(.semibold)).frame(width: 17, height: 18)
        // ImageRenderer cannot draw AppKit-backed buttons, so the snapshot shows the bare icon.
        if snapshot { icon.foregroundStyle(.secondary) }
        else { Button(action: action) { icon }.buttonStyle(.borderless).foregroundStyle(.secondary).help(help) }
    }

    private func meter(_ m: Meter, resetFormat: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(m.name).font(.caption).foregroundStyle(.secondary)
                badge(m.source)
                Text(m.budgetLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                if let r = m.resetsAt {
                    Text("resets \(fmt(r, resetFormat))").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("no window open").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(m.usedPercent.rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color(m.usedPercent))
                Text("used · \(Int(m.leftPercent.rounded()))% left").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(compact(m.tokens.weighted)).font(.callout).monospacedDigit()
            }
            bar(m.usedPercent)
            Text("in \(compact(Double(m.tokens.input))) · out \(compact(Double(m.tokens.output))) · cache write \(compact(Double(m.tokens.cacheWrite))) · read \(compact(Double(m.tokens.cacheRead)))")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func badge(_ source: String) -> some View {
        Text(source)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(source == "live" ? Color.green.opacity(0.3) : Color.white.opacity(0.12)))
    }

    private func bar(_ pct: Double, ghost: Double? = nil) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                if let ghost {
                    Capsule().fill(color(ghost).opacity(0.35)).frame(width: g.size.width * min(max(ghost, 0), 100) / 100)
                }
                Capsule().fill(color(pct)).frame(width: g.size.width * min(max(pct, 0), 100) / 100)
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder private func forecast(_ a: Aggregates) -> some View {
        let f = a.forecast
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("End-of-week forecast").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(f.projectedPercent.rounded()))%").font(.callout.bold()).monospacedDigit()
                    .foregroundStyle(color(f.projectedPercent))
            }
            bar(a.weekly.usedPercent, ghost: f.projectedPercent)
            HStack {
                Text("\(compact(f.ratePerHour))/h · \(Int(f.hoursRemaining))h to reset").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let out = f.runsOutAt {
                    Text("runs out \(fmt(out, "EEE HH:mm"))")
                        .font(.caption.bold()).foregroundStyle(.red)
                }
            }
        }
    }

    private func trend(_ days: [DayBucket]) -> some View {
        let maxV = max(days.map(\.weighted).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Last 14 days").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == hoverDay ? Color.white : i == days.count - 1 ? Color.orange : Color.white.opacity(0.45))
                        .frame(height: max(2, 40 * d.weighted / maxV))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40, alignment: .bottom)
            .overlay {
                // ImageRenderer cannot draw AppKit views, so the snapshot leaves the tracker out.
                if !snapshot { HoverTracker { x in hoverDay = x.map { min(days.count - 1, max(0, Int($0 * Double(days.count)))) } } }
            }
            .overlay(alignment: .topLeading) {
                if let i = hoverDay, days.indices.contains(i) { dayTip(days[i], index: i, count: days.count) }
            }
            HStack {
                Text(days.first.map { String($0.day.suffix(5)) } ?? "")
                Spacer()
                Text("peak \(compact(maxV))")
                Spacer()
                Text("today")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Tooltip over the hovered bar: date, weighted and raw tokens. Kept inside the chart's width.
    private func dayTip(_ d: DayBucket, index: Int, count: Int) -> some View {
        GeometryReader { g in
            let tipWidth: CGFloat = 185
            let center = g.size.width * (CGFloat(index) + 0.5) / CGFloat(count)
            VStack(alignment: .leading, spacing: 1) {
                Text(dayLabel(d.day)).font(.caption2.bold())
                Text("\(compact(d.weighted)) weighted · \(compact(Double(d.raw))) raw").font(.caption2).monospacedDigit()
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(width: tipWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85)))
            .offset(x: min(max(center - tipWidth / 2, 0), g.size.width - tipWidth), y: -30)
        }
        .allowsHitTesting(false)
    }

    private func dayLabel(_ day: String) -> String {
        let p = DateFormatter(); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: day) else { return day }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: d)
    }

    private func sessions(_ rows: [SessionRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Top sessions this week").font(.caption).foregroundStyle(.secondary)
            ForEach(rows, id: \.sessionId) { r in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(r.title).font(.callout).lineLimit(1).truncationMode(.tail)
                        Text("\(r.project) · \(relative(r.lastActive))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(compact(r.weighted)).font(.callout).monospacedDigit()
                }
            }
            if rows.isEmpty { Text("No sessions yet this week").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func hhmm(_ d: Date) -> String { fmt(d, "HH:mm") }

    private func fmt(_ d: Date, _ format: String) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate(format == "HH:mm" ? "HHmm" : "EEEHHmm")
        return f.string(from: d)
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: store.agg?.generatedAt ?? Date())
    }
}

/// Green below 75%, amber from 75%, red from 90%.
func color(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 75 ? .orange : .green }

/// Reports the mouse's horizontal position (0...1) over the view, or nil when it leaves.
/// Uses an always-active tracking area because the panel is never the key window, where
/// SwiftUI hover and .help tooltips do not fire reliably. Clicks and drags pass through.
struct HoverTracker: NSViewRepresentable {
    var onMove: (Double?) -> Void

    final class TrackingView: NSView {
        var onMove: (Double?) -> Void = { _ in }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        private func report(_ e: NSEvent) {
            let x = convert(e.locationInWindow, from: nil).x
            onMove(bounds.width > 0 ? Double(x / bounds.width) : nil)
        }
        override func mouseEntered(with e: NSEvent) { report(e) }
        override func mouseMoved(with e: NSEvent) { report(e) }
        override func mouseExited(with e: NSEvent) { onMove(nil) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> TrackingView { let v = TrackingView(); v.onMove = onMove; return v }
    func updateNSView(_ v: TrackingView, context: Context) { v.onMove = onMove }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - App delegate: panel + menu bar item

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let config = Config.load()
    private lazy var store = UsageStore(config: config)
    private var panel: NSPanel!
    private var hosting: NSHostingView<PanelView>!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var sub: AnyCancellable?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private let autosaveName = "ClaudeUsagePanel"

    // Settings kept across restarts (UserDefaults).
    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? config.alwaysOnTop }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop"); store.alwaysOnTop = newValue }
    }
    /// false = collapsed to the menu bar only.
    private var panelShown: Bool {
        get { UserDefaults.standard.object(forKey: "panelShown") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "panelShown") }
    }
    private var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hosting = NSHostingView(rootView: PanelView(
            store: store,
            onRefresh: { [weak self] in self?.refreshNow() },
            onCalibrate: { [weak self] in self?.calibrate() },
            onTogglePin: { [weak self] in self?.toggleOnTop() },
            onHide: { [weak self] in self?.setPanel(shown: false) },
            onDrag: { [weak self] d in self?.drag(d) }))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 480),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true  // for the trend chart tooltip
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        store.alwaysOnTop = alwaysOnTop
        applyLevel()
        applyDockPolicy()
        if !panel.setFrameUsingName(autosaveName), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 330, y: screen.maxY - 20))
        }
        panel.setFrameAutosaveName(autosaveName)
        if panelShown { panel.orderFrontRegardless() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Claude usage")
        statusItem.button?.imagePosition = .imageLeading
        // Left-click shows or hides the panel; right-click (or Control-click) opens the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self

        sub = store.$agg.receive(on: RunLoop.main).sink { [weak self] a in self?.update(a) }
        store.start()
    }

    private func update(_ a: Aggregates?) {
        guard let a else { return }
        // Menu bar: "5h% · week%".
        statusItem.button?.title = " \(Int(a.fiveHour.usedPercent.rounded()))% · \(Int(a.weekly.usedPercent.rounded()))%"
        statusItem.button?.toolTip = "5-hour \(a.fiveHour.source) · weekly \(a.weekly.source). Click to show or hide the panel, right-click for options."
        // Fit the panel to its content, keeping the top-left corner where the user put it.
        let size = hosting.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func drag(_ d: CGSize?) {
        guard d != nil else { dragStart = nil; return }
        let mouse = NSEvent.mouseLocation
        guard let start = dragStart else { dragStart = (mouse, panel.frame.origin); return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func applyLevel() {
        panel.level = alwaysOnTop ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let a = store.agg {
            for m in [a.fiveHour, a.weekly] {
                let item = menu.addItem(withTitle: "\(m.name): \(Int(m.usedPercent.rounded()))% (\(m.source))", action: nil, keyEquivalent: "")
                item.isEnabled = false
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Calibrate from /usage…", action: #selector(calibrate), keyEquivalent: "").target = self
        menu.addItem(withTitle: panel.isVisible ? "Hide Panel" : "Show Panel", action: #selector(togglePanel), keyEquivalent: "").target = self
        let top = menu.addItem(withTitle: "Always on Top", action: #selector(toggleOnTop), keyEquivalent: "")
        top.target = self
        top.state = alwaysOnTop ? .on : .off
        let dock = menu.addItem(withTitle: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        dock.state = showInDock ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func statusItemClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            // Attach the menu only for this click, so a left-click stays a plain toggle.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    private func setPanel(shown: Bool) {
        panelShown = shown
        shown ? panel.orderFrontRegardless() : panel.orderOut(nil)
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// Clicking the Dock icon (when shown) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setPanel(shown: true)
        return false
    }

    @objc private func togglePanel() { setPanel(shown: !panel.isVisible) }
    @objc private func toggleOnTop() { alwaysOnTop.toggle(); applyLevel() }
    @objc private func toggleDock() { showInDock.toggle(); applyDockPolicy() }
    @objc private func refreshNow() { store.refresh() }

    /// Asks for the percentages shown by /usage in Claude Code and back-solves the budgets.
    @objc private func calibrate() {
        let alert = NSAlert()
        alert.messageText = "Calibrate from /usage"
        alert.informativeText = "Run /usage in Claude Code and type the % used it shows. Leave a field empty to skip it."
        let five = NSTextField(string: ""), week = NSTextField(string: "")
        five.placeholderString = "5-hour session %"
        week.placeholderString = "Weekly (all models) %"
        let stack = NSStackView(views: [five, week])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = five
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func pct(_ f: NSTextField) -> Double? {
            Double(f.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: " %")))
        }
        store.calibrate(fiveHour: pct(five), weekly: pct(week)) { problems in
            guard !problems.isEmpty else { return }
            let a = NSAlert()
            a.messageText = "Some meters were not calibrated"
            a.informativeText = problems.joined(separator: "\n")
            a.runModal()
        }
    }
}

// MARK: - Offscreen render for docs/screenshot.png

@MainActor func renderSnapshot(to path: String, demo: Bool, hoverDay: Int? = nil) -> Bool {
    let store = UsageStore(config: Config.load())
    store.agg = demo ? .demo() : Tracker(config: store.config).update()
    let renderer = ImageRenderer(content: PanelView(store: store, snapshot: true, hoverDay: hoverDay).padding(20))
    renderer.scale = 2
    guard let cg = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
    return FileManager.default.createFile(atPath: path, contents: png)
}
