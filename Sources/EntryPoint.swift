import AppKit
import Darwin

@main
struct EntryPoint {
    @MainActor
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.dropFirst().first == "--proxy-worker" {
            guard let xray = Bundle.main.url(forAuxiliaryExecutable: "xray") else { exit(1) }
            exit(ProxyWorker.run(xray: xray))
        }

        let app = NSApplication.shared
        let delegate = MenuController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
