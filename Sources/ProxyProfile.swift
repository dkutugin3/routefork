import Foundation

enum ProxyListener {
    case http
    case socks5

    var xrayProtocol: String { self == .http ? "http" : "socks" }
    var curlScheme: String { self == .http ? "http" : "socks5h" }
}

struct XrayEndpoint: Sendable {
    let host: String
    let port: UInt16
}

struct DirectXrayRoute: Sendable {
    let interface: String
    let label: String
    let address: String
}

enum ProfileError: LocalizedError {
    case address
    case localAddress
    case key
    case transport
    case reality
    case insecureTLS

    var errorDescription: String? {
        switch self {
        case .address: return "Нужна ссылка vless:// или адрес локального HTTP/SOCKS5-прокси."
        case .localAddress: return "Укажи локальный прокси с портом, например socks5://127.0.0.1:1080."
        case .key: return "Вставь один полный ключ vless:// с UUID и портом сервера."
        case .transport: return "Поддерживаются Xray gRPC/TLS, TCP/TLS и TCP/REALITY."
        case .reality: return "В ключе REALITY проверь параметры sni, pbk и sid."
        case .insecureTLS: return "Для TLS требуется проверка сертификата сервера."
        }
    }
}

struct ProxyProfile {
    enum Kind {
        case xray, local
    }

    let value: String
    let title: String
    let kind: Kind
    let upstreamPort: UInt16?
    let xrayEndpoint: XrayEndpoint?
    private let outbound: [String: Any]

    init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URLComponents(string: value), let scheme = url.scheme?.lowercased()
        else { throw ProfileError.address }
        self.value = value

