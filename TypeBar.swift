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
    if let e = event {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown: TypeBarApp.shared?.handleKey(code, flags: e.flags)
        case .keyUp: TypeBarApp.shared?.handleKeyUp(code)
        default: break
        }
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
    var onRelease: ((UInt32) -> Void)? // клавиша отпущена (для удержания)
    private var mgr: IOHIDManager?
    private struct DK: Hashable { var d: UInt; var u: UInt32 }
    private var pressed = [DK: Double]()
    private(set) var keyboardCount = 0
    var diag = ""

    // Фильтр внешних клавиатур: встроенную HID видит по свойству
    // «Built-In = 1» (Apple Internal Keyboard), Karabiner-виртуалку
    // ловим по Manufacturer = pqrs.org. Event tap таких данных не отдаёт,
    // поэтому фильтр работает только на этом пути.
    var filterExternal = false
    private var builtInDev = [UInt: Bool]()
    private(set) var builtinCount = 0
    private(set) var externalCount = 0

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
                        let isBuiltIn =
                            (IOHIDDeviceGetProperty(dev, "Built-In" as CFString) as? NSNumber)?.boolValue == true
                            || (IOHIDDeviceGetProperty(dev, "Manufacturer" as CFString) as? String) == "pqrs.org"
                        let dp = UInt(bitPattern: Int(bitPattern: p))
                        builtInDev[dp] = isBuiltIn
                        if isBuiltIn { builtinCount += 1 } else { externalCount += 1 }
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
        // Внешняя клавиатура при включённом фильтре не дёргает приложение
        // (слежку pressed ведём всегда — модификаторы нужны для комбо).
        func fire(_ u: UInt32) {
            if !filterExternal || (builtInDev[dev] ?? true) { onUsage?(u) }
        }
        if eu == 0 || eu == 0xFFFFFFFF {
            // стиль «массив»
            if iv == 0 {
                // слот освободился — чистим залипшее этого устройства
                pressed = pressed.filter { $0.key.d != dev }
                if !filterExternal || (builtInDev[dev] ?? true) { onRelease?(0) }
            } else {
                // в значении до двух usages: hi16 и lo16
                let halves = [UInt32(iv & 0xFFFF), UInt32((iv >> 16) & 0xFFFF)]
                for u in halves where u >= 1 && u <= 0xE7 {
                    let k = DK(d: dev, u: u)
                    if pressed[k] == nil {
                        pressed[k] = now
                        fire(u)
                    }
                }
            }
        } else {
            // стиль «per-key»
            let k = DK(d: dev, u: eu)
            if iv != 0 {
                if pressed[k] == nil {
                    pressed[k] = now
                    fire(eu)
                }
            } else {
                pressed.removeValue(forKey: k)
                if !filterExternal || (builtInDev[dev] ?? true) { onRelease?(eu) }
            }
        }
        for (k, v) in pressed where now - v > 3 { pressed.removeValue(forKey: k) }
    }

    /// Зажатые модификаторы (0xE0 LCtrl … 0xE7 RGUI) — для комбо в HID.
    func modsHeld() -> Set<UInt32> {
        Set(pressed.keys.map(\.u).filter { (0xE0 ... 0xE7).contains($0) })
    }
}

