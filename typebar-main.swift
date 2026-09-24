// Точка входа TypeBar — меню-бар печатной машинки.
import AppKit

@main
struct TypeBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = TypeBarApp()
        app.delegate = delegate
        app.run()
    }
}
