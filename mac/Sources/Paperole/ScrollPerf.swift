import AppKit
import QuartzCore

/// Debug counters of view body evaluations, read by --debug-scroll-perf (UX.md §10.9): the panel's rows, expanded card
/// and list; the sidebar, its papers and its Contents rows (POLISH §5: scrolling the PDF redraws only the section rows
/// it leaves and enters).
enum BodyCount {
    static var row = 0
    static var expanded = 0
    static var list = 0
    static var sidebar = 0
    static var paper = 0
    static var section = 0
    static var snapshot: [String: Int] {
        ["row": row, "expanded": expanded, "list": list, "sidebar": sidebar, "paper": paper, "section": section]
    }
}

/// --debug-scroll-perf scroll|wheel|keys|pdf (UX.md §13): measures the shown panel list's frame intervals with a display
/// link. `scroll` moves the panel's NSScrollView 24 pt per tick to the bottom and back; `wheel` does it with a 24-pixel
/// scroll-wheel event per tick, through the view's own scrolling; `pdf` moves the PDF 24 pt per tick, at most 400 ticks
/// down and back (the sidebar's Contents follows it: its body counts); `keys` presses J through every card,
/// then K back, every 150 ms; each step's `key_ms` is the run loop turn that handled the key (the new card laid out and
/// drawn), which can be measured with the display asleep. When the display link does not tick (the display asleep), the
/// scrolling modes step on a 60 Hz timer instead and time each step's scroll, layout and drawing at once (`work_*_ms`,
/// as `key_ms`; `timer: true`). Writes one JSON object to `out` (or stderr) and calls `done`.
@MainActor
final class ScrollPerf: NSObject {
    private let mode: String
    private let out: String?
    private let cards: Int
    private let press: (String) -> Void
    private let done: () -> Void
    private var scrollView: NSScrollView?
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60
    private var down = true
    private var bodies0 = BodyCount.snapshot
    private var steps: [[String: Any]] = []
    private var step: (n: Int, start: Int, bodies: [String: Int])?
    private var timer: Timer?
    /// Main run loop iterations as (start, busy seconds): what a step costs on the main thread, which can be measured
    /// when the display link does not tick (display asleep).
    private var busy: [(CFTimeInterval, CFTimeInterval)] = []
    private var woke: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    private var window: NSWindow?
    private var ticks = 0  // in the current direction (pdf: at most 400)
    private var fallback: Timer?  // the display link did not tick
    private var work: [CFTimeInterval] = []
    private var section0 = 0
    var sectionChanges: () -> Int = { 0 }
    /// The run is in Focus (--focus): noted in the result.
    var focus = false

    init(mode: String, out: String?, cards: Int, press: @escaping (String) -> Void, done: @escaping () -> Void) {
        self.mode = mode
        self.out = out
        self.cards = cards
        self.press = press
        self.done = done
    }