final class TypeBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: TypeBarApp?

    // группа -> waveform 1..6
    var waves = ["key": 4, "space": 5, "tab": 5, "enter": 2, "delete": 1,
                 "esc": 3, "arrow": 5, "nav": 5]
    let groups: [(id: String, title: String)] = [
        ("key", "Буквы"), ("space", "Пробел"), ("tab", "Tab"),
        ("enter", "Ввод"), ("delete", "Стереть"), ("esc", "Esc"),
        ("arrow", "Стрелки"), ("nav", "Навигация"),
    ]
    let waveNames = ["", "слабый клик", "сильный клик", "buzz",
                     "лёгкий тап", "средний тап", "сильный тап"]
    var minGapMs = 15.0
    var repGapMs = 120.0 // пауза между ударами паттерна (общая с CLI: repgap=)
    var master = 500.0 // мастер-сила 10..500: амплитуда 0.1..5.0
    var strengthSlider: NSSlider!
    var strengthLabel: NSTextField!
    var lastPreview = -1.0
    var lastHover = -1.0
    var reps = ["key": 1, "space": 1, "tab": 1, "enter": 2, "delete": 1,
                "esc": 1, "arrow": 1, "nav": 1]
    var enabled = false
    var wantOn = true // хочет ли пользователь включённый режим

    // --- настройки нового поколения (все живут в ~/.typeclickrc) ---
    var soundOn = true          // звук щелчка
    var soundVol = 60.0         // 0..100
    var soundPick = 1           // 1...4 встроенный, 0 — свой файл
    var soundFile = ""          // путь soundfile=
    var indOn = true            // мигание иконки при нажатии
    var statOn = true           // счётчик щелчков в меню
    var holdOn = false          // гул, пока клавиша зажата
    var holdGapMs = 100.0       // период гула 50..400 мс
    var comboOn = false         // реагировать на Cmd+C и т.п.
    var combos = [String: String]() // "cmd+c" -> "3x2"; nil = как у «Остальные»
    var extkbOn = true          // вибрировать ли на внешних клавиатурах
    var presetKey = "custom"    // quiet | normal | loud | custom
    var profileKey = ""         // имя последнего профиля
    var stats = [String: Int]() // счётчики за сессию: группа -> N

    /// Доступные комбо: точные строки конфига combo.<id>=WxR.
    static let comboKeys: [(id: String, title: String)] = [
        ("cmd+c", "Cmd+C"), ("cmd+v", "Cmd+V"), ("cmd+x", "Cmd+X"),
        ("cmd+z", "Cmd+Z"), ("cmd+a", "Cmd+A"), ("cmd+s", "Cmd+S"),
        ("cmd+f", "Cmd+F"), ("cmd+q", "Cmd+Q"), ("cmd+w", "Cmd+W"),
        ("any", "Остальные комбинации"),
    ]
    static let presetKeys: [(id: String, title: String)] = [
        ("quiet", "Тихий"), ("normal", "Обычный"),
        ("loud", "Мощный"), ("custom", "Свой"),
    ]

    var item: NSStatusItem!
    var toggleItem: NSMenuItem!
    var sourceItem: NSMenuItem!
    var autoStartItem: NSMenuItem!
    var soundItem: NSMenuItem!
    var statsItem: NSMenuItem!
    var groupMenus = [String: [NSMenuItem]]()
    var repMenus = [String: [NSMenuItem]]()
    var gapItems = [NSMenuItem]()
    var driver: HapticDriver?
    var lastFire = -1.0
    var hid: HIDKeys?
    var source = "—"
    var lastOutcome = ""

    /// Какой перехват сейчас активен: тап и HID не должны стрелять вместе.
    enum InputSource { case none, tap, hid }
    var activeSource: InputSource = .none
    var click: ClickSound?      // звук клавиши (лениво, при sound=1)
    var settings: SettingsWindow? // окно настроек (открыто или нет)
    private var holdTimer: Timer?
    private var blinkPending = false
    private var blinkGen = 0

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
        dlog("cfg master=\(Int(master)) gap=\(Int(minGapMs)) repgap=\(Int(repGapMs)) "
             + "sound=\(soundOn ? 1 : 0)/\(Int(soundVol))/pick\(soundPick) "
             + "ind=\(indOn ? 1 : 0) stat=\(statOn ? 1 : 0) hold=\(holdOn ? 1 : 0) "
             + "combo=\(comboOn ? 1 : 0) extkb=\(extkbOn ? 1 : 0) preset=\(presetKey)",
             always: true)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupStatusIcon()
        refreshSound()
        item.menu = buildMenu()
        startTap() // сразу включаемся, как демон
        refreshStates() // после startTap: там уже известны источник и статус
        if CommandLine.arguments.contains("--settings")
            || CommandLine.arguments.contains("--settings-tab") {
            var tab = -1
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--settings-tab"), i + 1 < args.count {
                tab = Int(args[i + 1]) ?? -1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.settingsOpen(tab: tab)
            }
        }
        // Отладка гула: --hold-test сам держит клавишу 2 с (без нажатий).
        if CommandLine.arguments.contains("--hold-test") {
            holdOn = true
            dlog("hold-test: гул включён принудительно", always: true)
            startHold(group: "key")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                self.stopHold()
                self.holdOn = false
            }
        }
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
        if !UserDefaults.standard.bool(forKey: "typebar.onboarded") {
            UserDefaults.standard.set(true, forKey: "typebar.onboarded")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.firstRunNotice()
            }
        }
    }

    /// Иконка трей: SF Symbol-шаблон сам подстраивается под светлую/тёмную
    /// тему; на старых macOS остаётся эмодзи ⌨️.
    func setupStatusIcon() {
        if #available(macOS 11.0, *) {
            let img = NSImage(systemSymbolName: "keyboard",
                              accessibilityDescription: "Печатная машинка")
            img?.isTemplate = true
            item.button?.image = img
            item.button?.imagePosition = .imageLeading
            item.button?.title = ""
        } else {
            item.button?.title = "⌨️"
        }
    }

    /// Счётчик статистики рядом с иконкой + базовая прозрачность.
    func updateStatusItem() {
        guard let b = item?.button else { return }
        if !blinkPending {
            b.alphaValue = enabled ? 1.0 : 0.4
        }
        if #available(macOS 11.0, *) {
            b.title = statOn ? " \(statsTotal)" : ""
        } else {
            b.title = "⌨️" + (statOn ? " \(statsTotal)" : "")
        }
    }

    /// Мигание иконки при засчитанном нажатии (ind=1).
    func blinkIndicator() {
        guard indOn, let b = item?.button else { return }
        blinkGen += 1
        let gen = blinkGen
        blinkPending = true
        b.alphaValue = 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self = self, self.blinkGen == gen else { return }
            self.blinkPending = false
            self.updateStatusItem()
        }
    }

    /// Подсказка при первом запуске: как дать доступ «Мониторинг ввода».
    /// Работает и без него (через HID), но тап точнее — предупреждаем один раз.
    func firstRunNotice() {
        let a = NSAlert()
        a.messageText = "Добро пожаловать в печатную машинку ⌨️"
        a.informativeText = """
        Щелчки Taptic Engine на каждое нажатие клавиши.

        Чтобы клавиши ловились точнее, добавь TypeBar в список:
        Системные настройки → Конфиденциальность и безопасность → Мониторинг ввода → + → TypeBar.

        Без доступа тоже работает (через HID-клавиатуры), но с ним отзывчивее.
        В меню ⚙️ Настройки: звук печатной машинки, пресеты, профили,
        гул при удержании, комбинации, статистика и экспорт настроек.
        """
        a.addButton(withTitle: "Понятно")
        a.addButton(withTitle: "Мониторинг ввода")
        a.addButton(withTitle: "Настройки TypeBar")
        let r = a.runModal()
        switch r {
        case .alertSecondButtonReturn:
            // доступ «Мониторинг ввода» — главный шаг из подсказки
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(u)
            }
        case .alertThirdButtonReturn:
            openSettings()
        default:
            break
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
        strengthSlider = NSSlider(value: master, minValue: 10, maxValue: 500,
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

        statsItem = NSMenuItem(title: "Статистика: 0", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        m.addItem(statsItem)

        soundItem = NSMenuItem(title: "Звук: вкл", action: #selector(toggleSound),
                               keyEquivalent: "")
        soundItem.target = self
        m.addItem(soundItem)

        let settingsBtn = NSMenuItem(title: "⚙️ Настройки…",
                                     action: #selector(openSettings),
                                     keyEquivalent: ",")
        settingsBtn.target = self
        m.addItem(settingsBtn)

        m.addItem(.separator())
        autoStartItem = NSMenuItem(title: "Автозапуск при входе",
                                   action: #selector(toggleAutoStart),
                                   keyEquivalent: "")
        autoStartItem.target = self
        m.addItem(autoStartItem)

        let helpItem = NSMenuItem(title: "Показать подсказку заново",
                                  action: #selector(showTipAgain),
                                  keyEquivalent: "")
        helpItem.target = self
        m.addItem(helpItem)

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
        autoStartItem.state = isAutoStartEnabled ? .on : .off
        for (id, items) in repMenus {
            let cur = reps[id] ?? 1
            for it in items {
                let n = (it.representedObject as? NSDictionary)?["n"] as? Int
                it.state = (n == cur) ? .on : .off
            }
        }
        soundItem.title = soundOn ? "Звук: вкл" : "Звук: выкл"
        soundItem.state = soundOn ? .on : .off
        statsItem.title = "Статистика: \(statsTotal) щелчков"
        statsItem.isHidden = !statOn
        updateStatusItem()
        settings?.syncFromApp()
    }

    /// Перед открытием меню — обновить счётчики и состояния.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStates()
    }

    @objc func toggleSound() {
        soundOn.toggle()
        refreshSound()
        saveCfg()
        refreshStates()
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
        presetKey = "custom"
        saveCfg()
        refreshStates()
        burst(group: g) // сразу дать послушать
    }

    @objc func pickRep(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? NSDictionary,
              let g = d["repGroup"] as? String,
              let n = d["n"] as? Int else { return }
        reps[g] = n
        presetKey = "custom"
        saveCfg()
        refreshStates()
        burst(group: g) // послушать
    }

    /// Паттерн группы как настроен; громкость — мастер-слайдер (амплитуда).
    func burst(group g: String) {
        fireWave(waves[g] ?? 4, rep: reps[g] ?? 1, tag: g)
    }

    /// Один удар (или повтор) волны на фоне — без статистики и звука.
    func fireWave(_ w: Int, rep: Int, tag: String) {
        let gap = UInt32(repGapMs * 1000)
        let amp = masterAmp
        DispatchQueue.global().async { [weak self] in
            var ok = false
            for i in 0 ..< rep {
                if i > 0 { usleep(gap) }
                ok = self?.driver?.fire(Int32(w), intensity: amp) ?? false
            }
            self?.dlog("fire \(tag)=\(w)x\(rep) amp=\(amp) ok=\(ok)", always: true)
        }
    }

    @objc func pickGap(_ sender: NSMenuItem) {
        if let ms = sender.representedObject as? Int {
            minGapMs = Double(ms)
            saveCfg()
            refreshStates()
        }
    }

    @objc func testWave(_ sender: NSMenuItem) {
        ensureDriver()
        driver?.fire(Int32(sender.tag))
    }

    // ----- мастер-сила 10..300% = амплитуда 0.1..2.0 -----

    /// Мастер-слайдер напрямую в амплитуду актуатора.
    /// API принимает и больше 2.0 — драйвер сам клампит, так что даём запас.
    var masterAmp: Float { min(max(Float(master) / 100, 0.1), 5.0) }

    @objc func strengthChanged(_ sender: NSSlider) {
        master = sender.doubleValue
        strengthLabel.stringValue = "Сила: \(Int(master))%"
        presetKey = "custom"
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
        stopHold()
        // Фильтр внешних клавиатур возможен только через HID: event tap
        // не сообщает, с какого устройства пришло нажатие.
        if extkbOn {
            if startEventTap() { return }
            if startHID(filter: false) { return }
        } else {
            if startHID(filter: true) { return }
            if startEventTap() {
                source = "тап ⚠ фильтр выкл."
                dlog("tap=ok (без фильтра внешних)")
                refreshStates()
                return
            }
        }
        if let h = hid {
            source = "HID? \(h.diag)"
            dlog("hid=fail \(h.diag)")
        } else {
            dlog("tap=nil")
        }
        if showAlert {
            alert("Не вижу клавиатуру",
                  "Event tap без доступа, а HID-устройств не нашлось.\n\n" +
                  "Дай доступ: Системные настройки → Конфиденциальность → " +
                  "Мониторинг ввода → добавь TypeBar, затем выйди и запусти заново.")
        }
        refreshStates()
    }

    /// 1. event tap: точен, но требует «Мониторинг ввода» и не фильтрует
    /// устройства. keyDown + keyUp — keyUp нужен для гула при удержании.
    private func startEventTap() -> Bool {
        if gTap == nil {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
        guard let t = gTap else { return false }
        CGEvent.tapEnable(tap: t, enable: true)
        activeSource = .tap
        enabled = true
        source = "тап"
        dlog("tap=ok")
        refreshStates()
        return true
    }

    /// 2. HID-клавиатуры напрямую: доступ не нужен, зато видно устройство.
    private func startHID(filter: Bool) -> Bool {
        if hid == nil {
            let h = HIDKeys()
            h?.onUsage = { [weak self] u in
                self?.dlog(String(format: "key 0x%x", u), always: true)
                self?.handleUsage(u)
            }
            h?.onRelease = { [weak self] _ in self?.stopHold() }
            hid = h
        }
        guard let h = hid else { return false }
        h.filterExternal = filter
        guard h.start(), h.keyboardCount > 0 else { return false }
        activeSource = .hid
        enabled = true
        if filter {
            source = "HID (внешн. выкл., внутр. \(h.builtinCount))"
        } else {
            source = "HID (\(h.keyboardCount) клав.)"
        }
        dlog("hid=ok n=\(h.keyboardCount) in=\(h.builtinCount) out=\(h.externalCount) filter=\(filter)")
        refreshStates()
        return true
    }

    /// Перезапуск перехвата после смены настроек, влияющих на источник.
    func restartSource() {
        stopTap()
        if wantOn { startTap(showAlert: false) }
        refreshStates()
    }

    func stopTap() {
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: false) }
        activeSource = .none
        enabled = false
        stopHold()
    }

    // ---------- разбор нажатий ----------

    /// keycode -> группа (nil — молчим: модификаторы).
    func groupForKeyCode(_ code: Int) -> String? {
        switch code {
        case 49: return "space"
        case 48: return "tab"
        case 36: return "enter"
        case 51: return "delete"
        case 53: return "esc"
        case 123, 124, 125, 126: return "arrow" // ← ↑ → ↓
        case 115, 116, 119, 121: return "nav"    // Home, PgUp, End, PgDn
        case 54, 55, 58, 59, 60, 61, 62, 63: return nil // модификаторы
        default: return "key"
        }
    }

    /// То же для HID-usage (0x07).
    func groupForUsage(_ usage: UInt32) -> String? {
        switch usage {
        case 0x2C: return "space"
        case 0x2B: return "tab"
        case 0x28: return "enter"
        case 0x2A: return "delete"
        case 0x29: return "esc"
        case 0x50, 0x51, 0x52, 0x53: return "arrow" // ← → ↓ ↑
        case 0x4A, 0x4B, 0x4D, 0x4E: return "nav"    // Home, PgUp, End, PgDn
        case 0xE0 ... 0xE7: return nil               // модификаторы
        default: return "key"
        }
    }

    func handleKey(_ code: Int, flags: CGEventFlags = []) {
        guard enabled, activeSource == .tap, !isDemo else { return }
        if comboOn {
            let mods = comboMods(flags: flags)
            if mods.contains(where: { $0 != "shift" }) {
                fireCombo(mods: mods, letter: Self.letter(forKeyCode: code))
                return
            }
        }
        guard let g = groupForKeyCode(code) else { return }
        fireGroup(g)
        startHold(group: g)
    }

    func handleKeyUp(_ code: Int) {
        guard enabled, activeSource == .tap, holdOn else { return }
        stopHold()
    }

    /// Та же таблица, но для HID-usage (0x07): пробел 0x2C, ввод 0x28,
    /// стереть 0x2A, esc 0x29, tab 0x2B, модификаторы 0xE0–0xE7 молчат.
    func handleUsage(_ usage: UInt32) {
        guard enabled, activeSource == .hid, !isDemo else { return }
        if (0xE0 ... 0xE7).contains(usage) { return }
        if comboOn {
            let mods = comboMods(usages: hid?.modsHeld() ?? [])
            if mods.contains(where: { $0 != "shift" }) {
                fireCombo(mods: mods, letter: Self.letter(forUsage: usage))
                return
            }
        }
        guard let g = groupForUsage(usage) else { return }
        fireGroup(g)
        startHold(group: g)
    }

    /// Общий поток нажатия: лимит частоты -> статистика -> мигание -> звук
    /// -> вибрация.
    func fireGroup(_ g: String) {
        guard rateOk() else { return }
        bumpStat(g)
        blinkIndicator()
        if soundOn { click?.play(group: g) }
        burst(group: g)
    }

    /// Комбо (Cmd+C …): точная настройка, иначе «Остальные», 0 = тихо.
    func fireCombo(mods: [String], letter: String?) {
        var id = mods.joined(separator: "+")
        if let l = letter, !l.isEmpty { id += "+" + l }
        let spec = combos[id] ?? combos["any"] ?? "0"
        guard let pat = Self.parsePat(spec), pat.wave >= 1 else {
            dlog("combo \(id) = тихо")
            return
        }
        guard rateOk() else { return }
        bumpStat("combo")
        blinkIndicator()
        if soundOn { click?.play(group: "key") }
        fireWave(pat.wave, rep: pat.rep, tag: "combo \(id)")
    }

    /// "W" или "WxR" -> (wave, rep); невалидно -> nil. wave 0 = тихо.
    static func parsePat(_ s: String) -> (wave: Int, rep: Int)? {
        let parts = s.split(separator: "x", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let w = Int(parts[0]) else { return nil }
        var r = 1
        if parts.count > 1 {
            guard let rr = Int(parts[1]) else { return nil }
            r = rr
        }
        return (w, r)
    }

    /// Модификаторы события в каноничном порядке (для ключей combo.*).
    func comboMods(flags: CGEventFlags) -> [String] {
        var p = [String]()
        if flags.contains(.maskCommand) { p.append("cmd") }
        if flags.contains(.maskControl) { p.append("ctrl") }
        if flags.contains(.maskAlternate) { p.append("opt") }
        if flags.contains(.maskShift) { p.append("shift") }
        return p
    }

    /// То же из HID usage зажатых модификаторов.
    func comboMods(usages: Set<UInt32>) -> [String] {
        var p = [String]()
        if usages.contains(0xE3) || usages.contains(0xE7) { p.append("cmd") }
        if usages.contains(0xE0) || usages.contains(0xE4) { p.append("ctrl") }
        if usages.contains(0xE2) || usages.contains(0xE5) { p.append("opt") }
        if usages.contains(0xE1) || usages.contains(0xE6) { p.append("shift") }
        return p
    }

    /// Буква для combo-ключа: CG keycode (ANSI) -> "a"..."z".
    static func letter(forKeyCode code: Int) -> String? {
        let map = [0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z",
                   7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
                   14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
                   34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n",
                   46: "m"]
        return map[code]
    }

    /// HID usage 0x04..0x1D -> "a"..."z".
    static func letter(forUsage usage: UInt32) -> String? {
        guard (0x04 ... 0x1D).contains(usage) else { return nil }
        guard let scalar = Unicode.Scalar(97 + usage - 4) else { return nil }
        return String(Character(scalar))
    }

    /// Лимит частоты: не чаще minGapMs между щелчками.
    private func rateOk() -> Bool {
        let now = mono()
        if now - lastFire < minGapMs / 1000.0 { return false }
        lastFire = now
        return true
    }

    // ---------- гул при удержании ----------

    /// Пока клавиша зажата — повторный удар волны её группы.
    func startHold(group g: String) {
        guard holdOn, enabled else { return }
        let w = waves[g] ?? 4
        stopHold()
        let interval = max(0.05, holdGapMs / 1000)
        dlog("hold arm \(g) w=\(w) gap=\(Int(holdGapMs))ms", always: true)
        holdTimer = Timer.scheduledTimer(withTimeInterval: interval,
                                         repeats: true) { [weak self] _ in
            guard let self = self, self.enabled, self.holdOn else { return }
            self.fireWave(w, rep: 1, tag: "hold")
        }
    }

    func stopHold() {
        if holdTimer != nil { dlog("hold off", always: true) }
        holdTimer?.invalidate()
        holdTimer = nil
    }

    // ---------- статистика ----------

    var statsTotal: Int { stats.values.reduce(0, +) }

    func bumpStat(_ g: String) {
        stats[g, default: 0] += 1
        if statOn { updateStatusItem() }
        settings?.syncStats()
    }

    func mono() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
    }

    // ---------- конфиг ~/.typeclickrc (общий с CLI) ----------

    func loadCfg() {
        guard let s = try? String(contentsOf: cfgURL, encoding: .utf8) else { return }
        applyCfgText(s, reset: false)
    }

    /// Дефолты — база для профилей и импорта JSON.
    func resetDefaults() {
        waves = ["key": 4, "space": 5, "tab": 5, "enter": 2, "delete": 1,
                 "esc": 3, "arrow": 5, "nav": 5]
        reps = ["key": 1, "space": 1, "tab": 1, "enter": 2, "delete": 1,
                "esc": 1, "arrow": 1, "nav": 1]
        minGapMs = 15
        repGapMs = 120
        master = 500
        soundOn = true
        soundVol = 60
        soundPick = 1
        soundFile = ""
        indOn = true
        statOn = true
        holdOn = false
        holdGapMs = 100
        comboOn = false
        combos = [:]
        extkbOn = true
        presetKey = "custom"
        profileKey = ""
    }

    /// Разобрать текст конфига (тот же формат key=value, что у typeclick).
    /// reset=true — сначала вернуть дефолты (профили, импорт).
    func applyCfgText(_ s: String, reset: Bool) {
        if reset { resetDefaults() }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let kv = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2 else { continue }
            let k = kv[0], v = kv[1]
            switch k {
            case "master":
                if let n = Double(v), (10 ... 500).contains(n) { master = n }
            case "repgap":
                if let n = Int(v), (20 ... 500).contains(n) { repGapMs = Double(n) }
            case "gap":
                if let n = Double(v), (1 ... 200).contains(n) { minGapMs = n }
            case "sound":
                soundOn = v == "1"
            case "soundvol":
                if let n = Double(v), (0 ... 100).contains(n) { soundVol = n }
            case "soundpick":
                if let n = Int(v), (0 ... 4).contains(n) { soundPick = n }
            case "soundfile":
                soundFile = v
            case "ind":
                indOn = v == "1"
            case "stat":
                statOn = v == "1"
            case "hold":
                holdOn = v == "1"
            case "holdgap":
                if let n = Double(v), (50 ... 400).contains(n) { holdGapMs = n }
            case "extkb":
                extkbOn = v != "0" // нет ключа в старом конфиге -> вкл
            case "preset":
                presetKey = v
            case "profile":
                profileKey = v
            case "combo.on":
                comboOn = v == "1"
            default:
                if k.hasPrefix("combo.") {
                    let id = String(k.dropFirst(6))
                    if Self.comboKeys.contains(where: { $0.id == id }) {
                        combos[id] = v
                    }
                    continue
                }
                guard waves[k] != nil else { continue }
                guard let pat = Self.parsePat(v), (1 ... 6).contains(pat.wave),
                      (1 ... 4).contains(pat.rep) else { continue }
                waves[k] = pat.wave
                reps[k] = pat.rep
            }
        }
    }

    /// Текст конфига — его же пишут saveCfg и профили.
    func cfgText() -> String {
        var lines = [String]()
        for g in ["key", "space", "tab", "enter", "delete", "esc", "arrow", "nav"] {
            let w = waves[g] ?? 4
            let r = reps[g] ?? 1
            lines.append(r == 1 ? "\(g)=\(w)" : "\(g)=\(w)x\(r)")
        }
        lines += [
            "repgap=\(Int(repGapMs))",
            "gap=\(Int(minGapMs))",
            "master=\(Int(master))",
            "preset=\(presetKey)",
            "profile=\(profileKey)",
            "sound=\(soundOn ? 1 : 0)",
            "soundvol=\(Int(soundVol))",
            "soundpick=\(soundPick)",
            "soundfile=\(soundFile)",
            "ind=\(indOn ? 1 : 0)",
            "stat=\(statOn ? 1 : 0)",
            "hold=\(holdOn ? 1 : 0)",
            "holdgap=\(Int(holdGapMs))",
            "extkb=\(extkbOn ? 1 : 0)",
            "combo.on=\(comboOn ? 1 : 0)",
        ]
        for (id, _) in Self.comboKeys where combos[id] != nil {
            lines.append("combo.\(id)=\(combos[id]!)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func saveCfg() {
        try? cfgText().write(to: cfgURL, atomically: true, encoding: .utf8)
    }

    /// Применить только что изменённый конфиг: записать, перезапустить
    /// звук и обновить UI (вызывается из настроек и профилей).
    func afterCfgApply() {
        saveCfg()
        refreshSound()
        refreshStates()
    }

    // ---------- звук ----------

    /// (Пере)собрать звуковой движок по текущим настройкам.
    func refreshSound() {
        if soundOn {
            if click == nil { click = ClickSound() }
            click?.log = { [weak self] s in self?.dlog(s, always: true) }
            click?.volume = Float(soundVol) / 100
            click?.isOn = true
            let ok = click?.configure(pick: soundPick, custom: soundFile) ?? false
            dlog("snd cfg ok=\(ok) pick=\(soundPick) vol=\(Int(soundVol))"
                 + (ok ? "" : " err=\(click?.lastError ?? "?")"), always: true)
        } else {
            click?.isOn = false
            click?.stop()
        }
    }

    // ----- автозапуск через LaunchAgent -----

    private static let agentLabel = "local.midihaptic.typebar"

    private var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
    }

    private var isAutoStartEnabled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    @objc func toggleAutoStart() {
        setAutoStart(!isAutoStartEnabled)
        refreshStates()
    }

    @objc func showTipAgain() {
        firstRunNotice()
    }

    /// Ставит/снимает LaunchAgent: TypeBar грузится при входе в систему.
    func setAutoStart(_ on: Bool) {
        if on {
            let exe = Bundle.main.executableURL?.path ?? ""
            guard !exe.isEmpty else { return }
            let dir = agentPlistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(Self.agentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exe)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
                <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            try? plist.write(to: agentPlistURL, atomically: true, encoding: .utf8)
            // подхватить без перезагрузки
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["load", agentPlistURL.path]
            try? task.run()
            task.waitUntilExit()
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["unload", agentPlistURL.path]
            try? task.run()
            task.waitUntilExit()
            try? FileManager.default.removeItem(at: agentPlistURL)
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