        switch scheme {
        case "http", "socks5":
            guard let host = url.host?.lowercased(),
                  ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
                  let port = url.port.flatMap(UInt16.init(exactly:)), port > 0,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/"
            else { throw ProfileError.localAddress }
            let address = host.hasSuffix(":1]") || host == "::1" ? "::1" : "127.0.0.1"
            kind = .local
            upstreamPort = port
            xrayEndpoint = nil
            title = "Локальный \(scheme.uppercased())"
            outbound = [
                "protocol": scheme == "http" ? "http" : "socks",
                "settings": ["servers": [["address": address, "port": Int(port)]]]
            ]
        case "vless":
            kind = .xray
            upstreamPort = nil
            let (settings, description, endpoint) = try Self.vlessOutbound(url)
            outbound = settings
            title = description
            xrayEndpoint = endpoint
        default:
            throw ProfileError.address
        }
    }

    func xrayJSON(
        listenPort: UInt16, directRoute: DirectXrayRoute? = nil, listener: ProxyListener = .http
    ) throws -> Data {
        var configuredOutbound = outbound
        if kind == .xray {
            guard let directRoute,
                  var stream = outbound["streamSettings"] as? [String: Any],
                  var settings = outbound["settings"] as? [String: Any],
                  var servers = settings["vnext"] as? [[String: Any]], !servers.isEmpty
            else { throw ProfileError.address }
            stream["sockopt"] = ["interface": directRoute.interface]
            servers[0]["address"] = directRoute.address
            settings["vnext"] = servers
            configuredOutbound["streamSettings"] = stream
            configuredOutbound["settings"] = settings
        }
        let config: [String: Any] = [
            "log": ["loglevel": "none"],
            "inbounds": [["listen": "127.0.0.1", "port": Int(listenPort), "protocol": listener.xrayProtocol]],
            "outbounds": [configuredOutbound]
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    private static func vlessOutbound(_ url: URLComponents) throws -> ([String: Any], String, XrayEndpoint) {
        guard let id = url.user.flatMap(UUID.init(uuidString:)),
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty,
              let port = url.port.flatMap(UInt16.init(exactly:)), port > 0,
              url.password == nil, url.path.isEmpty || url.path == "/"
        else { throw ProfileError.key }

        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard query[item.name] == nil else { throw ProfileError.key }
            query[item.name] = item.value ?? ""
        }
        for name in ["allowInsecure", "insecure"] {
            guard ["0", "false", ""].contains(query[name]?.lowercased() ?? "") else {
                throw ProfileError.insecureTLS
            }
        }
        let network = query["type"]?.lowercased() ?? "tcp"
        let security = query["security"]?.lowercased() ?? ""
        let flow = query["flow"] ?? ""
        let isGRPC = network == "grpc"
        guard isGRPC || network == "tcp" || network == "raw",
              security == "tls" || (!isGRPC && security == "reality"),
              ["", "none"].contains(query["headerType"] ?? ""),
              (query["encryption"] ?? "none") == "none",
              flow.isEmpty || (!isGRPC && flow == "xtls-rprx-vision")
        else { throw ProfileError.transport }

        var stream: [String: Any] = ["network": isGRPC ? "grpc" : "raw", "security": security]
        let serverName = query["sni"] ?? host
        let fingerprint = query["fp"] ?? "chrome"
        if security == "reality" {
            let key = query["pbk"] ?? ""
            let shortID = query["sid"] ?? ""
            guard validRealityKey(key), !serverName.isEmpty, !fingerprint.isEmpty,
                  shortID.count <= 16, shortID.count.isMultiple(of: 2),
                  shortID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { throw ProfileError.reality }
            var settings = [
                "serverName": serverName, "fingerprint": fingerprint,
                "password": key, "shortId": shortID, "spiderX": query["spx"] ?? ""
            ]
            if let verify = query["pqv"], !verify.isEmpty {
                settings["mldsa65Verify"] = verify
            }
            stream["realitySettings"] = settings
        } else {
            var settings: [String: Any] = ["serverName": serverName.isEmpty ? host : serverName]
            if !fingerprint.isEmpty { settings["fingerprint"] = fingerprint }
            if let alpn = query["alpn"], !alpn.isEmpty {
                settings["alpn"] = alpn.split(separator: ",").map(String.init)
            } else if isGRPC {
                settings["alpn"] = ["h2"]
            }
            stream["tlsSettings"] = settings
        }
        if isGRPC {
            let mode = query["mode"] ?? "gun"
            guard ["", "gun", "multi"].contains(mode) else { throw ProfileError.transport }
            var settings: [String: Any] = [
                "serviceName": query["serviceName"] ?? "",
                "multiMode": mode == "multi"
            ]
            if let authority = query["authority"], !authority.isEmpty {
                settings["authority"] = authority
            }
            stream["grpcSettings"] = settings
        }
        var user = ["id": id.uuidString.lowercased(), "encryption": "none"]
        if !flow.isEmpty { user["flow"] = flow }
        let outbound: [String: Any] = [
            "protocol": "vless", "streamSettings": stream,
            "settings": ["vnext": [["address": host, "port": Int(port), "users": [user]]]]
        ]
        let transport = isGRPC ? "gRPC" : "TCP"
        return (outbound, "Xray · \(transport)/\(security.uppercased())", XrayEndpoint(host: host, port: port))
    }

    private static func validRealityKey(_ key: String) -> Bool {
        guard key.utf8.count == 43 else { return false }
        let base64 = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + "=")?.count == 32
    }
}

struct CodexLaunchOptions {
    let environment: [String: String]
    let arguments: [String]

    init(proxyPort: UInt16?) {
        guard let proxyPort else {
            environment = [:]
            arguments = []
            return
        }
        let proxy = "http://127.0.0.1:\(proxyPort)"
        let directHosts = ["localhost", "127.0.0.1"]
        let noProxy = (directHosts + ["::1", ".localhost", ".local", ".internal"]).joined(separator: ",")
        let bypass = (directHosts + ["[::1]", "*.localhost", "*.local", "*.internal"]).joined(separator: ";")
        environment = [
            "HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "ALL_PROXY": proxy,
            "http_proxy": proxy, "https_proxy": proxy, "all_proxy": proxy,
            "NO_PROXY": noProxy, "no_proxy": noProxy,
            "NODE_USE_ENV_PROXY": "1",
            "CODEX_APP_SERVER_FORCE_CLI": "1"
        ]
        arguments = ["--proxy-server=\(proxy)", "--proxy-bypass-list=\(bypass)", "--disable-quic"]
    }
}