    /// The panel's scroll view: the rightmost NSScrollView that is neither inside a PDFView nor the sidebar's table.
    static func panelScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ v: NSView, inPDF: Bool) {
            let pdf = inPDF || v.className.contains("PDFView")
            if let s = v as? NSScrollView, !pdf, !(s.documentView is NSTableView) { found.append(s) }
            v.subviews.forEach { walk($0, inPDF: pdf) }
        }
        walk(root, inPDF: false)
        return found.max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    func run(in window: NSWindow, scrollView given: NSScrollView? = nil) {
        guard let root = window.contentView, let sv = given ?? Self.panelScrollView(in: root) else {
            return finish(["error": "no panel scroll view"])
        }
        scrollView = sv
        self.window = window
        bodies0 = BodyCount.snapshot
        section0 = sectionChanges()
        let l = sv.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        if mode != "keys" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.stamps.isEmpty, self.link != nil else { return }
                self.fallback = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let t0 = CACurrentMediaTime()
                        let more = self.scrollStep()
                        self.window?.displayIfNeeded()
                        self.work.append(CACurrentMediaTime() - t0)
                        if !more { self.stop() }
                    }
                }
            }
        }
        if mode == "keys" {
            let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity([.afterWaiting, .beforeWaiting]).rawValue,
                                                         true, 0) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    if activity == .afterWaiting { self.woke = now } else if self.woke > 0 { self.busy.append((self.woke, now - self.woke)) }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
            observer = obs
            var n = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.endStep()
                    let total = 2 * self.cards
                    if n >= total { self.stop(); return }
                    self.step = (n, self.stamps.count, BodyCount.snapshot)
                    self.stepStart = CACurrentMediaTime()
                    self.press(n < self.cards ? "j" : "k")
                    n += 1
                }
            }
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        if fallback != nil { return }
        stamps.append(l.timestamp)
        if l.duration > 0 { refresh = l.duration }
        guard mode != "keys" else { return }
        if !scrollStep() { stop() }
    }

    /// One 24 pt step down, or back up once the bottom (or pdf's 400 steps) is reached; false when back at the top.
    private func scrollStep() -> Bool {
        guard let sv = scrollView else { return false }
        let clip = sv.contentView
        let flipped = sv.documentView?.isFlipped ?? true
        let dy: CGFloat = (down == flipped) ? 24 : -24
        var proposed = clip.bounds
        proposed.origin.y += dy
        let next = clip.constrainBoundsRect(proposed).origin
        ticks += 1
        if abs(next.y - clip.bounds.origin.y) < 0.5 || (mode == "pdf" && ticks > 400) {
            if !down { return false }
            down = false
            ticks = 0
            return true
        }
        // wheel: a scroll-wheel event of 24 pixels through the scroll view's own handling, as a trackpad sends
        if mode == "wheel", let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                             wheel1: down ? -24 : 24, wheel2: 0, wheel3: 0), let e = NSEvent(cgEvent: cg) {
            sv.scrollWheel(with: e)
            return true
        }
        clip.scroll(to: next)
        sv.reflectScrolledClipView(clip)
        return true
    }

    private var stepStart: CFTimeInterval = 0

    private func endStep() {
        guard let s = step else { return }
        let ivs = intervals(Array(stamps[max(s.start - 1, 0)...]))
        let b = BodyCount.snapshot
        let mine = busy.filter { $0.0 >= stepStart - 0.0005 }.map(\.1)
        let key = busy.first { $0.0 <= stepStart && $0.0 + $0.1 >= stepStart }?.1 ?? 0
        steps.append(["step": s.n, "ms": round1((ivs.max() ?? 0) * 1000),
                      "busy_ms": round1(mine.reduce(0, +) * 1000), "longest_ms": round1((mine.max() ?? 0) * 1000),
                      "key_ms": round1(key * 1000), "bodies": b.merging(s.bodies) { $0 - $1 }])
        busy = []
        step = nil
    }

    private func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        timer?.invalidate()
        fallback?.invalidate()
        link?.invalidate()
        guard link != nil else { return }
        link = nil
        let ivs = intervals(stamps)
        let sorted = ivs.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] * 1000 }
        let first = stamps.first ?? 0
        var late = 0
        for (i, iv) in ivs.enumerated() where iv > 0.05 && stamps[i + 1] - first > 1 { late += 1 }
        var result: [String: Any] = [
            "mode": mode, "cards": cards, "frames": stamps.count, "refresh_ms": round1(refresh * 1000),
            "p50_ms": round1(pct(0.5)), "p95_ms": round1(pct(0.95)), "max_ms": round1((sorted.last ?? 0) * 1000),
            "over_50ms": late, "bodies": BodyCount.snapshot.merging(bodies0) { $0 - $1 }]
        if fallback != nil {
            let w = work.sorted()
            func wp(_ p: Double) -> Double { w.isEmpty ? 0 : round1(w[min(Int(Double(w.count) * p), w.count - 1)] * 1000) }
            result["timer"] = true
            result["work_p50_ms"] = wp(0.5)
            result["work_p95_ms"] = wp(0.95)
            result["work_max_ms"] = round1((w.last ?? 0) * 1000)
            result["steps"] = w.count
        }
        if mode == "pdf" { result["sections"] = sectionChanges() - section0 }
        if focus { result["focus"] = true }
        if mode == "keys" {
            result["steps"] = steps
            let keys = steps.dropFirst().compactMap { $0["key_ms"] as? Double }.sorted()  // the first step builds the card's views
            func kp(_ p: Double) -> Double { keys.isEmpty ? 0 : keys[min(Int(Double(keys.count) * p), keys.count - 1)] }
            result["key_p50_ms"] = kp(0.5)
            result["key_p90_ms"] = kp(0.9)
        }
        finish(result)
    }

    private func intervals(_ s: [CFTimeInterval]) -> [CFTimeInterval] {
        s.count < 2 ? [] : (1..<s.count).map { s[$0] - s[$0 - 1] }
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private func finish(_ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        let text = String(decoding: data, as: UTF8.self) + "\n"
        if let out { try? text.write(toFile: out, atomically: true, encoding: .utf8) } else { FileHandle.standardError.write(Data(text.utf8)) }
        done()
    }
}
