// MidiHapticGui.swift — нативное окно для midi_haptic:
// drag-and-drop плейлист, звук (AVMIDIPlayer), повтор, прогресс-бар, лог.
// Сборка: make MidiHapticApp  (или вручную: swiftc -O -o MidiHapticApp MidiHapticGui.swift -framework AppKit -framework AVFoundation)
// Рядом должен лежать бинарь midi_haptic. Или собери всё в .app: make app
import AppKit
import AVFoundation
import Foundation

// Пути к движкам: рядом с GUI-бинарником (в т.ч. внутри .app), иначе в текущей папке.
func toolPath(_ name: String) -> String {
    let exe = Bundle.main.executablePath ?? ""
    let dir = (exe as NSString).deletingLastPathComponent
    let nextTo = (dir as NSString).appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: nextTo) { return nextTo }
    let cwd = FileManager.default.currentDirectoryPath + "/" + name
    if FileManager.default.isExecutableFile(atPath: cwd) { return cwd }
    let desktop = NSString(string: "~/Desktop/hapticEngineMidi/\(name)").expandingTildeInPath
    if FileManager.default.isExecutableFile(atPath: desktop) { return desktop }
    return nextTo
}
func enginePath() -> String { toolPath("midi_haptic") }
func audioEnginePath() -> String { toolPath("audio_haptic") }
func toolFor(_ path: String) -> String { isAudioFile(path) ? audioEnginePath() : enginePath() }

func isAudioFile(_ path: String) -> Bool {
    ["mp3", "wav", "m4a", "aiff", "aif", "flac"]
        .contains((path as NSString).pathExtension.lowercased())
}

// ---------- Drop-зона ----------
final class DropView: NSView {
    var onFiles: (([String]) -> Void)?
    private let label = NSTextField(labelWithString: "Перетащи MIDI или MP3 сюда\n(можно несколько сразу)")
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.alignment = .center
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = bounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
        (hovering ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = hovering ? 2.5 : 1.5
        let dash: [CGFloat] = [8, 6]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.stroke()
        layer?.backgroundColor = (hovering
            ? NSColor.controlAccentColor.withAlphaComponent(0.08)
            : NSColor.controlBackgroundColor).cgColor
        layer?.cornerRadius = 12
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = true; needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        hovering = false; needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false; needsDisplay = true
        let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let picked = files.map { $0.path }.filter {
            let e = ($0 as NSString).pathExtension.lowercased()
            return ["mid", "midi", "mp3", "wav", "m4a", "aiff", "aif", "flac"].contains(e)
        }
        if !picked.isEmpty { onFiles?(picked) }
        return !picked.isEmpty
    }
}

