import AppKit

enum CodexApplicationError: LocalizedError {
    case missing
    case multiple
    case cannotQuit
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .missing: return "Не найден настольный Codex. Проверь, что Codex установлен в папку «Программы»."
        case .multiple: return "Открыто несколько экземпляров Codex. Закрой лишние экземпляры и повтори."
        case .cannotQuit: return "Codex не завершился. Дождись окончания задач, закрой Codex через ⌘Q и повтори."
        case .cannotOpen: return "Не удалось открыть Codex. Попробуй открыть его из меню переключателя."
        }
    }
}

@MainActor
struct CodexApplication {
    let url: URL
    let identifier: String

    static func installed() throws -> CodexApplication {
        let identifier = "com.openai.codex"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications")]
        let standard = folders.flatMap { folder in
            ["Codex.app", "ChatGPT.app"].map { folder.appendingPathComponent($0, isDirectory: true) }
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }.compactMap(\.bundleURL)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        let candidates = running + standard + [registered].compactMap { $0 }
        guard let url = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == identifier }) else {
            throw CodexApplicationError.missing
        }
        return CodexApplication(url: url, identifier: identifier)
    }

    func running() throws -> NSRunningApplication? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }
        guard applications.count <= 1 else { throw CodexApplicationError.multiple }
        return applications.first
    }

    func stop(_ application: NSRunningApplication?) async throws {
        guard let application, !application.isTerminated else { return }
        guard application.terminate() || application.isTerminated else { throw CodexApplicationError.cannotQuit }
        let deadline = ContinuousClock.now + .seconds(15)
        while !application.isTerminated && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard application.isTerminated else { throw CodexApplicationError.cannotQuit }
    }

    func launch(proxyPort: UInt16?) async throws -> NSRunningApplication {
        let options = CodexLaunchOptions(proxyPort: proxyPort)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = options.arguments
        configuration.environment = options.environment
        configuration.createsNewApplicationInstance = proxyPort != nil
        configuration.addsToRecentItems = false
        if proxyPort != nil, try running() != nil { throw CodexApplicationError.multiple }

        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw CodexApplicationError.cannotOpen
        }
        // Launch Services can return before the Electron single-instance check completes.
        if proxyPort != nil { try await Task.sleep(for: .milliseconds(1100)) }
        guard !application.isTerminated else { throw CodexApplicationError.cannotOpen }
        return application
    }
}
