// Точка входа ритм-игры (@main работает в файле с любым именем).
import AppKit

@main
struct GameMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = RhythmGame()
        app.delegate = delegate
        app.run()
    }
}
