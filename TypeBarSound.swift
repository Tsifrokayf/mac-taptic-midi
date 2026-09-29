// TypeBarSound.swift — щелчок клавиши для TypeBar.
// AVAudioEngine + пул AVAudioPlayerNode: файл конвертируется в общий
// буфер (44.1 кГц, моно, Float32), поэтому нажатия играют без задержки
// и не конфликтуют по форматам (44.1/48 кГц, стерео/моно).
// Встроенные звуки — sounds/*.wav (см. sounds/CREDITS.txt), свой — путь
// из конфига soundfile=. Группа «Ввод» звучит кареткой return005.wav.
import AVFoundation

final class ClickSound {
    /// Встроенные варианты: id = значение конфига soundpick=.
    static let picks: [(id: Int, title: String, file: String)] = [
        (1, "Щелчок", "key004"),
        (2, "Машинка", "key010"),
        (3, "Клик", "key001"),
        (4, "Тихий", "key009"),
    ]
    /// Отдельный звук клавиши ввода (возврат каретки), если файл есть.
    static let enterFile = "return005"

    private static let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100,
        channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var mainBuf: AVAudioPCMBuffer?
    private var enterBuf: AVAudioPCMBuffer?
    private var next = 0
    private var running = false
    private(set) var lastError = ""
    /// Куда сплевывать диагностику (dlog приложения).
    var log: ((String) -> Void)?
    var volume: Float = 0.6
    var isOn = true

    /// Резолв файла: 1...4 — встроенные, 0 — свой путь (soundfile=).
    static func url(pick: Int, custom: String) -> URL? {
        if pick == 0 {
            let p = custom.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { return nil }
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let name = picks.first { $0.id == pick }?.file ?? picks[0].file
        return locate(name)
    }

    /// Искать в Resources бандла, потом рядом с бинарём (запуск из репо).
    private static func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        if let u = Bundle.main.url(forResource: name, withExtension: "wav",
                                   subdirectory: "sounds") {
            return u
        }
        var cands = [URL]()
        if let exe = Bundle.main.executableURL {
            cands.append(exe.deletingLastPathComponent()
                .appendingPathComponent("sounds/\(name).wav"))
        }
        cands.append(URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("sounds/\(name).wav"))
        return cands.first { fm.fileExists(atPath: $0.path) }
    }

    /// (Пере)грузить звук. false + lastError — файл не найден/не читается.
    @discardableResult
    func configure(pick: Int, custom: String) -> Bool {
        lastError = ""
        guard let url = Self.url(pick: pick, custom: custom) else {
            mainBuf = nil
            enterBuf = nil
            lastError = "файл звука не найден"
            return false
        }
        guard let buf = Self.buffer(from: url) else {
            mainBuf = nil
            lastError = "не удалось прочитать \(url.lastPathComponent)"
            return false
        }
        mainBuf = buf
        if pick != 0, let eu = Self.locate(Self.enterFile),
           let eb = Self.buffer(from: eu) {
            enterBuf = eb // каретка — только для встроенных звуков
        } else {
            enterBuf = nil
        }
        return startEngine()
    }

    private func startEngine() -> Bool {
        if running { return true }
        if players.isEmpty {
            for _ in 0 ..< 4 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: Self.dstFormat)
                players.append(p)
            }
        }
        do {
            try engine.start()
            running = true
            // Узлы стартуют в состоянии stopped: без play() scheduleBuffer
            // молчит — проверено замером на tap'е (peak=0 без play()).
            for p in players { p.play() }
        } catch {
            lastError = "аудио не запустилось: \(error.localizedDescription)"
            running = false
        }
        return running
    }

    /// Щелчок. group == "enter" — каретка, если встроена.
    func play(group: String = "key") {
        guard isOn else { log?("snd skip: выключен"); return }
        guard volume > 0.01 else { log?("snd skip: громкость 0"); return }
        guard running else { log?("snd skip: движок не запущен"); return }
        guard let main = mainBuf else { log?("snd skip: буфер пуст"); return }
        let buf = (group == "enter" && enterBuf != nil) ? enterBuf! : main
        let p = players[next]
        next = (next + 1) % players.count
        p.volume = volume
        p.scheduleBuffer(buf, at: nil, options: .interrupts)
        p.play() // иначе узел остаётся stopped и не звучит
    }

    /// Обрезанный/залипший звук не должен накапливаться на нодах.
    func stop() {
        for p in players { p.stop() }
    }

    /// Файл -> общий буфер 44.1 кГц моно. Длинный свой файл режем на 5 с.
    private static func buffer(from url: URL) -> AVAudioPCMBuffer? {
        guard let src = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = src.processingFormat
        guard let conv = AVAudioConverter(from: inFmt, to: dstFormat) else {
            return nil
        }
        let ratio = dstFormat.sampleRate / inFmt.sampleRate
        let maxFrames = AVAudioFrameCount(dstFormat.sampleRate * 5)
        let cap = min(AVAudioFrameCount(Double(src.length) * ratio) + 4096,
                      maxFrames + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat,
                                         frameCapacity: cap) else { return nil }
        var eof = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if eof {
                status.pointee = .endOfStream
                return nil
            }
            guard let b = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 16384)
            else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try src.read(into: b)
            } catch {
                status.pointee = .endOfStream
                return nil
            }
            if b.frameLength == 0 {
                eof = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return b
        }
        guard out.frameLength > 0 else { return nil }
        return out
    }
}
