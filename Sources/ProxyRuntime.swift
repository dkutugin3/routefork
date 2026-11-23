import Darwin
import Foundation

enum ProxyRuntimeError: LocalizedError {
    case files
    case localPort
    case startup
    case stopped
    case stopTimeout
    case connection

    var errorDescription: String? {
        switch self {
        case .files: return "В приложении не найден исполняемый файл Xray."
        case .localPort: return "Не удалось выделить локальный порт для Xray."
        case .startup: return "Xray не запустился. Проверь параметры подключения."
        case .stopped: return "Xray остановился. Подключись снова."
        case .stopTimeout: return "Xray не успел завершиться. Повтори действие через несколько секунд."
        case .connection: return "Не удалось установить HTTPS-соединение через прокси. Проверь профиль и доступность сервера."
        }
    }
}

@MainActor
final class ManagedProxy {
    let port: UInt16
    let directRoute: DirectXrayRoute?
    var isRunning: Bool { worker.isRunning }

    private let worker: Process
    private let lifetime: FileHandle

    private init(port: UInt16, directRoute: DirectXrayRoute?, worker: Process, lifetime: FileHandle) {
        self.port = port
        self.directRoute = directRoute
        self.worker = worker
        self.lifetime = lifetime
    }

    deinit {
        try? lifetime.close()
    }

    static func start(
        profile: ProxyProfile, listener: ProxyListener = .http,
        preferredPort: UInt16? = nil, bundle: Bundle = .main
    ) async throws -> ManagedProxy {
        guard let executable = bundle.executableURL,
              let xray = bundle.url(forAuxiliaryExecutable: "xray"),
              FileManager.default.isExecutableFile(atPath: xray.path)
        else { throw ProxyRuntimeError.files }
        let route: DirectXrayRoute?
        if let endpoint = profile.xrayEndpoint {
            let fallbackAddresses = bundle.object(forInfoDictionaryKey: "XrayFallbackAddresses") as? [String: String] ?? [:]
            route = try await Task.detached(priority: .userInitiated) {
                try DirectEgress.verify(endpoint, fallbackAddresses: fallbackAddresses)
            }.value
        } else {
            route = nil
        }
        let port = try Loopback.availablePort(excluding: profile.upstreamPort, preferred: preferredPort)
        var config = try profile.xrayJSON(listenPort: port, directRoute: route, listener: listener)
        config.append(10)

        let pipe = Pipe()
        let worker = Process()
        worker.executableURL = executable
        worker.arguments = ["--proxy-worker"]
        worker.standardInput = pipe
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        let proxy = ManagedProxy(port: port, directRoute: route, worker: worker, lifetime: pipe.fileHandleForWriting)
        do {
            try worker.run()
            try proxy.lifetime.write(contentsOf: config)
            for _ in 0..<40 {
                guard worker.isRunning else { break }
                if Loopback.isListening(port: port) { return proxy }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ProxyRuntimeError.startup
        } catch {
            proxy.stop()
            throw ProxyRuntimeError.startup
        }
    }

    func stop() {
        try? lifetime.close()
    }

    func stopAndWait() async throws {
        stop()
        for _ in 0..<40 {
            if !isRunning { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if isRunning { throw ProxyRuntimeError.stopTimeout }
    }
}

enum ProxyWorker {
    static func run(xray: URL) -> Int32 {
        guard let config = readLine(), !config.isEmpty, config.utf8.count <= 32_768 else { return 1 }
        let pipe = Pipe()
        let child = Process()
        child.executableURL = xray
        child.arguments = ["run", "-config", "stdin:"]
        let inheritedProxies: Set<String> = ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        child.environment = ProcessInfo.processInfo.environment.filter { !inheritedProxies.contains($0.key.lowercased()) }
        child.standardInput = pipe
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            try pipe.fileHandleForWriting.write(contentsOf: Data(config.utf8))
            try pipe.fileHandleForWriting.close()
        } catch {
            if child.isRunning { child.terminate() }
            return 1
        }

        // The menu app owns the only writer. A crash also closes this pipe.
        DispatchQueue.global(qos: .utility).async {
            _ = try? FileHandle.standardInput.read(upToCount: 1)
            if child.isRunning { child.terminate() }
        }
        child.waitUntilExit()
        return child.terminationStatus
    }
}

enum ProxyProbe {
    static func check(
        port: UInt16, listener: ProxyListener = .http,
        url: URL = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    ) async throws -> Int {
        let output = Pipe()
        let curl = Process()
        let expectedConnectStatus = listener == .http ? 200 : 0
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "-q", "--silent", "--head", "--proto", "=https",
            "--connect-timeout", "4", "--max-time", "8",
            "--proxy", "\(listener.curlScheme)://127.0.0.1:\(port)", "--noproxy", "",
            "--output", "/dev/null", "--write-out", "%{http_connect} %{http_code}",
            url.absoluteString
        ]
        curl.standardInput = FileHandle.nullDevice
        curl.standardOutput = output
        curl.standardError = FileHandle.nullDevice
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            curl.terminationHandler = { process in
                let response = output.fileHandleForReading.readDataToEndOfFile()
                let codes = String(decoding: response, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
                guard process.terminationStatus == 0, codes.count == 2, codes[0] == expectedConnectStatus,
                      (100...599).contains(codes[1])
                else {
                    continuation.resume(throwing: ProxyRuntimeError.connection)
                    return
                }
                continuation.resume(returning: codes[1])
            }
            do {
                try curl.run()
            } catch {
                continuation.resume(throwing: ProxyRuntimeError.connection)
            }
        }
        return code
    }
}

private enum Loopback {
    static func availablePort(excluding: UInt16?, preferred: UInt16? = nil) throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProxyRuntimeError.localPort }
        defer { close(descriptor) }
        let requested = preferred == excluding ? 0 : preferred ?? 0
        if requested != 0 {
            var reuse: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0
            else { throw ProxyRuntimeError.localPort }
        }
        var address = localAddress(port: requested)
        let bound = withAddress(&address) { pointer, length in bind(descriptor, pointer, length) }
        if bound != 0, requested != 0, errno == EADDRINUSE {
            return try availablePort(excluding: excluding)
        }
        guard bound == 0 else { throw ProxyRuntimeError.localPort }

        // An unavailable upstream may own no socket when the OS assigns the port.
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard result == 0, port > 0 else { throw ProxyRuntimeError.localPort }
        if port == excluding {
            // Reserve the excluded port while asking the OS for another one.
            return try availablePort(excluding: nil)
        }
        return port
    }

    static func isListening(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = localAddress(port: port)
        return withAddress(&address) { pointer, length in connect(descriptor, pointer, length) } == 0
    }

    private static func localAddress(port: UInt16) -> sockaddr_in {
        sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
    }

    private static func withAddress<T>(
        _ address: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
