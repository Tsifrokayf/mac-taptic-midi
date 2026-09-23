// RhythmGame.swift — ритм-игра на трекпаде: ноты падают, тапай в ритм.
// Ноты берутся из MIDI (через midi_haptic --dry-run), тапы детектятся
// приватным MultitouchSupport.framework (как в mactic), удары — Taptic Engine.
// Сборка: make rhythm-app. Тест: open -a RhythmGame.app song.mid (сам играет).
import AppKit
import Foundation

// ---------- общее ----------

func toolPath(_ name: String) -> String {
    let exe = Bundle.main.executablePath ?? ""
    let dir = (exe as NSString).deletingLastPathComponent
    let nextTo = (dir as NSString).appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: nextTo) { return nextTo }
    let cwd = FileManager.default.currentDirectoryPath + "/" + name
    if FileManager.default.isExecutableFile(atPath: cwd) { return cwd }
    return nextTo
}

func mono() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}

// ---------- детект тапов по трекпаду ----------

// MTTouch: pathIndex +16 (int32), state +20 (int32), шаг 96 байт.
// Тап = контакт (3/4/5/6) короче 350 мс. Время — наши моно-часы в момент колбэка.

private var sharedTap: TouchTap?

private func tapCallback(_ device: UnsafeRawPointer?, _ touches: UnsafeRawPointer?,
                         _ n: Int32, _ ts: Double, _ frame: Int32) {
    sharedTap?.handle(touches: touches, n: n)
}

final class TouchTap {
    typealias FnList = @convention(c) () -> UnsafeRawPointer?
    typealias FnReg = @convention(c) (UnsafeRawPointer,
        @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void) -> Void
    typealias FnStart = @convention(c) (UnsafeRawPointer, Int32) -> Void
    typealias FnStop = @convention(c) (UnsafeRawPointer) -> Void

    var onTap: ((Double) -> Void)?

    private var fnStart: FnStart?
    private var fnStop: FnStop?
    private var devices: CFArray?
    private var device: UnsafeRawPointer?
    private var presses = [Int32: Double]()
    private let lock = NSLock()
    private var running = false

    init?() {
        guard let h = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY) else { return nil }
        func sym<T>(_ n: String) -> T? {
            guard let s = dlsym(h, n) else { return nil }
            return unsafeBitCast(s, to: T.self)
        }
        let fnList: FnList? = sym("MTDeviceCreateList")
        let fnReg: FnReg? = sym("MTRegisterContactFrameCallback")
        fnStart = sym("MTDeviceStart")
        fnStop = sym("MTDeviceStop")
        guard let fl = fnList, let fr = fnReg,
              fnStart != nil, fnStop != nil else { return nil }
        guard let listPtr = fl() else { return nil }
        let arr = Unmanaged<CFArray>.fromOpaque(listPtr).takeRetainedValue()
        guard CFArrayGetCount(arr) > 0,
              let dev = CFArrayGetValueAtIndex(arr, 0) else { return nil }
        devices = arr
        device = UnsafeRawPointer(dev)
        sharedTap = self
        fr(device!, tapCallback)
    }

    /// Вызывать с main-потока (колбэки едут на ранлуп вызывавшего).
    func start() {
        guard !running, let dev = device else { return }
        running = true
        fnStart!(dev, 0)
    }

    func stop() {
        guard running, let dev = device else { return }
        running = false
        fnStop!(dev)
        lock.lock()
        presses.removeAll()
        lock.unlock()
    }

    fileprivate func handle(touches: UnsafeRawPointer?, n: Int32) {
        guard let t = touches, n > 0 else { return }
        let now = mono()
        var taps = [Double]()
        lock.lock()
        for i in 0 ..< Int(n) {
            let base = t.advanced(by: i * 96)
            let path: Int32 = base.load(fromByteOffset: 16, as: Int32.self)
            let state: Int32 = base.load(fromByteOffset: 20, as: Int32.self)
            if state == 3 || state == 4 || state == 5 || state == 6 {
                if presses[path] == nil { presses[path] = now }
            } else {
                if let t0 = presses.removeValue(forKey: path) {
                    if now - t0 < 0.35 { taps.append(t0) }
                }
            }
        }
        // чистка залипших
        for (k, v) in presses where now - v > 3 { presses.removeValue(forKey: k) }
        lock.unlock()
        for tap in taps { onTap?(tap) }
    }
}

// ---------- падающие ноты ----------

final class NoteView: NSView {
    weak var game: RhythmGame?
    override var isFlipped: Bool { true } // y растёт вниз — удобно падать

