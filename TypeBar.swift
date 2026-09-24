// TypeBar.swift — настройки печатной машинки в верхней панели мака.
// Иконка ⌨️: вкл/выкл, waveform на каждую группу клавиш, пауза между
// щелчками, проверка паттернов. Настройки живут в ~/.typeclickrc —
// том же файле, что у CLI-версии typeclick (подхватывает наживую).
// Сборка: make typebar-app.
import AppKit

private var gTap: CFMachPort?

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                            event: CGEvent?, refcon: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout, let t = gTap {
        CGEvent.tapEnable(tap: t, enable: true)
    }
    if type == .keyDown, let e = event {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        TypeBarApp.shared?.handleKey(code)
    }
    guard let e = event else { return nil }
    return Unmanaged.passUnretained(e)
}

final class TypeBarApp: NSObject, NSApplicationDelegate {
    static var shared: TypeBarApp?

    // группа -> waveform 1..6
    var waves = ["key": 4, "space": 5, "tab": 5, "enter": 2, "delete": 1, "esc": 3]
    let groups: [(id: String, title: String)] = [
        ("key", "Буквы"), ("space", "Пробел"), ("tab", "Tab"),
        ("enter", "Ввод"), ("delete", "Стереть"), ("esc", "Esc"),
    ]
    let waveNames = ["", "слабый клик", "сильный клик", "buzz",
                     "лёгкий тап", "средний тап", "сильный тап"]
    var minGapMs = 15.0
    var reps = ["key": 1, "space": 1, "tab": 1, "enter": 2, "delete": 1, "esc": 1]
    var enabled = false

    var item: NSStatusItem!
    var toggleItem: NSMenuItem!
    var groupMenus = [String: [NSMenuItem]]()
    var repMenus = [String: [NSMenuItem]]()
    var gapItems = [NSMenuItem]()
    var driver: HapticDriver?
    var lastFire = -1.0

