import AppKit

@MainActor
final class MenuController: NSObject, NSApplicationDelegate {
    private struct Session {
        let target: CodexApplication
        let application: NSRunningApplication
        let proxy: ManagedProxy
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let stateRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let profileRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleRow = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
    private let openRow = NSMenuItem(title: "Открыть Codex", action: #selector(openCodex), keyEquivalent: "")
    private let checkRow = NSMenuItem(title: "Проверить соединение", action: #selector(checkConnection), keyEquivalent: "")
    private let telegramOpenRow = NSMenuItem(
        title: "Открыть Telegram через прокси…", action: #selector(openTelegram), keyEquivalent: ""
    )
    private let telegramStopRow = NSMenuItem(
        title: "Остановить прокси Telegram", action: #selector(stopTelegramProxy), keyEquivalent: ""
    )
    private let settingsRow = NSMenuItem(title: "Подключение", action: nil, keyEquivalent: "")
    private let quitRow = NSMenuItem(title: "Выйти из переключателя", action: #selector(quit), keyEquivalent: "q")
    private var timer: Timer?
    private var profile: ProxyProfile?
    private var session: Session?
    private var telegramProxy: ManagedProxy?
    private var activity: String?
    private var failedCheck = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = NSMenu()
        settings.addItem(withTitle: "Ключ Xray…", action: #selector(editXray), keyEquivalent: "").target = self
        settings.addItem(withTitle: "Локальный прокси…", action: #selector(editLocal), keyEquivalent: "").target = self
        settingsRow.submenu = settings

        let menu = NSMenu(title: "RouteFork")
        menu.autoenablesItems = false
        for row in [
            stateRow, profileRow, .separator(), toggleRow, openRow, checkRow, .separator(),
            telegramOpenRow, telegramStopRow, .separator(), settingsRow, quitRow
        ] {
            if row.action != nil { row.target = self }
            menu.addItem(row)
        }
        statusItem.menu = menu
        do {
            profile = try ProfileStore.load()
        } catch {
            present(title: "Профиль подключения недоступен", detail: error.localizedDescription)
        }
        render()

        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSession() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        session?.proxy.stop()
        telegramProxy?.stop()
    }

    private func updateSession() {
        guard activity == nil, session != nil || telegramProxy != nil else { return }
        if let session, session.application.isTerminated {
            session.proxy.stop()
            self.session = nil
            failedCheck = false
        }
        if telegramProxy?.isRunning == false { telegramProxy = nil }
        render()
    }

    private func render() {
        let symbol: String
        let state: String
        if let activity {
            symbol = "shield.lefthalf.filled"
            state = activity
        } else if let session {
            if !session.proxy.isRunning || failedCheck {
                symbol = "shield.slash"
                state = session.proxy.isRunning ? "Прокси недоступен" : "Xray остановился"
            } else {
                symbol = "shield.fill"
                state = "Прокси для Codex включён"
            }
        } else if telegramProxy?.isRunning == true {
            symbol = "shield.fill"
            state = "SOCKS5 для Telegram готов"
        } else {
            symbol = "shield"
            state = "Прокси для Codex выключен"
        }

        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: state)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            icon?.isTemplate = true
            button.image = icon
            button.title = icon == nil ? "VPN" : ""
            button.toolTip = state
            button.setAccessibilityLabel("RouteFork. \(state)")
        }
        stateRow.title = state
        stateRow.isEnabled = false
        let connection = profile?.title ?? "Добавь подключение"
        if let route = session?.proxy.directRoute ?? telegramProxy?.directRoute {
            profileRow.title = "\(connection) · \(route.label)"
        } else {
            profileRow.title = connection
        }
        profileRow.isEnabled = false
        toggleRow.title = session == nil ? "Включить прокси Codex…" : "Выключить прокси Codex…"
        openRow.isEnabled = activity == nil
        toggleRow.isEnabled = activity == nil
        telegramOpenRow.isEnabled = activity == nil
        telegramStopRow.isHidden = telegramProxy?.isRunning != true
        telegramStopRow.isEnabled = activity == nil
        settingsRow.isEnabled = activity == nil && session == nil && telegramProxy == nil
        checkRow.isHidden = session == nil
        checkRow.isEnabled = activity == nil && session?.proxy.isRunning == true
        quitRow.isEnabled = activity == nil
    }

    @objc private func toggle() {
        guard activity == nil else { return }
        if session != nil {
            operate("Выключаю прокси…") { try await self.disable(thenQuit: false) }
            return
        }
        if profile == nil, !editProfile(kind: .xray) { return }
        guard let profile else { return }
        operate("Проверяю прокси…") { try await self.enable(using: profile) }
    }

    private func enable(using profile: ProxyProfile) async throws {
        let target = try CodexApplication.installed()
        let proxy = try await ManagedProxy.start(profile: profile)
        var stoppedExistingApp = false
        do {
            _ = try await ProxyProbe.check(port: proxy.port)
            let previous = try target.running()
            if previous != nil {
                guard confirmRestart(enabling: true) else {
                    proxy.stop()
                    return
                }
                _ = try await ProxyProbe.check(port: proxy.port)
            }
            guard proxy.isRunning else { throw ProxyRuntimeError.stopped }
            activity = previous == nil ? "Открываю Codex…" : "Перезапускаю Codex…"
            render()
            try await target.stop(previous)
            stoppedExistingApp = previous != nil
            guard proxy.isRunning else { throw ProxyRuntimeError.stopped }
            let application = try await target.launch(proxyPort: proxy.port)
            session = Session(target: target, application: application, proxy: proxy)
        } catch {
            proxy.stop()
            if stoppedExistingApp {
                if offerOrdinaryLaunch(after: error) {
                    _ = try await target.launch(proxyPort: nil)
                }
                return
            }
            throw error
        }
    }

    private func offerOrdinaryLaunch(after error: Error) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Codex не запустился через прокси"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Открыть обычным способом")
        alert.addButton(withTitle: "Закрыть")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func disable(thenQuit: Bool) async throws {
        if let session {
            let wasRunning = !session.application.isTerminated
            if wasRunning {
                guard confirmRestart(enabling: false, thenQuit: thenQuit) else { return }
                try await session.target.stop(session.application)
            }
            self.session = nil
            failedCheck = false
            session.proxy.stop()
            if wasRunning { _ = try await session.target.launch(proxyPort: nil) }
        }
        if thenQuit { NSApp.terminate(nil) }
    }

    @objc private func openCodex() {
        operate("Открываю Codex…") {
            let target = try CodexApplication.installed()
            _ = try await target.launch(proxyPort: nil)
        }
    }

    @objc private func openTelegram() {
        guard activity == nil else { return }
        if profile == nil, !editProfile(kind: .xray) { return }
        guard let profile else { return }
        operate("Подключаю Telegram…") { try await self.enableTelegram(using: profile) }
    }

    private func enableTelegram(using profile: ProxyProfile) async throws {
        let telegram = try TelegramApplication.installed()
        let probeURL = URL(string: "https://telegram.org/")!
        if let existing = telegramProxy {
            if existing.isRunning,
               (try? await ProxyProbe.check(port: existing.port, listener: .socks5, url: probeURL)) != nil {
                try await telegram.open(proxyPort: existing.port)
                return
            }
            try await existing.stopAndWait()
            telegramProxy = nil
        }
        let preferences = UserDefaults.standard
        let portKey = "TelegramSOCKS5Port"
        let lastPort = UInt16(exactly: preferences.integer(forKey: portKey))
        let proxy = try await ManagedProxy.start(profile: profile, listener: .socks5, preferredPort: lastPort)
        do {
            _ = try await ProxyProbe.check(port: proxy.port, listener: .socks5, url: probeURL)
            guard proxy.isRunning else { throw ProxyRuntimeError.stopped }
            try await telegram.open(proxyPort: proxy.port)
            preferences.set(Int(proxy.port), forKey: portKey)
            telegramProxy = proxy
        } catch {
            proxy.stop()
            throw error
        }
    }

    @objc private func stopTelegramProxy() {
        guard activity == nil, let telegramProxy else { return }
        operate("Останавливаю прокси Telegram…") {
            try await telegramProxy.stopAndWait()
            self.telegramProxy = nil
            self.present(title: "Прокси Telegram остановлен",
                         detail: "Чтобы Telegram подключался обычным способом, выключи SOCKS5 в его настройках прокси.")
        }
    }

    @objc private func checkConnection() {
        guard let session else { return }
        operate("Проверяю прокси…") {
            do {
                let code = try await ProxyProbe.check(port: session.proxy.port)
                self.failedCheck = false
                self.present(title: "Прокси отвечает", detail: "HTTPS до chatgpt.com через прокси работает (HTTP \(code)).")
            } catch {
                self.failedCheck = true
                throw error
            }
        }
    }

    @objc private func quit() {
        operate("Закрываю переключатель…") { try await self.disable(thenQuit: true) }
    }

    private func operate(_ title: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard activity == nil else { return }
        activity = title
        render()
        Task {
            do {
                try await action()
            } catch DirectEgressError.unreachable(let interface, let addresses) {
                let failure = DirectEgressError.unreachable(interface, addresses)
                present(title: "Нет прямого соединения с Xray", detail: failure.localizedDescription,
                        copyText: addresses.joined(separator: ", "))
            } catch {
                present(title: "Не удалось выполнить действие", detail: error.localizedDescription)
            }
            activity = nil
            updateSession()
            render()
        }
    }

    @objc private func editXray() { _ = editProfile(kind: .xray) }
    @objc private func editLocal() { _ = editProfile(kind: .local) }

    private func editProfile(kind: ProxyProfile.Kind) -> Bool {
        guard activity == nil, session == nil, telegramProxy == nil else { return false }
        let alert = NSAlert()
        let isXray = kind == .xray
        alert.messageText = isXray ? "Ключ Xray" : "Локальный прокси"
        alert.informativeText = isXray
            ? "Вставь одну ссылку vless://. Xray подключится к серверу через Wi‑Fi или Ethernet."
            : "Вставь адрес HTTP или SOCKS5 на 127.0.0.1. Сетевой маршрут задаёт приложение, запустившее прокси."
        let initialValue = !isXray && profile?.kind == .local ? profile?.value ?? "" : ""
        let input = ProfileInput(secure: isXray, initialValue: initialValue)
        let field = input.field
        alert.accessoryView = input
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let newProfile = try ProxyProfile(field.stringValue)
                guard newProfile.kind == kind else { throw isXray ? ProfileError.key : ProfileError.localAddress }
                try ProfileStore.save(newProfile)
                profile = newProfile
                render()
                return true
            } catch {
                present(title: "Не удалось сохранить подключение", detail: error.localizedDescription)
            }
        }
        return false
    }

    private func confirmRestart(enabling: Bool, thenQuit: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = enabling ? "Перезапустить Codex через прокси?" : "Перезапустить Codex без этого прокси?"
        alert.informativeText = "Дождись завершения текущих задач. Codex будет закрыт и открыт снова."
        alert.addButton(withTitle: thenQuit ? "Перезапустить и выйти" : "Перезапустить")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(title: String, detail: String, copyText: String? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if copyText != nil { alert.addButton(withTitle: "Скопировать IP") }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let copyText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText, forType: .string)
        }
    }
}