    override func draw(_ dirtyRect: NSRect) {
        guard let g = game else { return }
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        dirtyRect.fill()

        let midX = bounds.width / 2
        let now = mono()

        // линия удара
        if let last = g.lastHit, now - last.0 < 0.25 {
            (last.1 == 0 ? NSColor.systemGreen : NSColor.systemYellow).setFill()
        } else {
            NSColor.white.setFill()
        }
        NSRect(x: 40, y: g.hitY - 3, width: bounds.width - 80, height: 6).fill()

        // обратный отсчёт
        if now < g.startTime {
            let left = g.startTime - now
            let s = "Палец на трекпад! \(Int(ceil(left)))"
            drawCentered(s, size: 26, y: bounds.height / 2)
            return
        }

        // ноты
        for (i, t) in g.chart.enumerated() {
            if g.judged[i] { continue }
            let dt = t - now
            if dt < -0.3 || dt > 4 { continue }
            let y = g.hitY + CGFloat(dt) * g.speed
            let r: CGFloat = 16
            if dt < 0 { NSColor.systemGray.setFill() }
            else { NSColor.white.setFill() }
            let bp = NSBezierPath(ovalIn: NSRect(x: midX - r, y: y - r, width: r * 2, height: r * 2))
            bp.fill()
            _ = i
        }

        // конец
        if g.finished {
            drawCentered("Стоп! Смотри результат ↓", size: 22, y: bounds.height / 2)
        }
    }

    private func drawCentered(_ s: String, size: CGFloat, y: CGFloat) {
        let a = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: size),
                 NSAttributedString.Key.foregroundColor: NSColor.white]
        let ns = NSAttributedString(string: s, attributes: a)
        let sz = ns.size()
        ns.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: y))
    }
}

// ---------- игра ----------