    var cfgURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".typeclickrc")
    }

    // ---------- запуск ----------

    func applicationDidFinishLaunching(_ notification: Notification) {
        TypeBarApp.shared = self
        loadCfg()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌨️"
        item.menu = buildMenu()
        refreshStates()
        startTap() // сразу включаемся, как демон
    }

    // ---------- меню ----------

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        toggleItem = NSMenuItem(title: "Печатная машинка", action: #selector(toggle),
                                keyEquivalent: "")
        toggleItem.target = self
        m.addItem(toggleItem)

        m.addItem(.separator())

        for g in groups {
            let sub = NSMenu()
            var items = [NSMenuItem]()
            for w in 1 ... 6 {
                let it = NSMenuItem(title: "\(w) — \(waveNames[w])",
                                    action: #selector(pickWave(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = ["group": g.id, "wave": w] as NSDictionary
                sub.addItem(it)
                items.append(it)
            }
            sub.addItem(.separator())
            var ritems = [NSMenuItem]()
            for r in 1 ... 3 {
                let it = NSMenuItem(title: "Повтор ×\(r)", action: #selector(pickRep(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.representedObject = ["repGroup": g.id, "n": r] as NSDictionary
                sub.addItem(it)
                ritems.append(it)
            }
            repMenus[g.id] = ritems
            groupMenus[g.id] = items
            let gi = NSMenuItem(title: g.title, action: nil, keyEquivalent: "")
            gi.submenu = sub
            m.addItem(gi)
        }

        let gapSub = NSMenu()
        for ms in [5, 15, 40] {
            let it = NSMenuItem(title: "\(ms) мс", action: #selector(pickGap(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = ms as NSNumber
            gapSub.addItem(it)
            gapItems.append(it)
        }
        let gapItem = NSMenuItem(title: "Пауза между щелчками", action: nil, keyEquivalent: "")
        gapItem.submenu = gapSub
        m.addItem(gapItem)

        let testSub = NSMenu()
        for w in 1 ... 6 {
            let it = NSMenuItem(title: "\(w) — \(waveNames[w])",
                                action: #selector(testWave(_:)), keyEquivalent: "")
            it.target = self
            it.tag = w
            testSub.addItem(it)
        }
        let testItem = NSMenuItem(title: "Проверка паттернов", action: nil, keyEquivalent: "")
        testItem.submenu = testSub
        m.addItem(testItem)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApp.terminate),
                              keyEquivalent: "q")
        m.addItem(quit)
        return m
    }

    func refreshStates() {
        toggleItem.state = enabled ? .on : .off
        toggleItem.title = enabled ? "Печатная машинка: вкл" : "Печатная машинка: выкл"
        for (id, items) in groupMenus {
            let cur = waves[id] ?? 4
            for it in items {
                let w = (it.representedObject as? NSDictionary)?["wave"] as? Int
                it.state = (w == cur) ? .on : .off
            }
        }
        for it in gapItems {
            it.state = ((it.representedObject as? Int) == Int(minGapMs)) ? .on : .off
        }
        for (id, items) in repMenus {
            let cur = reps[id] ?? 1
            for it in items {
                let n = (it.representedObject as? NSDictionary)?["n"] as? Int
                it.state = (n == cur) ? .on : .off
            }
        }
    }

    @objc func toggle() {
        enabled ? stopTap() : startTap()
        refreshStates()
    }

    @objc func pickWave(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? NSDictionary,
              let g = d["group"] as? String,
              let w = d["wave"] as? Int else { return }
        waves[g] = w
        saveCfg()
        refreshStates()
        burst(group: g) // сразу дать послушать
    }

    @objc func pickRep(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? NSDictionary,
              let g = d["repGroup"] as? String,
              let n = d["n"] as? Int else { return }
        reps[g] = n
        saveCfg()
        refreshStates()
        burst(group: g) // послушать
    }

    /// Паттерн: rep ударов с паузой 70 мс — отличим на любом железе.
    func burst(group g: String) {
        let w = waves[g] ?? 4
        let r = reps[g] ?? 1
        DispatchQueue.global().async { [weak self] in
            for i in 0 ..< r {
                if i > 0 { usleep(70000) }
                self?.driver?.fire(Int32(w))
            }
        }
    }

    @objc func pickGap(_ sender: NSMenuItem) {
        if let ms = sender.representedObject as? Int {
            minGapMs = Double(ms)
            refreshStates()
        }
    }

    @objc func testWave(_ sender: NSMenuItem) {
        ensureDriver()
        driver?.fire(Int32(sender.tag))
    }

    // ---------- перехват клавиш ----------

    func ensureDriver() -> Bool {
        if driver == nil { driver = HapticDriver() }
        return driver != nil
    }

    func startTap() {
        guard ensureDriver() else {
            alert("Нет Taptic Engine", "Не нашлось устройство с вибромотором.")
            return
        }
        if gTap == nil {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: mask,
                                              callback: keyTapCallback,
                                              userInfo: nil) else {
                alert("Нужен доступ",
                      "Открой: Системные настройки → Конфиденциальность → " +
                      "Мониторинг ввода → добавь TypeBar.")
                return
            }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            gTap = tap
        }
        CGEvent.tapEnable(tap: gTap!, enable: true)
        enabled = true
    }

    func stopTap() {
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: false) }
        enabled = false
    }

    func handleKey(_ code: Int) {
        guard enabled else { return }
        let g: String
        switch code {
        case 49: g = "space"
        case 48: g = "tab"
        case 36: g = "enter"
        case 51: g = "delete"
        case 53: g = "esc"
        case 54, 55, 58, 59, 60, 61, 62, 63: return // модификаторы молчат
        default: g = "key"
        }
        let now = mono()
        if now - lastFire < minGapMs / 1000.0 { return }
        lastFire = now
        burst(group: g)
    }

    func mono() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
    }

    // ---------- конфиг ~/.typeclickrc (общий с CLI) ----------

    func loadCfg() {
        guard let s = try? String(contentsOf: cfgURL, encoding: .utf8) else { return }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let kv = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2, waves[kv[0]] != nil else { continue }
            // формат: W или WxR
            let parts = kv[1].split(separator: "x", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let w = Int(parts[0]), (1 ... 6).contains(w) else { continue }
            var r = 1
            if parts.count > 1 {
                guard let rr = Int(parts[1]), (1 ... 4).contains(rr) else { continue }
                r = rr
            }
            waves[kv[0]] = w
            reps[kv[0]] = r
        }
    }

    func saveCfg() {
        let order = ["key", "space", "tab", "enter", "delete", "esc"]
        let s = order.map { g -> String in
            let w = waves[g] ?? 4
            let r = reps[g] ?? 1
            return r == 1 ? "\(g)=\(w)" : "\(g)=\(w)x\(r)"
        }.joined(separator: "\n") + "\n"
        try? s.write(to: cfgURL, atomically: true, encoding: .utf8)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
