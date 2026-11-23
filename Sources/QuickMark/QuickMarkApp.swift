import AppKit

@main
@MainActor
enum QuickMarkMain {
    // NSApplication.delegate is weak, so keep a strong reference here.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