final class RhythmGame: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: NoteView!
    var scoreLabel = NSTextField(labelWithString: "Перетащи MIDI — ноты упадут, тапай по трекпаду в ритм")
    var fileLabel = NSTextField(labelWithString: "Файл не выбран")
    var diffPopup: NSPopUpButton!
    var playBtn: NSButton!
    var stopBtn: NSButton!

    var chart = [Double]()
    var judged = [Bool]()
    var idx = 0
    var perfect = 0, good = 0, miss = 0, combo = 0, maxCombo = 0
    var startTime = 0.0
    var playing = false
    var finished = false
    var lastHit: (Double, Int)? // (время, 0 perfect / 1 good)
    var lastErr = ""
    var timer: Timer?

    var driver: HapticDriver?
    var taps: TouchTap?
    var pendingOpen: [URL] = []

    // окна судейства по сложности (perfect / miss), good = miss
    var perfectWin = 0.06, missWin = 0.15
    let hitY: CGFloat = 420
    let speed: CGFloat = 280 // px в секунду

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        log("Движок нот: \(toolPath("midi_haptic"))")
        if !pendingOpen.isEmpty {
            let u = pendingOpen
            pendingOpen = []
            openURLs(u)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if window == nil {
            pendingOpen += urls
            return
        }
        openURLs(urls)
    }

    func openURLs(_ urls: [URL]) {
        let m = urls.map { $0.path }.filter {
            ["mid", "midi"].contains(($0 as NSString).pathExtension.lowercased())
        }
        if let f = m.first {
            loadChart(f)
            if !playing { startGame() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { stopGame() }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Ритм-игра на трекпаде"
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        window.contentView = root

        let title = NSTextField(labelWithString: "Тапай по трекпаду в ритм")
        title.font = .boldSystemFont(ofSize: 17)
        root.addArrangedSubview(title)

        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        scoreLabel.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(scoreLabel)

        view = NoteView()
        view.game = self
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 460).isActive = true
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        root.addArrangedSubview(view)

        fileLabel.font = .systemFont(ofSize: 12)
        fileLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(fileLabel)

        let row = NSStackView()
        row.spacing = 8
        diffPopup = NSPopUpButton()
        diffPopup.addItems(withTitles: ["Легко", "Норма", "Сложно"])
        diffPopup.selectItem(at: 1)
        row.addArrangedSubview(diffPopup)
        let sel = NSButton(title: "Выбрать MIDI…", target: self, action: #selector(chooseFile))
        playBtn = NSButton(title: "▶ Играть", target: self, action: #selector(startGame))
        stopBtn = NSButton(title: "■ Стоп", target: self, action: #selector(stopGame))
        stopBtn.isEnabled = false
        row.addArrangedSubview(sel)
        row.addArrangedSubview(playBtn)
        row.addArrangedSubview(stopBtn)
        root.addArrangedSubview(row)

        window.makeKeyAndOrderFront(nil)
    }

    @objc func chooseFile() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["mid", "midi"]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { loadChart(u.path) }
    }

    func log(_ s: String) {
        scoreLabel.stringValue = s
    }

    // ----- ноты из MIDI через движок -----

    @discardableResult
    func loadChart(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: toolPath("midi_haptic"))
        p.arguments = [path, "-n"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run(); p.waitUntilExit()
        } catch {
            log("Не запустился midi_haptic"); return false
        }
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                       encoding: .utf8) ?? ""
        var times = [Double]()
        for line in s.components(separatedBy: "\n") {
            guard line.hasPrefix("["),
                  let end = line.firstIndex(of: "]") else { continue }
            let num = line[line.index(after: line.startIndex) ..< end]
                .trimmingCharacters(in: .whitespaces)
            if let t = Double(num) { times.append(t) }
        }
        guard !times.isEmpty else { log("В MIDI нет нот"); return false }
        chart = times
        fileLabel.stringValue = "Файл: \((path as NSString).lastPathComponent) — нот: \(times.count)"
        log("Нот: \(times.count), длительность: \(String(format: "%.1f", times.last ?? 0)) c — жми ▶")
        return true
    }

    // ----- игра -----

    @objc func startGame() {
        if playing { return }
        if chart.isEmpty { log("Сначала выбери MIDI"); return }
        switch diffPopup.indexOfSelectedItem {
        case 0: perfectWin = 0.09; missWin = 0.18
        case 2: perfectWin = 0.04; missWin = 0.11
        default: perfectWin = 0.06; missWin = 0.15
        }
        if driver == nil { driver = HapticDriver() }
        if taps == nil {
            taps = TouchTap()
            taps?.onTap = { [weak self] t in
                DispatchQueue.main.async { self?.onTap(t) }
            }
        }
        guard driver != nil, taps != nil else {
            log("Нет Taptic Engine / тач-монитора"); return
        }
        judged = [Bool](repeating: false, count: chart.count)
        idx = 0
        perfect = 0; good = 0; miss = 0; combo = 0; maxCombo = 0
        lastHit = nil; lastErr = ""
        finished = false
        playing = true
        startTime = mono() + 2.0
        taps?.start()
        playBtn.isEnabled = false
        stopBtn.isEnabled = true
        log("Приготовься…")
        // отсчёт
        for (i, d) in [1.5, 1.0, 0.5].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                if self?.playing == true { NSSound(named: "Tink")?.play() }
                _ = i
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) {
            [weak self] _ in self?.tick()
        }
    }

    @objc func stopGame() {
        playing = false
        timer?.invalidate(); timer = nil
        taps?.stop()
        playBtn?.isEnabled = true
        stopBtn?.isEnabled = false
        view?.needsDisplay = true
    }

    func tick() {
        if !playing { return }
        let now = mono()
        // пропущенные
        while idx < chart.count && !judged[idx] && chart[idx] < now - missWin {
            judged[idx] = true
            idx += 1
            miss += 1; combo = 0
            updateScore()
        }
        while idx < chart.count && judged[idx] { idx += 1 }
        view.needsDisplay = true
        if now > (chart.last ?? 0.0) + 1.0 {
            finishGame()
        }
    }

    func onTap(_ t: Double) {
        if !playing || t < startTime { return }
        // ближайшая несуженая нота
        var best = -1
        var bestDt = Double.greatestFiniteMagnitude
        for i in max(0, idx - 3) ..< min(chart.count, idx + 4) {
            if judged[i] { continue }
            let dt = abs(chart[i] - t)
            if dt < bestDt { bestDt = dt; best = i }
        }
        guard best >= 0, bestDt <= missWin else { return } // мимо нот — мимо
        judged[best] = true
        let err = chart[best] - t
        lastErr = String(format: "%+.0f мс", err * 1000)
        if bestDt <= perfectWin {
            perfect += 1; combo += 1
            lastHit = (mono(), 0)
            driver?.fire(2)
        } else {
            good += 1; combo += 1
            lastHit = (mono(), 1)
            driver?.fire(5)
        }
        maxCombo = max(maxCombo, combo)
        updateScore()
        view.needsDisplay = true
    }

    func updateScore() {
        let score = perfect * 300 + good * 100
        let total = max(1, perfect + good + miss)
        let acc = (Double(perfect) + Double(good) * 0.5) / Double(total) * 100
        scoreLabel.stringValue =
            "Счёт \(score) · комбо \(combo) · P\(perfect) G\(good) M\(miss) · \(lastErr)"
        _ = acc
    }

    func finishGame() {
        stopGame()
        finished = true
        let total = max(1, perfect + good + miss)
        let acc = (Double(perfect) + Double(good) * 0.5) / Double(total) * 100
        let rank: String
        switch acc {
        case 95...: rank = "S"
        case 85..<95: rank = "A"
        case 70..<85: rank = "B"
        default: rank = "C"
        }
        scoreLabel.stringValue =
            "Финиш! P\(perfect) G\(good) M\(miss) · точность \(String(format: "%.1f", acc))% " +
            "· max-комбо \(maxCombo) · ранг \(rank)"
        view.needsDisplay = true
    }
}
