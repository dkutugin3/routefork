import AppKit

enum TelegramApplicationError: LocalizedError {
    case missing
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .missing: return "Telegram не найден. Установи приложение Telegram для macOS."
        case .cannotOpen: return "Не удалось открыть Telegram с настройками SOCKS5."
        }
    }
}

@MainActor
struct TelegramApplication {
    let url: URL

    static func installed() throws -> TelegramApplication {
        let identifiers = ["ru.keepcoder.Telegram", "org.telegram.desktop"]
        let workspace = NSWorkspace.shared
        for identifier in identifiers {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { !$0.isTerminated })?.bundleURL {
                return TelegramApplication(url: running)
            }
        }
        guard let app = identifiers.lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first
        else { throw TelegramApplicationError.missing }
        return TelegramApplication(url: app)
    }

    static func proxyURL(port: UInt16) -> URL {
        var components = URLComponents()
        components.scheme = "tg"
        components.host = "socks"
        components.queryItems = [
            URLQueryItem(name: "server", value: "127.0.0.1"),
            URLQueryItem(name: "port", value: String(port))
        ]
        return components.url!
    }

    func open(proxyPort: UInt16) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.open(
                [Self.proxyURL(port: proxyPort)], withApplicationAt: url, configuration: configuration
            )
        } catch {
            throw TelegramApplicationError.cannotOpen
        }
    }
}
