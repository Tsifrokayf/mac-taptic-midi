// TypeBar.swift — настройки печатной машинки в верхней панели мака.
// Иконка ⌨️: вкл/выкл, waveform на каждую группу клавиш, пауза между
// щелчками, проверка паттернов. Настройки живут в ~/.typeclickrc —
// том же файле, что у CLI-версии typeclick (подхватывает наживую).
// Сборка: make typebar-app.
import AppKit
import IOKit
import IOKit.hid

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

// ---------- клавиатуры напрямую через HID (без доступа вообще) ----------
// Event tap точен, но требует «Мониторинг ввода», который может не липнуть
// к ad-hoc сборке. HID читает те же нажатия как ввод с устройства —
// доступ не нужен. Использование HID 0x07: 0x2C пробел, 0x28 ввод,
// 0x2A стереть, 0x29 esc, 0x2B tab, 0xE0–0xE7 модификаторы.

private var sharedHID: HIDKeys?

private func hidValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                              sender: UnsafeMutableRawPointer?, value: IOHIDValue?) {
    guard let v = value else { return }
    sharedHID?.handleValue(sender: sender, value: v)
}

final class HIDKeys {
    var onUsage: ((UInt32) -> Void)?
    private var mgr: IOHIDManager?
    private struct DK: Hashable { var d: UInt; var u: UInt32 }
    private var pressed = [DK: Double]()
    private(set) var keyboardCount = 0
    var diag = ""

    init?() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault,
                                   IOOptionBits(kIOHIDOptionsTypeNone))
        // Фильтр нужен: без него CopyDevices отдаёт nil.
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: NSNumber(value: UInt32(0x01)),
            kIOHIDDeviceUsageKey as String: NSNumber(value: UInt32(0x06)),
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, hidValueCallback, nil)
        // колбэки едут на ранлуп вызывавшего — звать только с main
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(),
                                        CFRunLoopMode.defaultMode.rawValue as CFString)
        mgr = m
        sharedHID = self
    }

    private var devicesReady = false

    /// Открыть устройства. Возвращает true, если есть хоть одна клавиатура.
    /// Open менеджера часто отдаёт ExclusiveAccess (устройства держит
    /// Karabiner) — игнорируем и цепляем колбэки напрямую к устройствам:
    /// IOHIDDeviceOpen + RegisterInputValueCallback на каждое.
    func start() -> Bool {
        guard let m = mgr else { return false }
        if !devicesReady {
            devicesReady = true
            let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
            var n = 0
            var openOk = 0
            if let raw = IOHIDManagerCopyDevices(m) {
                let cf = raw as CFSet
                let c = CFSetGetCount(cf)
                if c > 0 {
                    let vals = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: c)
                    defer { vals.deallocate() }
                    CFSetGetValues(cf, vals)
                    for i in 0 ..< c {
                        guard let p = vals[i] else { continue }
                        let dev = Unmanaged<IOHIDDevice>.fromOpaque(p).takeUnretainedValue()
                        let pg = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int
                        let us = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int
                        guard pg == 0x01 && us == 0x06 else { continue }
                        n += 1
                        if IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                            openOk += 1
                            IOHIDDeviceRegisterInputValueCallback(dev, hidValueCallback, nil)
                            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(),
                                                           CFRunLoopMode.defaultMode.rawValue as CFString)
                        }
                    }
                }
            }
            diag = String(format: "open=0x%x kb=%d devopen=%d",
                          UInt32(bitPattern: Int32(r)), n, openOk)
            keyboardCount = n
        }
        return keyboardCount > 0
    }

    // Два стиля отчётов:
    //  - per-key: usage клавиши в ЭЛЕМЕНТЕ, значение 0/1;
    //  - массив: в элементе мусор (0/0xFFFFFFFF), а в ЗНАЧЕНИИ упакованы
    //    сразу два usage (hi16|lo16 — видно в живом логе: 0x190009 и т.п.),
    //    0 = слот освободился (какая именно клавиша ушла — неизвестно).
    fileprivate func handleValue(sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(el) == 0x07 else { return }
        let eu = IOHIDElementGetUsage(el)
        let iv = IOHIDValueGetIntegerValue(value)
        let now = Date().timeIntervalSinceReferenceDate
        var dev: UInt = 0
        if let s = sender { dev = UInt(bitPattern: Int(bitPattern: s)) }
        if eu == 0 || eu == 0xFFFFFFFF {
            // стиль «массив»
            if iv == 0 {
                // слот освободился — чистим залипшее этого устройства
                pressed = pressed.filter { $0.key.d != dev }
            } else {
                // в значении до двух usages: hi16 и lo16
                let halves = [UInt32(iv & 0xFFFF), UInt32((iv >> 16) & 0xFFFF)]
                for u in halves where u >= 1 && u <= 0xE7 {
                    let k = DK(d: dev, u: u)
                    if pressed[k] == nil {
                        pressed[k] = now
                        onUsage?(u)
                    }
                }
            }
        } else {
            // стиль «per-key»
            let k = DK(d: dev, u: eu)
            if iv != 0 {
                if pressed[k] == nil {
                    pressed[k] = now
                    onUsage?(eu)
                }
            } else {
                pressed.removeValue(forKey: k)
            }
        }
        for (k, v) in pressed where now - v > 3 { pressed.removeValue(forKey: k) }
    }
}