// ---------- Делегат приложения ----------
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource {
    var window: NSWindow!
    var dropView: DropView!
    var table = NSTableView()

    var fileLabel = NSTextField(labelWithString: "Перетащи MIDI или MP3 на окно")
    var mapPopup: NSPopUpButton!
    var loopPopup: NSPopUpButton!
    var tempoSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 2.0, target: nil, action: nil)
    var tempoLabel = NSTextField(labelWithString: "x1.00")
    var volumeSlider = NSSlider(value: 100, minValue: 10, maxValue: 300, target: nil, action: nil)
    var volumeLabel = NSTextField(labelWithString: "100%")
    var syncSlider = NSSlider(value: 0, minValue: -1000, maxValue: 1000, target: nil, action: nil)
    var syncLabel = NSTextField(labelWithString: "+0 мс")
    var metroBpmSlider = NSSlider(value: 120, minValue: 40, maxValue: 240, target: nil, action: nil)
    var metroBpmLabel = NSTextField(labelWithString: "120 BPM")
    var metroMeter: NSPopUpButton!
    var metroSoundBox = NSButton(checkboxWithTitle: "клик", target: nil, action: nil)
    var metroBtn: NSButton!
    var metroBeatLabel = NSTextField(labelWithString: "")
    var hdriver: HapticDriver?
    var metroRunning = false
    var clickHi: AVAudioPlayer?
    var clickLo: AVAudioPlayer?
    var channelsField = NSTextField(string: "all")
    var minVelField = NSTextField(string: "1")
    var verboseBox = NSButton(checkboxWithTitle: "подробно (-v)", target: nil, action: nil)
    var dryRunBox = NSButton(checkboxWithTitle: "только показать, без вибрации", target: nil, action: nil)
    var audioBox = NSButton(checkboxWithTitle: "🔊 звук вместе с вибрацией", target: nil, action: nil)
    var playBtn: NSButton!
    var stopBtn: NSButton!
    var progressBar = NSProgressIndicator()
    var timeLabel = NSTextField(labelWithString: "")
    var logView = NSTextView()

    // очередь
    var playlist: [String] = []
    var playQueue: [String] = []
    var queueIndex = 0
    var loopOne = false
    var loopAll = false
    var stopRequested = false
    var player: Process?
    var trackAudioOn = false
    var pendingOpen: [URL] = []
    var audioPlayer: AVMIDIPlayer?
    var avPlayer: AVPlayer?
    var progressTimer: Timer?
    var trackStart = Date()
    var trackDuration = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        log("Движок: \(enginePath())")
        scanDevice()
        if !pendingOpen.isEmpty {
            let u = pendingOpen
            pendingOpen = []
            openURLs(u)
        }
    }

    // двойной клик по .mid в Finder (когда мы .app): добавить и играть
    func application(_ application: NSApplication, open urls: [URL]) {
        // может прийти раньше, чем построено окно, — откладываем
        if window == nil {
            pendingOpen += urls
            return
        }
        openURLs(urls)
    }

    func openURLs(_ urls: [URL]) {
        let m = urls.map { $0.path }.filter {
            let e = ($0 as NSString).pathExtension.lowercased()
            return ["mid", "midi", "mp3", "wav", "m4a", "aiff", "aif", "flac"].contains(e)
        }
        if m.isEmpty { return }
        addFiles(m)
        if player == nil { play() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        metroRunning = false
        stopRequested = true
        stopPlayer(); stopAudio()
    }

    // ----- окно -----
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MIDI → Taptic Engine"
        window.center()

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        window.contentView = root

        let title = NSTextField(labelWithString: "MIDI → вибромотор макбука")
        title.font = .boldSystemFont(ofSize: 17)
        root.addArrangedSubview(title)

        let hint = NSTextField(labelWithString: "Во время игры держи палец на трекпаде — иначе не почувствуешь.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        root.addArrangedSubview(hint)

        dropView = DropView(frame: NSRect(x: 0, y: 0, width: 640, height: 100))
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.heightAnchor.constraint(equalToConstant: 100).isActive = true
        dropView.onFiles = { [weak self] files in self?.addFiles(files) }
        root.addArrangedSubview(dropView)

        // плейлист
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.title = "Плейлист"
        col.width = 620
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(playRow)
        let tscroll = NSScrollView()
        tscroll.hasVerticalScroller = true
        tscroll.documentView = table
        tscroll.heightAnchor.constraint(equalToConstant: 104).isActive = true
        root.addArrangedSubview(tscroll)

        let qrow = NSStackView()
        qrow.spacing = 8
        qrow.addArrangedSubview(NSTextField(labelWithString: "Режим:"))
        loopPopup = NSPopUpButton()
        loopPopup.addItems(withTitles: ["выбранное", "весь список", "🔂 повтор одного", "🔁 повтор всего"])
        qrow.addArrangedSubview(loopPopup)
        let addB = NSButton(title: "+ Добавить…", target: self, action: #selector(addClicked))
        let rmB = NSButton(title: "− Убрать", target: self, action: #selector(removeClicked))
        let clrB = NSButton(title: "Очистить", target: self, action: #selector(clearClicked))
        qrow.addArrangedSubview(addB)
        qrow.addArrangedSubview(rmB)
        qrow.addArrangedSubview(clrB)
        root.addArrangedSubview(qrow)

        fileLabel.font = .systemFont(ofSize: 12)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(fileLabel)

        // ряд настроек 1: маппинг + темп
        let row1 = NSStackView()
        row1.spacing = 8
        row1.addArrangedSubview(NSTextField(labelWithString: "Маппинг:"))
        mapPopup = NSPopUpButton()
        mapPopup.addItems(withTitles: ["velocity — по громкости", "pitch — по высоте", "drums — барабаны"])
        row1.addArrangedSubview(mapPopup)
        row1.addArrangedSubview(NSTextField(labelWithString: "Темп:"))
        tempoSlider.target = self
        tempoSlider.action = #selector(tempoChanged)
        tempoSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row1.addArrangedSubview(tempoSlider)
        tempoLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        row1.addArrangedSubview(tempoLabel)
        root.addArrangedSubview(row1)

        // громкость
        let rowVol = NSStackView()
        rowVol.spacing = 8
        rowVol.addArrangedSubview(NSTextField(labelWithString: "Громкость:"))
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        rowVol.addArrangedSubview(volumeSlider)
        volumeLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        rowVol.addArrangedSubview(volumeLabel)
        let volHint = NSTextField(labelWithString: "тише — лёгкие тапы, громче — сильные удары")
        volHint.font = .systemFont(ofSize: 11)
        volHint.textColor = .secondaryLabelColor
        rowVol.addArrangedSubview(volHint)
        root.addArrangedSubview(rowVol)

        // синхрон: сдвиг вибрации относительно звука (файлы + метроном)
        let rowSync = NSStackView()
        rowSync.spacing = 8
        rowSync.addArrangedSubview(NSTextField(labelWithString: "Синхрон:"))
        syncSlider.target = self
        syncSlider.action = #selector(syncChanged)
        syncSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        rowSync.addArrangedSubview(syncSlider)
        syncLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
        rowSync.addArrangedSubview(syncLabel)
        let syncHint = NSTextField(labelWithString: "сдвиг вибрации; в метрономе — вживую")
        syncHint.font = .systemFont(ofSize: 11)
        syncHint.textColor = .secondaryLabelColor
        rowSync.addArrangedSubview(syncHint)
        let nudgeMinus = NSButton(title: "−10 мс", target: self, action: #selector(syncNudgeMinus))
        let nudgePlus = NSButton(title: "+10 мс", target: self, action: #selector(syncNudgePlus))
        rowSync.addArrangedSubview(nudgeMinus)
        rowSync.addArrangedSubview(nudgePlus)
        root.addArrangedSubview(rowSync)

        // метроном — инструмент подгонки синхрона
        let mTitle = NSTextField(labelWithString: "Метроном — подгонка синхрона")
        mTitle.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(mTitle)
        let mHint = NSTextField(labelWithString: "Слушай клик и чувствуй вибрацию. Крути «Синхрон» выше, пока не совпадут.")
        mHint.font = .systemFont(ofSize: 11)
        mHint.textColor = .secondaryLabelColor
        root.addArrangedSubview(mHint)
        let mrow = NSStackView()
        mrow.spacing = 8
        metroBpmSlider.target = self
        metroBpmSlider.action = #selector(metroBpmChanged)
        metroBpmSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        mrow.addArrangedSubview(metroBpmSlider)
        metroBpmLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        mrow.addArrangedSubview(metroBpmLabel)
        mrow.addArrangedSubview(NSTextField(labelWithString: "Доли:"))
        metroMeter = NSPopUpButton()
        metroMeter.addItems(withTitles: ["2", "3", "4"])
        metroMeter.selectItem(at: 2)
        mrow.addArrangedSubview(metroMeter)
        metroSoundBox.state = .on
        mrow.addArrangedSubview(metroSoundBox)
        metroBtn = NSButton(title: "▶ Метроном", target: self, action: #selector(metroToggle))
        mrow.addArrangedSubview(metroBtn)
        metroBeatLabel.font = .systemFont(ofSize: 14)
        metroBeatLabel.textColor = .secondaryLabelColor
        metroBeatLabel.widthAnchor.constraint(equalToConstant: 120).isActive = true
        mrow.addArrangedSubview(metroBeatLabel)
        root.addArrangedSubview(mrow)

        // ряд настроек 2
        let row2 = NSStackView()
        row2.spacing = 8
        row2.addArrangedSubview(NSTextField(labelWithString: "Каналы:"))
        channelsField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        row2.addArrangedSubview(channelsField)
        row2.addArrangedSubview(NSTextField(labelWithString: "Min vel:"))
        minVelField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        row2.addArrangedSubview(minVelField)
        row2.addArrangedSubview(verboseBox)
        root.addArrangedSubview(row2)
        root.addArrangedSubview(dryRunBox)
        root.addArrangedSubview(audioBox)

        // кнопки
        let btns = NSStackView()
        btns.spacing = 8
        let sel = NSButton(title: "Выбрать файлы…", target: self, action: #selector(addClicked))
        playBtn = NSButton(title: "▶ Играть", target: self, action: #selector(play))
        playBtn.keyEquivalent = "\r"
        stopBtn = NSButton(title: "■ Стоп", target: self, action: #selector(stop))
        stopBtn.isEnabled = false
        let test = NSButton(title: "Тест вибрации", target: self, action: #selector(testBuzz))
        btns.addArrangedSubview(sel)
        btns.addArrangedSubview(playBtn)
        btns.addArrangedSubview(stopBtn)
        btns.addArrangedSubview(test)
        root.addArrangedSubview(btns)

        // прогресс
        let prow = NSStackView()
        prow.spacing = 8
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.widthAnchor.constraint(equalToConstant: 480).isActive = true
        prow.addArrangedSubview(progressBar)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        prow.addArrangedSubview(timeLabel)
        root.addArrangedSubview(prow)

        // лог
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = logView
        root.addArrangedSubview(scroll)

        window.makeKeyAndOrderFront(nil)
    }

    @objc func tempoChanged() {
        tempoLabel.stringValue = String(format: "x%.2f", tempoSlider.doubleValue)
    }
    @objc func volumeChanged() {
        volumeLabel.stringValue = String(format: "%.0f%%", volumeSlider.doubleValue)
    }
    @objc func syncChanged() {
        syncLabel.stringValue = String(format: "%+.0f мс", syncSlider.doubleValue)
        if player != nil { writeOffsetFile() } // движок подхватит на следующей ноте
    }
    @objc func syncNudgeMinus() { nudgeSync(by: -10) }
    @objc func syncNudgePlus() { nudgeSync(by: 10) }
    func nudgeSync(by ms: Double) {
        syncSlider.doubleValue = min(max(syncSlider.doubleValue + ms, -1000), 1000)
        syncChanged()
    }
    /// Живой сдвиг для движков: значение слайдера в файл, движок
    /// перечитывает его перед каждой нотой — подгонка наживую.
    static let offsetFile = "/tmp/midihaptic.offset"
    func writeOffsetFile() {
        try? "\(Int(syncSlider.doubleValue))".write(
            toFile: Self.offsetFile, atomically: true, encoding: .utf8)
    }
    @objc func metroBpmChanged() {
        metroBpmLabel.stringValue = String(format: "%.0f BPM", metroBpmSlider.doubleValue)
    }

    @objc func metroToggle() {
        metroRunning ? metroStop() : metroStart()
    }
    func metroStart() {
        if player != nil { log("Сначала останови игру (■ Стоп)"); return }
        if hdriver == nil {
            hdriver = HapticDriver()
            log(hdriver != nil ? "Метроном: драйвер Taptic готов"
                               : "Метроном: драйвер Taptic НЕ запустился")
        }
        guard hdriver != nil else { return }
        if clickHi == nil {
            clickHi = Self.makeClick(freq: 1900)
            clickLo = Self.makeClick(freq: 1400)
            if clickHi == nil { log("Метроном: не смог синтезировать клик") }
        }
        metroRunning = true
        metroBtn.title = "■ Метроном стоп"
        log("Метроном: \(Int(metroBpmSlider.doubleValue)) BPM — крути «Синхрон» до совпадения")
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            var n = 0
            var next = Self.mono() + 0.3
            while self.metroRunning {
                let bpm = self.metroBpmSlider.doubleValue
                let meter = self.metroMeter.indexOfSelectedItem + 2
                let accent = (n % meter == 0)
                let soundAt = next
                let tapAt = soundAt + self.syncSlider.doubleValue / 1000.0
                if tapAt <= soundAt {
                    Self.sleepUntil(tapAt)
                    if !self.metroRunning { break }
                    _ = self.hdriver?.fire(accent ? 6 : 4)
                    Self.sleepUntil(soundAt)
                    if !self.metroRunning { break }
                    self.playClick(accent)
                } else {
                    Self.sleepUntil(soundAt)
                    if !self.metroRunning { break }
                    self.playClick(accent)
                    Self.sleepUntil(tapAt)
                    if !self.metroRunning { break }
                    _ = self.hdriver?.fire(accent ? 6 : 4)
                }
                let beat = (n % meter) + 1
                let dots = (1 ... meter).map {
                    $0 == beat ? ($0 == 1 ? "◉" : "◎") : "○"
                }.joined(separator: " ")
                DispatchQueue.main.async { self.metroBeatLabel.stringValue = dots }
                n += 1
                next += 60.0 / max(bpm, 1)
            }
            DispatchQueue.main.async {
                self.metroBtn.title = "▶ Метроном"
                self.metroBeatLabel.stringValue = ""
            }
        }
    }
    func metroStop() { metroRunning = false }
    func playClick(_ accent: Bool) {
        guard metroSoundBox.state == .on else { return }
        DispatchQueue.main.async {
            let p = accent ? self.clickHi : self.clickLo
            p?.currentTime = 0
            p?.play()
        }
    }
    /// Синтез «тока» метронома в памяти (WAV 44.1к моно, 35 мс):
    /// синус + щелчок атаки с резким спадом.
    static func makeClick(freq: Double) -> AVAudioPlayer? {
        let sr = 44100
        let n = sr * 35 / 1000
        var pcm = [Int16](repeating: 0, count: n)
        var seed: UInt64 = 0x12345678
        for i in 0 ..< n {
            let t = Double(i) / Double(sr)
            let body = sin(2 * Double.pi * freq * t) * exp(-t / 0.006)
            var attack = 0.0
            if i < sr * 2 / 1000 {
                seed = seed &* 1103515245 &+ 12345
                attack = (Double((seed >> 16) & 0x7FFF) / Double(0x7FFF) - 0.5)
                    * exp(-t / 0.001) * 0.6
            }
            let v = Int((body + attack) * 26000)
            pcm[i] = Int16(min(max(v, -32768), 32767))
        }
        var wav = Data()
        func u32(_ v: UInt32) {
            wav.append(contentsOf: [
                UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF),
            ])
        }
        func u16(_ v: UInt16) {
            wav.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        }
        let dataBytes = n * 2
        wav.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        u32(16); u16(1); u16(1)
        u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        for s in pcm { u16(UInt16(bitPattern: s)) }
        do {
            let p = try AVAudioPlayer(data: wav)
            p.prepareToPlay()
            return p
        } catch {
            return nil
        }
    }
    static func mono() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
    }
    static func sleepUntil(_ deadline: Double) {
        let dt = deadline - mono()
        if dt <= 0 { return }
        var ts = timespec(tv_sec: time_t(dt), tv_nsec: Int((dt - Double(time_t(dt))) * 1e9))
        nanosleep(&ts, nil)
    }

    // ----- плейлист -----
    func numberOfRows(in tableView: NSTableView) -> Int { playlist.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let name = (playlist[row] as NSString).lastPathComponent
        return (isAudioFile(playlist[row]) ? "🔊 " : "🎹 ") + name
    }

    func addFiles(_ paths: [String]) {
        var added = 0
        for p in paths where !playlist.contains(p) {
            playlist.append(p); added += 1
        }
        table.reloadData()
        if added > 0 {
            table.selectRowIndexes(IndexSet(integer: playlist.count - 1), byExtendingSelection: false)
            table.scrollRowToVisible(playlist.count - 1)
            fileLabel.stringValue = "В очереди: \(playlist.count)"
            log("Добавлено файлов: \(added), всего: \(playlist.count)")
        }
    }

    @objc func addClicked() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["mid", "midi", "mp3", "wav", "m4a", "aiff", "flac"]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { addFiles(p.urls.map { $0.path }) }
    }
    @objc func removeClicked() {
        for i in table.selectedRowIndexes.sorted(by: >) { playlist.remove(at: i) }
        table.reloadData()
        fileLabel.stringValue = "В очереди: \(playlist.count)"
    }
    @objc func clearClicked() {
        playlist.removeAll()
        table.reloadData()
        fileLabel.stringValue = "Перетащи MIDI или MP3 на окно"
    }
    @objc func playRow() {
        let r = table.clickedRow
        if r >= 0 {
            table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            play()
        }
    }

    func singleSelection() -> [String] {
        let r = table.selectedRow
        if r >= 0 && r < playlist.count { return [playlist[r]] }
        if let f = playlist.first { return [f] }
        return []
    }

    // ----- игра очередью -----
    @objc func play() {
        if playlist.isEmpty { log("Список пуст — перетащи файлы на окно"); return }
        stopRequested = false
        metroStop()
        let mode = loopPopup.indexOfSelectedItem
        loopOne = (mode == 2)
        loopAll = (mode == 3)
        if mode == 1 || mode == 3 { playQueue = playlist }
        else { playQueue = singleSelection() }
        if playQueue.isEmpty { return }
        queueIndex = 0
        playNext()
    }

    func playNext() {
        if stopRequested { finishQueue(nil); return }
        if queueIndex >= playQueue.count {
            if loopAll && !playQueue.isEmpty { queueIndex = 0 }
            else { finishQueue("⏹ очередь готова"); return }
        }
        let f = playQueue[queueIndex]
        let name = (f as NSString).lastPathComponent
        trackDuration = probeDuration(f)
        trackAudioOn = false
        progressBar.doubleValue = 0
        timeLabel.stringValue = trackDuration > 0 ? "0:00 / \(fmtTime(trackDuration))" : name
        fileLabel.stringValue = "▶ \(name)  (трек \(queueIndex + 1)/\(playQueue.count))"
        writeOffsetFile() // стартовое значение живого сдвига для движка
        let isDry = dryRunBox.state == .on
        if isDry { beginAudioAndProgress(f) } // dry-run: как раньше, сразу
        runEngine(playArgs(for: f), tag: "играю \(name)", chain: true, tool: toolFor(f)) {
            [weak self] in
            guard let self = self else { return }
            // звук стартует по READY от движка — строго вместе с вибрацией
            if self.stopRequested || self.player == nil || isDry { return }
            self.beginAudioAndProgress(f)
        }
        // страховка: если READY не пришёл за 15 с — стартуем звук сами
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, myFile = f] in
            guard let self = self else { return }
            if !self.stopRequested && self.player != nil && !self.trackAudioOn &&
               self.queueIndex < self.playQueue.count &&
               self.playQueue[self.queueIndex] == myFile {
                self.log("READY не дождались — стартую звук сам")
                self.beginAudioAndProgress(myFile)
            }
        }
    }

    /// Старт звука и прогресса общей точкой (по READY от движка).
    func beginAudioAndProgress(_ f: String) {
        if trackAudioOn { return }
        trackAudioOn = true
        trackStart = Date()
        progressBar.doubleValue = 0
        startProgressTimer()
        startAudio(f)
    }

    func finishQueue(_ msg: String?) {
        player = nil
        trackAudioOn = false
        stopAudio(); stopProgressTimer()
        progressBar.doubleValue = 0
        playBtn.isEnabled = true; stopBtn.isEnabled = false
        fileLabel.stringValue = "В очереди: \(playlist.count)"
        if let m = msg { log(m) }
    }

    @objc func stop() {
        stopRequested = true
        stopPlayer()
        finishQueue("■ остановлено")
    }

    @objc func testBuzz() { runEngine(["--list"], tag: "тест", chain: false, tool: enginePath()) }

    // ----- движок -----
    func runEngine(_ args: [String], tag: String, chain: Bool, tool: String,
                   onReady: (() -> Void)? = nil) {
        stopPlayer()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var readyBuf = ""
        var readyFired = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(data: h.availableData, encoding: .utf8) ?? ""
            if s.isEmpty { return }
            if !readyFired, let cb = onReady {
                readyBuf += s
                if readyBuf.contains("READY") {
                    readyFired = true
                    DispatchQueue.main.async { cb() }
                }
                if readyBuf.count > 4096 {
                    readyBuf = String(readyBuf.suffix(1024))
                }
            }
            DispatchQueue.main.async { self?.log(s, noprefix: true) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !chain {
                    self.player = nil
                    self.playBtn.isEnabled = true
                    self.stopBtn.isEnabled = false
                    self.log("[\(tag) завершён]")
                    return
                }
                self.stopAudio()
                self.stopProgressTimer()
                if self.stopRequested { self.finishQueue(nil); return }
                self.log("[трек готов]")
                if !self.loopOne { self.queueIndex += 1 }
                self.playNext()
            }
        }
        do {
            try p.run()
            player = p
            playBtn.isEnabled = false
            stopBtn.isEnabled = true
            log("▶ \(tag)")
        } catch {
            log("ОШИБКА запуска: \(error)")
        }
    }

    func stopPlayer() {
        if let p = player, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if p.isRunning { p.interrupt(); kill(p.processIdentifier, SIGKILL) }
            }
        }
        player = nil
        playBtn?.isEnabled = true
        stopBtn?.isEnabled = false
    }

    func playArgs(for path: String) -> [String] {
        let g = String(format: "%.2f", min(volumeSlider.doubleValue / 100.0, 2.0))
        var a: [String]
        if isAudioFile(path) {
            a = [path, "-g", g]
        } else {
            let maps = ["velocity", "pitch", "drums"]
            a = [path, "-m", maps[mapPopup.indexOfSelectedItem],
                 "-t", String(format: "%.2f", tempoSlider.doubleValue),
                 "-g", g,
                 "-c", channelsField.stringValue.trimmingCharacters(in: .whitespaces),
                 "--min-vel", minVelField.stringValue.trimmingCharacters(in: .whitespaces)]
        }
        if verboseBox.state == .on { a.append("-v") }
        if dryRunBox.state == .on { a.append("-n") }
        a += ["--offset-ms", "\(Int(syncSlider.doubleValue))"]
        a += ["--offset-file", Self.offsetFile]
        a.append("--immediate") // без секундной паузы: старт строго по READY
        return a
    }

    // длительность через мгновенный --info (без игры и без вибрации)
    func probeDuration(_ path: String) -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: toolFor(path))
        p.arguments = ["--info", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run(); p.waitUntilExit()
        } catch { return 0 }
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let r = s.range(of: "длительность:") {
            let tail = s[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if let num = tail.split(separator: " ").first, let d = Double(num) { return d }
        }
        return 0
    }

    // ----- звук -----
    func startAudio(_ path: String) {
        stopAudio()
        guard audioBox.state == .on else { return }
        if isAudioFile(path) {
            // сам трек через AVPlayer, вибрация — по битам из audio_haptic
            let pl = AVPlayer(url: URL(fileURLWithPath: path))
            avPlayer = pl
            pl.play()
            log("🔊 играет оригинал + вибрация по битам")
            return
        }
        do {
            let pl = try AVMIDIPlayer(contentsOf: URL(fileURLWithPath: path), soundBankURL: nil)
            pl.rate = Float(min(max(tempoSlider.doubleValue, 0.5), 2.0))
            pl.prepareToPlay()
            audioPlayer = pl
            pl.play()
            log("🔊 звук включён (темп совпадает со слайдером)")
        } catch {
            log("🔊 без звука (\(error)) — играю только вибрацию")
        }
    }
    func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        avPlayer?.pause()
        avPlayer = nil
    }

    // ----- прогресс -----
    func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
    }
    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    func tickProgress() {
        guard trackDuration > 0 else { return }
        let e = Date().timeIntervalSince(trackStart)
        progressBar.doubleValue = min(100 * e / trackDuration, 100)
        timeLabel.stringValue = "\(fmtTime(e)) / \(fmtTime(trackDuration))"
    }
    func fmtTime(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    func scanDevice() {
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: enginePath())
            p.arguments = ["--scan"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run(); p.waitUntilExit()
                let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async { self?.log(s, noprefix: true) }
            } catch {
                DispatchQueue.main.async { self?.log("Движок не запустился: \(error)") }
            }
        }
    }

    func log(_ s: String, noprefix: Bool = false) {
        let t = noprefix ? s : "• \(s)\n"
        logView.string += t.hasSuffix("\n") ? t : t + "\n"
        logView.scrollToEndOfDocument(nil)
    }
}
