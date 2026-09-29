// TypeBarSettings.swift — окно настроек TypeBar и всё, что с ним:
// пресеты, профили, экспорт/импорт JSON. Настройки лежат в ~/.typeclickrc
// (тот же файл, что у CLI typeclick) и в ~/.typeclick.profiles/*.rc.
import AppKit

// ---------- действия, которые живут на TypeBarApp ----------

extension TypeBarApp {
    @objc func openSettings() {
        settingsOpen(tab: -1)
    }

    func settingsOpen(tab: Int) {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings?.show(tab: tab)
    }

    // ----- профили: ~/.typeclick.profiles/<имя>.rc -----

    var profilesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".typeclick.profiles", isDirectory: true)
    }

    func profileNames() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: profilesDir,
                                                      includingPropertiesForKeys: nil)
        else { return [] }
        return items.filter { $0.pathExtension == "rc" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func saveProfile(_ name: String) {
        try? FileManager.default.createDirectory(at: profilesDir,
                                                 withIntermediateDirectories: true)
        let url = profilesDir.appendingPathComponent("\(name).rc")
        try? cfgText().write(to: url, atomically: true, encoding: .utf8)
        profileKey = name
        saveCfg()
        dlog("profile saved \(name)")
    }

    @discardableResult
    func loadProfile(_ name: String) -> Bool {
        let url = profilesDir.appendingPathComponent("\(name).rc")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        applyCfgText(s, reset: true)
        profileKey = name
        afterCfgApply()
        restartSource() // в профиле мог быть другой extkb
        dlog("profile loaded \(name)")
        return true
    }

    func deleteProfile(_ name: String) {
        let url = profilesDir.appendingPathComponent("\(name).rc")
        try? FileManager.default.removeItem(at: url)
        if profileKey == name {
            profileKey = ""
            saveCfg()
        }
        dlog("profile deleted \(name)")
    }

    // ----- пресеты -----

    /// Быстрый набор «сила + паттерны + звук». custom — не набор,
    /// а метка «настроено вручную».
    func applyPreset(_ id: String) {
        let all = ["key", "space", "tab", "enter", "delete", "esc", "arrow", "nav"]
        switch id {
        case "quiet":
            master = 30
            waves = ["key": 1, "space": 1, "tab": 1, "enter": 1,
                     "delete": 1, "esc": 1, "arrow": 1, "nav": 1]
            reps = Dictionary(uniqueKeysWithValues: all.map { ($0, 1) })
            soundOn = true
            soundVol = 35
        case "normal":
            master = 100
            waves = ["key": 4, "space": 5, "tab": 5, "enter": 2,
                     "delete": 1, "esc": 3, "arrow": 5, "nav": 5]
            reps = Dictionary(uniqueKeysWithValues: all.map { ($0, 1) })
            reps["enter"] = 2
            soundOn = true
            soundVol = 60
        case "loud":
            master = 300
            waves = ["key": 2, "space": 6, "tab": 6, "enter": 6,
                     "delete": 2, "esc": 6, "arrow": 6, "nav": 6]
            reps = ["key": 2, "space": 2, "tab": 2, "enter": 3,
                    "delete": 1, "esc": 1, "arrow": 2, "nav": 1]
            soundOn = true
            soundVol = 100
        default:
            return
        }
        presetKey = id
        afterCfgApply()
        burst(group: "key") // послушать результат
    }

    // ----- экспорт/импорт настроек в JSON -----

    func jsonConfig() -> [String: Any] {
        var groupsOut = [String: [String: Int]]()
        for g in waves.keys {
            groupsOut[g] = ["wave": waves[g] ?? 4, "rep": reps[g] ?? 1]
        }
        var combosOut = [String: String]()
        for (k, v) in combos { combosOut[k] = v }
        return [
            "v": 1,
            "groups": groupsOut,
            "master": Int(master),
            "repgap": Int(repGapMs),
            "gap": Int(minGapMs),
            "sound": soundOn,
            "soundvol": Int(soundVol),
            "soundpick": soundPick,
            "soundfile": soundFile,
            "ind": indOn,
            "stat": statOn,
            "hold": holdOn,
            "holdgap": Int(holdGapMs),
            "extkb": extkbOn,
            "preset": presetKey,
            "profile": profileKey,
            "comboon": comboOn,
            "combos": combosOut,
        ]
    }

    /// Импорт: JSON -> строки конфига -> тот же парсер, что и для rc.
    func applyJsonConfig(_ d: [String: Any]) -> Bool {
        func num(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        func flag(_ v: Any?) -> Int? {
            if let b = v as? Bool { return b ? 1 : 0 }
            if let n = v as? NSNumber { return n.intValue != 0 ? 1 : 0 }
            return nil
        }
        var lines = [String]()
        if let g = d["groups"] as? [String: [String: Any]] {
            for (k, v) in g {
                guard let w = num(v["wave"]), (1 ... 6).contains(w) else {
                    continue
                }
                let r = min(max(num(v["rep"]) ?? 1, 1), 4)
                lines.append(r == 1 ? "\(k)=\(w)" : "\(k)=\(w)x\(r)")
            }
        }
        if let n = num(d["master"]), (10 ... 500).contains(n) {
            lines.append("master=\(n)")
        }
        if let n = num(d["repgap"]), (20 ... 500).contains(n) {
            lines.append("repgap=\(n)")
        }
        if let n = num(d["gap"]), (1 ... 200).contains(n) {
            lines.append("gap=\(n)")
        }
        if let b = flag(d["sound"]) { lines.append("sound=\(b)") }
        if let n = num(d["soundvol"]), (0 ... 100).contains(n) {
            lines.append("soundvol=\(n)")
        }
        if let n = num(d["soundpick"]), (0 ... 4).contains(n) {
            lines.append("soundpick=\(n)")
        }
        if let s = d["soundfile"] as? String { lines.append("soundfile=\(s)") }
        if let b = flag(d["ind"]) { lines.append("ind=\(b)") }
        if let b = flag(d["stat"]) { lines.append("stat=\(b)") }
        if let b = flag(d["hold"]) { lines.append("hold=\(b)") }
        if let n = num(d["holdgap"]), (50 ... 400).contains(n) {
            lines.append("holdgap=\(n)")
        }
        if let b = flag(d["extkb"]) { lines.append("extkb=\(b)") }
        if let s = d["preset"] as? String { lines.append("preset=\(s)") }
        if let s = d["profile"] as? String { lines.append("profile=\(s)") }
        if let b = flag(d["comboon"]) { lines.append("combo.on=\(b)") }
        if let c = d["combos"] as? [String: String] {
            for (k, v) in c where Self.comboKeys.contains(where: { $0.id == k }) {
                lines.append("combo.\(k)=\(v)")
            }
        }
        applyCfgText(lines.joined(separator: "\n"), reset: true)
        afterCfgApply()
        restartSource()
        dlog("json imported")
        return true
    }
}

// ---------- окно настроек ----------

final class SettingsWindow: NSObject, NSWindowDelegate {
    weak var app: TypeBarApp!
    private var window: NSWindow?
    private var tabs: NSTabView?
    private var didCenter = false
    /// Отладка: --settings-tab N открывает окно сразу на вкладке N.
    private var pendingTab = -1

    private var powerCheck: NSButton!
    private var sourceLabel: NSTextField!
    private var presetChecks = [String: NSButton]()
    private var profilePopup: NSPopUpButton!
    private var profileName: NSTextField!
    private var soundCheck: NSButton!
    private var soundSlider: NSSlider!
    private var soundVolLabel: NSTextField!
    private var soundPopup: NSPopUpButton!
    private var extkbCheck: NSButton!
    private var holdCheck: NSButton!
    private var holdGapPopup: NSPopUpButton!
    private var comboCheck: NSButton!
    private var comboPopups = [String: NSPopUpButton]()
    private var comboOpts = [String: [(title: String, spec: String?)]]()
    private var indCheck: NSButton!
    private var statCheck: NSButton!
    private var statsText: NSTextField!
    private let holdGaps = [50, 100, 150, 200, 300, 400]

    init(app: TypeBarApp) {
        self.app = app
        super.init()
    }

    func show(tab: Int = -1) {
        if window == nil { build() }
        if tab >= 0 {
            pendingTab = tab
            if let t = tabs, tab < t.numberOfTabViewItems {
                t.selectTabViewItem(at: tab)
            }
        }
        app.dlog("settings show tab=\(tab) sel=\(tabs?.selectedTabViewItem?.label ?? "?")",
                 always: true)
        syncFromApp()
        guard let w = window else { return }
        if !didCenter {
            w.center()
            didCenter = true
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ----- сборка -----

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Настройки печатной машинки"
        win.isReleasedWhenClosed = false
        let tabs = NSTabView(frame: win.contentView!.bounds)
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(tabMain())
        tabs.addTabViewItem(tabSound())
        tabs.addTabViewItem(tabVibro())
        tabs.addTabViewItem(tabMisc())
        win.contentView = tabs
        self.tabs = tabs
        window = win
    }

    private func tabMain() -> NSTabViewItem {
        let v = NSView()
        powerCheck = check("Печатная машинка включена",
                           #selector(powerToggled))
        sourceLabel = label("Источник: —")
        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 6
        for p in TypeBarApp.presetKeys {
            let b = check(p.title, #selector(presetPicked(_:)))
            if p.id == "custom" { b.isEnabled = false } // метка, а не действие
            presetChecks[p.id] = b
            presets.addArrangedSubview(b)
        }
        profilePopup = popup([], #selector(noop))
        profilePopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let loadBtn = button("Загрузить", #selector(profileLoad))
        let delBtn = button("Удалить", #selector(profileDelete))
        profileName = NSTextField()
        profileName.placeholderString = "имя профиля"
        profileName.target = self
        profileName.action = #selector(profileSave)
        profileName.translatesAutoresizingMaskIntoConstraints = false
        profileName.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let saveBtn = button("Сохранить", #selector(profileSave))

        let stack = vstack([
            powerCheck, sourceLabel, spacer(6),
            head("Пресеты"), presets,
            spacer(6),
            head("Профили"), row([profilePopup, loadBtn, delBtn]),
            row([profileName, saveBtn]),
            spacer(4),
            note("Профиль — полный набор настроек. Пресеты перекрывают "
                 + "силу, паттерны и звук; дальше настройки «свои»."),
        ])
        embed(stack, in: v)
        return item("Основное", v)
    }

    private func tabSound() -> NSTabViewItem {
        let v = NSView()
        soundCheck = check("Щелчок клавиши при нажатии", #selector(soundToggled))
        soundSlider = NSSlider(value: 60, minValue: 0, maxValue: 100,
                               target: self, action: #selector(soundVolChanged(_:)))
        soundSlider.isContinuous = true
        soundSlider.translatesAutoresizingMaskIntoConstraints = false
        soundSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        soundVolLabel = label("60%")
        var titles = ClickSound.picks.map { $0.title }
        titles.append("Свой файл…")
        soundPopup = popup(titles, #selector(soundPickChanged))
        let testBtn = button("Тест", #selector(soundTest))
        let fileBtn = button("Выбрать файл…", #selector(soundChooseFile))
        fileBtn.tag = 0

        let stack = vstack([
            soundCheck,
            row([label("Громкость"), soundSlider, soundVolLabel]),
            row([label("Звук"), soundPopup, fileBtn, testBtn]),
            spacer(4),
            note("Встроенные: щелчок, машинка (звук настоящей печатной "
                 + "машинки), клик, тихий. Свой — wav/aiff/caf длиной до 5 с. "
                 + "Клавиша ввода звучит возвратом каретки."),
        ])
        embed(stack, in: v)
        return item("Звук", v)
    }

    private func tabVibro() -> NSTabViewItem {
        let v = NSView()
        extkbCheck = check("Вибрировать на внешних клавиатурах",
                           #selector(extkbToggled))
        holdCheck = check("Гул, пока клавиша зажата", #selector(holdToggled))
        holdGapPopup = popup(holdGaps.map { "\($0) мс" }, #selector(holdGapChanged))
        comboCheck = check("Реагировать на комбинации (Cmd+C, …)",
                           #selector(comboToggled))

        let cols = NSStackView()
        cols.orientation = .horizontal
        cols.alignment = .top
        cols.spacing = 24
        var col1 = [NSView]()
        var col2 = [NSView]()
        for (i, c) in TypeBarApp.comboKeys.enumerated() {
            let r = comboRow(c)
            if i % 2 == 0 { col1.append(r) } else { col2.append(r) }
        }
        cols.addArrangedSubview(vstack(col1, spacing: 6))
        cols.addArrangedSubview(vstack(col2, spacing: 6))

        let stack = vstack([
            extkbCheck,
            note("С фильтром источник переключается на HID — он знает, "
                 + "какая клавиатура нажата. Тап таких данных не отдаёт."),
            spacer(4),
            row([holdCheck, label("повтор каждые"), holdGapPopup]),
            spacer(4),
            comboCheck, cols,
            spacer(2),
            note("«Тихо» = комбинация не щёлкает; «как Остальные» — "
                 + "паттерн из последней строки."),
        ])
        embed(stack, in: v)
        return item("Вибрация", v)
    }

    private func tabMisc() -> NSTabViewItem {
        let v = NSView()
        indCheck = check("Мигать иконкой при нажатии", #selector(indToggled))
        statCheck = check("Счётчик щелчков в меню", #selector(statToggled))
        statsText = NSTextField(labelWithString: "")
        statsText.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statsText.translatesAutoresizingMaskIntoConstraints = false
        statsText.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let resetBtn = button("Сбросить статистику", #selector(resetStats))
        let exportBtn = button("Экспорт JSON…", #selector(exportJSON))
        let importBtn = button("Импорт JSON…", #selector(importJSON))

        let stack = vstack([
            indCheck, statCheck,
            note("Иконка в трее — SF Symbol: сама меняется под светлую "
                 + "и тёмную тему, а счётчик показывает щелчки за сессию."),
            spacer(8),
            head("Статистика за сессию"),
            statsText,
            row([resetBtn, spacer(10), exportBtn, importBtn]),
            spacer(4),
            note("Экспорт кладёт все настройки в один JSON — скинь другу, "
                 + "а он вернёт кнопкой «Импорт»."),
        ])
        embed(stack, in: v)
        return item("Прочее", v)
    }

    private func comboRow(_ key: (id: String, title: String)) -> NSView {
        let l = NSTextField(labelWithString: key.title)
        l.font = .systemFont(ofSize: 12)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 116).isActive = true
        let opts = comboOptions(key.id)
        comboOpts[key.id] = opts
        let p = popup(opts.map { $0.title }, #selector(comboPicked(_:)))
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(equalToConstant: 170).isActive = true
        comboPopups[key.id] = p
        return row([l, p], spacing: 6)
    }

    /// Варианты комбо: "" = как у «Остальные», "0" = тихо, дальше W и Wx2.
    private func comboOptions(_ id: String) -> [(title: String, spec: String?)] {
        var o: [(String, String?)] = []
        if id != "any" { o.append(("как «Остальные»", "")) }
        o.append(("тихо", "0"))
        for w in 1 ... 6 {
            o.append(("\(w) — \(app.waveNames[w])", "\(w)"))
            o.append(("\(w)×2 — \(app.waveNames[w])", "\(w)x2"))
        }
        return o
    }

    // ----- хелперы вёрстки -----

    private func item(_ label: String, _ view: NSView) -> NSTabViewItem {
        let it = NSTabViewItem(identifier: label)
        it.label = label
        it.view = view
        return it
    }

    private func embed(_ stack: NSStackView, in view: NSView) {
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                            constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor,
                                          constant: -14),
        ])
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    private func head(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .boldSystemFont(ofSize: 12)
        return l
    }

    private func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 12)
        return l
    }

    private func note(_ t: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = 3
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 430).isActive = true
        return l
    }

    private func check(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: sel)
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func popup(_ titles: [String], _ sel: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.target = self
        p.action = sel
        return p
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: h))
        return v
    }

    @objc private func noop() {}

    // ----- синхронизация контролов с состоянием -----

    func syncFromApp() {
        guard window != nil else { return }
        powerCheck.state = app.enabled ? .on : .off
        sourceLabel.stringValue = "Источник: \(app.source)"
        for (id, b) in presetChecks {
            b.state = (app.presetKey == id) ? .on : .off
        }
        if let cur = profilePopup.titleOfSelectedItem, !cur.isEmpty,
           !app.profileNames().contains(cur) {
            rebuildProfilePopup(select: nil)
        }
        if !app.profileKey.isEmpty,
           let i = profilePopup.itemArray.firstIndex(where: { $0.title == app.profileKey }) {
            profilePopup.selectItem(at: i)
        }
        soundCheck.state = app.soundOn ? .on : .off
        soundSlider.doubleValue = app.soundVol
        soundVolLabel.stringValue = "\(Int(app.soundVol))%"
        soundPopup.selectItem(at: app.soundPick == 0 ? 4 : app.soundPick - 1)
        extkbCheck.state = app.extkbOn ? .on : .off
        holdCheck.state = app.holdOn ? .on : .off
        let gi = holdGaps.firstIndex(of: Int(app.holdGapMs)) ?? 1
        holdGapPopup.selectItem(at: gi)
        comboCheck.state = app.comboOn ? .on : .off
        for (id, p) in comboPopups {
            guard let opts = comboOpts[id] else { continue }
            let cur = app.combos[id] ?? (id == "any" ? "0" : "")
            let idx = opts.firstIndex { $0.spec == cur } ?? 0
            p.selectItem(at: idx)
        }
        indCheck.state = app.indOn ? .on : .off
        statCheck.state = app.statOn ? .on : .off
        syncStats()
    }

    func syncStats() {
        guard statsText != nil else { return }
        var lines = [String]()
        let items = app.groups.map { ($0.id, $0.title) } + [("combo", "Комбо")]
        for (id, t) in items where (app.stats[id] ?? 0) > 0 {
            lines.append("\(t): \(app.stats[id]!)")
        }
        lines.append("Всего: \(app.statsTotal) за сессию")
        statsText.stringValue = lines.joined(separator: "\n")
    }

    private func rebuildProfilePopup(select name: String?) {
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: app.profileNames())
        if let name = name,
           let i = profilePopup.itemArray.firstIndex(where: { $0.title == name }) {
            profilePopup.selectItem(at: i)
        }
    }

    // ----- действия -----

    @objc private func powerToggled() {
        app.toggle()
        syncFromApp()
    }

    @objc private func presetPicked(_ s: NSButton) {
        guard let id = presetChecks.first(where: { $0.value === s })?.key else {
            return
        }
        app.applyPreset(id)
        syncFromApp()
    }

    @objc private func profileLoad() {
        guard let name = profilePopup.titleOfSelectedItem, !name.isEmpty else {
            return
        }
        if !app.loadProfile(name) { NSSound.beep() }
        syncFromApp()
    }

    @objc private func profileSave() {
        let name = profileName.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return }
        app.saveProfile(name)
        rebuildProfilePopup(select: name)
        syncFromApp()
    }

    @objc private func profileDelete() {
        guard let name = profilePopup.titleOfSelectedItem, !name.isEmpty else {
            return
        }
        app.deleteProfile(name)
        rebuildProfilePopup(select: nil)
        syncFromApp()
    }

    @objc private func soundToggled() {
        app.soundOn = soundCheck.state == .on
        app.refreshSound()
        app.saveCfg()
        app.refreshStates()
    }

    @objc private func soundVolChanged(_ s: NSSlider) {
        app.soundVol = s.doubleValue
        soundVolLabel.stringValue = "\(Int(s.doubleValue))%"
        app.click?.volume = Float(s.doubleValue) / 100
        app.saveCfg()
    }

    @objc private func soundPickChanged() {
        let i = soundPopup.indexOfSelectedItem
        app.soundPick = i == 4 ? 0 : i + 1
        app.refreshSound()
        app.saveCfg()
        app.refreshStates()
    }

    @objc private func soundTest() {
        app.refreshSound()
        app.click?.play(group: "key")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.app.click?.play(group: "enter")
        }
    }

    @objc private func soundChooseFile() {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.allowedFileTypes = ["wav", "aiff", "aif", "caf"]
        p.allowsOtherFileTypes = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK, let url = p.url, let self = self else { return }
            self.app.soundFile = url.path
            self.app.soundPick = 0
            self.app.soundOn = true
            self.soundPopup.selectItem(at: 4)
            self.app.refreshSound()
            self.app.saveCfg()
            self.app.refreshStates()
            if let err = self.app.click?.lastError, !err.isEmpty {
                let a = NSAlert()
                a.messageText = "Не играет звук"
                a.informativeText = err
                a.runModal()
            }
        }
    }

    @objc private func extkbToggled() {
        app.extkbOn = extkbCheck.state == .on
        app.saveCfg()
        app.restartSource()
    }

    @objc private func holdToggled() {
        app.holdOn = holdCheck.state == .on
        if !app.holdOn { app.stopHold() }
        app.saveCfg()
    }

    @objc private func holdGapChanged() {
        let i = max(0, min(holdGapPopup.indexOfSelectedItem, holdGaps.count - 1))
        app.holdGapMs = Double(holdGaps[i])
        app.saveCfg()
    }

    @objc private func comboToggled() {
        app.comboOn = comboCheck.state == .on
        app.saveCfg()
    }

    @objc private func comboPicked(_ p: NSPopUpButton) {
        guard let id = comboPopups.first(where: { $0.value === p })?.key,
              let opts = comboOpts[id] else { return }
        let i = max(0, min(p.indexOfSelectedItem, opts.count - 1))
        let spec = opts[i].spec
        if spec == nil || spec == "" {
            app.combos[id] = nil
        } else {
            app.combos[id] = spec
        }
        app.saveCfg()
    }

    @objc private func indToggled() {
        app.indOn = indCheck.state == .on
        app.saveCfg()
        app.updateStatusItem()
        app.refreshStates()
    }

    @objc private func statToggled() {
        app.statOn = statCheck.state == .on
        app.saveCfg()
        app.refreshStates()
    }

    @objc private func resetStats() {
        app.stats.removeAll()
        syncStats()
        app.updateStatusItem()
    }

    @objc private func exportJSON() {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "typebar.json"
        p.allowedFileTypes = ["json"]
        p.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK, let url = p.url, let self = self else { return }
            let dict = self.app.jsonConfig()
            guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                         options: [.prettyPrinted, .sortedKeys])
            else { NSSound.beep(); return }
            try? data.write(to: url)
        }
    }

    @objc private func importJSON() {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.allowedFileTypes = ["json"]
        p.canChooseDirectories = false
        p.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK, let url = p.url, let self = self else { return }
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { NSSound.beep(); return }
            self.app.applyJsonConfig(obj)
            self.rebuildProfilePopup(select: self.app.profileKey.isEmpty
                ? nil : self.app.profileKey)
            self.syncFromApp()
        }
    }
}