final class TypeBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    var repGapMs = 120.0 // пауза между ударами паттерна (общая с CLI: repgap=)
    var master = 100.0 // мастер-сила 10..300: лесенка волн + повторы
    var strengthSlider: NSSlider!
    var strengthLabel: NSTextField!
    var lastPreview = -1.0
    var lastHover = -1.0
    var reps = ["key": 1, "space": 1, "tab": 1, "enter": 2, "delete": 1, "esc": 1]
    var enabled = false
    var wantOn = true // хочет ли пользователь включённый режим

    var item: NSStatusItem!
    var toggleItem: NSMenuItem!
    var sourceItem: NSMenuItem!
    var groupMenus = [String: [NSMenuItem]]()
    var repMenus = [String: [NSMenuItem]]()
    var gapItems = [NSMenuItem]()
    var driver: HapticDriver?
    var lastFire = -1.0
    var hid: HIDKeys?
    var source = "—"
    var lastOutcome = ""

    /// Диагностика в файл (меню для этого слишком тесно).
    func dlog(_ s: String, always: Bool = false) {
        if !always && s == lastOutcome { return }
        lastOutcome = s
        let line = "\(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: "/tmp/typebar.log") {
            fh.seekToEndOfFile()
            fh.write(d)
            fh.closeFile()
        } else {
            try? line.write(toFile: "/tmp/typebar.log", atomically: true, encoding: .utf8)
        }
    }

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
        startTap() // сразу включаемся, как демон
        refreshStates() // после startTap: там уже известны источник и статус
        // Тихий повтор каждые 3 с, пока не включимся: покрывает случай,
        // когда доступ дали уже после запуска (окно активации может не прийти
        // агентному приложению, а модальный алерт вообще стопает ранлуп).
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.wantOn && !self.enabled {
                self.startTap(showAlert: false)
                self.refreshStates()
            }
        }
    }

    // Сюда попадаем, когда пользователь возвращается из Настроек, —
    // пробуем включиться тихо: доступ могли только что дать.
    func applicationDidBecomeActive(_ notification: Notification) {
        if wantOn && !enabled {
            startTap(showAlert: false)
            refreshStates()
        }
    }

    // ---------- меню ----------

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        toggleItem = NSMenuItem(title: "Печатная машинка", action: #selector(toggle),
                                keyEquivalent: "")
        toggleItem.target = self
        m.addItem(toggleItem)

        sourceItem = NSMenuItem(title: "Источник: —", action: nil, keyEquivalent: "")
        sourceItem.isEnabled = false
        m.addItem(sourceItem)

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

        // Мастер-сила 10..300 широким ползунком + живое превью при движении.
        let stItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let sview = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 52))
        strengthLabel = NSTextField(labelWithString: "Сила: \(Int(master))%")
        strengthLabel.font = .systemFont(ofSize: 12)
        strengthLabel.frame = NSRect(x: 14, y: 30, width: 120, height: 16)
        strengthLabel.isEditable = false
        strengthLabel.isBordered = false
        strengthLabel.backgroundColor = .clear
        strengthSlider = NSSlider(value: master, minValue: 10, maxValue: 300,
                                  target: self, action: #selector(strengthChanged(_:)))
        strengthSlider.frame = NSRect(x: 12, y: 6, width: 206, height: 20)
        strengthSlider.isContinuous = true
        sview.addSubview(strengthLabel)
        sview.addSubview(strengthSlider)
        stItem.view = sview
        m.addItem(stItem)

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

        demoItem = NSMenuItem(title: "▶ Демо режимов", action: #selector(demoToggle),
                              keyEquivalent: "")
        demoItem.target = self
        m.addItem(demoItem)

        demoStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        demoStatusItem.isEnabled = false
        m.addItem(demoStatusItem)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApp.terminate),
                              keyEquivalent: "q")
        m.addItem(quit)
        for item in m.items {
            item.submenu?.delegate = self
        }
        return m
    }

    func refreshStates() {
        toggleItem.state = enabled ? .on : .off
        toggleItem.title = enabled ? "Печатная машинка: вкл" : "Печатная машинка: выкл"
        sourceItem.title = "Источник: \(source)"
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
        strengthSlider.doubleValue = master
        strengthLabel.stringValue = "Сила: \(Int(master))%"
        for (id, items) in repMenus {
            let cur = reps[id] ?? 1
            for it in items {
                let n = (it.representedObject as? NSDictionary)?["n"] as? Int
                it.state = (n == cur) ? .on : .off
            }
        }
    }

    @objc func toggle() {
        if enabled {
            wantOn = false
            stopTap()
        } else {
            wantOn = true
            startTap()
        }
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

    /// Паттерн группы как настроен; громкость — мастер-слайдер (амплитуда).
    func burst(group g: String) {
        let w = waves[g] ?? 4
        let r = reps[g] ?? 1
        let gap = UInt32(repGapMs * 1000)
        let amp = masterAmp
        DispatchQueue.global().async { [weak self] in
            var ok = false
            for i in 0 ..< r {
                if i > 0 { usleep(gap) }
                ok = self?.driver?.fire(Int32(w), intensity: amp) ?? false
            }
            self?.dlog("fire \(g)=\(w)x\(r) amp=\(amp) ok=\(ok)", always: true)
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

    // ----- мастер-сила 10..300% = амплитуда 0.1..2.0 -----

    /// Мастер-слайдер напрямую в амплитуду актуатора.
    var masterAmp: Float { min(max(Float(master) / 100, 0.1), 2.0) }

    @objc func strengthChanged(_ sender: NSSlider) {
        master = sender.doubleValue
        strengthLabel.stringValue = "Сила: \(Int(master))%"
        saveCfg()
        // живое превью прямо во время движения (троттлинг 150 мс)
        let now = mono()
        if now - lastPreview > 0.15 {
            lastPreview = now
            previewMaster()
        }
    }

    /// Превью мастера: паттерн группы «Буквы» с текущей громкостью.
    func previewMaster() {
        ensureDriver()
        let w = waves["key"] ?? 4
        let r = reps["key"] ?? 1
        let gap = UInt32(repGapMs * 1000)
        let amp = masterAmp
        DispatchQueue.global().async { [weak self] in
            for i in 0 ..< r {
                if i > 0 { usleep(gap) }
                _ = self?.driver?.fire(Int32(w), intensity: amp)
            }
        }
    }

    // Превью вибрации при наведении на эффект (и в группах, и в проверке).
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let it = item else { return }
        var w: Int?
        if let d = it.representedObject as? NSDictionary,
           let ww = d["wave"] as? Int {
            w = ww
        } else if it.action == #selector(testWave(_:)) {
            w = it.tag
        }
        guard let wave = w, (1 ... 6).contains(wave) else { return }
        let now = mono()
        guard now - lastHover > 0.25 else { return }
        lastHover = now
        ensureDriver()
        driver?.fire(Int32(wave))
    }

    // ----- демо: все группы по очереди, чтобы сравнить режимы -----

    var demoItem: NSMenuItem!
    var demoStatusItem: NSMenuItem!
    var isDemo = false
    var stopDemoFlag = false

    @objc func demoToggle() {
        if isDemo {
            stopDemoFlag = true
            return
        }
        guard ensureDriver() else {
            alert("Нет Taptic Engine", "Не нашлось устройство с вибромотором.")
            return
        }
        isDemo = true
        stopDemoFlag = false
        demoItem.title = "■ Стоп демо"
        demoSay("Палец на трекпад…")
        DispatchQueue.global().async { [weak self] in self?.runDemo() }
    }

    func demoSay(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.demoStatusItem.title = s }
    }

    func runDemo() {
        // Демо различимого: одиночки 1/2/4/5/6 на этом железе сливаются,
        // поэтому идём по контрастным паттернам.
        let steps: [(String, [Int])] = [
            ("Одиночный", [4]),
            ("Двойной", [5, 5]),
            ("Тройной", [6, 6, 6]),
            ("Buzz", [3]),
            ("Мощный", [2, 6]),
        ]
        let gap = UInt32(repGapMs * 1000)
        for (i, s) in steps.enumerated() {
            if stopDemoFlag { break }
            demoSay("▶ [\(i + 1)/\(steps.count)] \(s.0)")
            for (j, w) in s.1.enumerated() {
                if stopDemoFlag { break }
                if j > 0 { usleep(gap) }
                _ = driver?.fire(Int32(w))
            }
            for _ in 0 ..< 14 {
                if stopDemoFlag { break }
                usleep(100000)
            }
        }
        let stopped = stopDemoFlag
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isDemo = false
            self.demoItem.title = "▶ Демо режимов"
            self.demoStatusItem.title = stopped ? "Демо остановлено" : "Демо готово ✅"
        }
    }

    // ---------- перехват клавиш ----------

    func ensureDriver() -> Bool {
        if driver == nil { driver = HapticDriver() }
        return driver != nil
    }

    func startTap(showAlert: Bool = true) {
        guard ensureDriver() else {
            source = "нет Taptic"
            dlog("driver=nil")
            if showAlert {
                alert("Нет Taptic Engine", "Не нашлось устройство с вибромотором.")
            }
            return
        }
        dlog("driver=ok")
        // 1. event tap: точен, но требует «Мониторинг ввода»
        if gTap == nil {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: keyTapCallback,
                                           userInfo: nil) {
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
                gTap = tap
            }
        }
        if let t = gTap {
            CGEvent.tapEnable(tap: t, enable: true)
            enabled = true
            source = "тап"
            dlog("tap=ok")
            return
        }
        dlog("tap=nil")
        // 2. фолбэк: HID-клавиатуры напрямую, доступ вообще не нужен
        if hid == nil {
            let h = HIDKeys()
            h?.onUsage = { [weak self] u in
                self?.dlog(String(format: "key 0x%x", u), always: true)
                self?.handleUsage(u)
            }
            hid = h
        }
        if let h = hid, h.start(), h.keyboardCount > 0 {
            enabled = true
            source = "HID (\(h.keyboardCount) клав.)"
            dlog("hid=ok n=\(h.keyboardCount)")
            return
        }
        if let h = hid {
            source = "HID? \(h.diag)"
            dlog("hid=fail \(h.diag)")
            refreshStates()
        }
        if showAlert {
            alert("Не вижу клавиатуру",
                  "Event tap без доступа, а HID-устройств не нашлось.\n\n" +
                  "Дай доступ: Системные настройки → Конфиденциальность → " +
                  "Мониторинг ввода → добавь TypeBar, затем выйди и запусти заново.")
        }
    }

    func stopTap() {
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: false) }
        enabled = false
    }

    func handleKey(_ code: Int) {
        guard enabled, !isDemo else { return }
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
        fireGroup(g)
    }

    /// Та же таблица, но для HID-usage (0x07): пробел 0x2C, ввод 0x28,
    /// стереть 0x2A, esc 0x29, tab 0x2B, модификаторы 0xE0–0xE7 молчат.
    func handleUsage(_ usage: UInt32) {
        guard enabled, !isDemo else { return }
        let g: String
        switch usage {
        case 0x2C: g = "space"
        case 0x2B: g = "tab"
        case 0x28: g = "enter"
        case 0x2A: g = "delete"
        case 0x29: g = "esc"
        case 0xE0...0xE7: return
        default: g = "key"
        }
        fireGroup(g)
    }

    func fireGroup(_ g: String) {
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
            guard kv.count == 2 else { continue }
            if kv[0] == "master" {
                if let n = Double(kv[1]), (10 ... 300).contains(n) {
                    master = n
                }
                continue
            }
            if kv[0] == "repgap" {
                if let n = Int(kv[1]), (20 ... 500).contains(n) { repGapMs = Double(n) }
                continue
            }
            guard waves[kv[0]] != nil else { continue }
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
        }.joined(separator: "\n") + "\nrepgap=\(Int(repGapMs))\nmaster=\(Int(master))\n"
        try? s.write(to: cfgURL, atomically: true, encoding: .utf8)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
