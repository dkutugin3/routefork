import Foundation

@main
struct ProfileChecks {
    static let uuid = "11111111-1111-4111-8111-111111111111"
    static let grpc = "vless://\(uuid)@vpn.example:60443?encryption=none&security=tls&sni=edge.example&fp=chrome&type=grpc&serviceName=CloudService&mode=gun#Mac"
    static let key = Data(repeating: 51, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    static let reality = "vless://\(uuid)@vpn.example:443?encryption=none&security=reality&sni=edge.example&fp=chrome&pbk=\(key)&sid=aabb&type=tcp&flow=xtls-rprx-vision#Mac"

    static func main() throws {
        let fixtures = try [grpc, reality, "http://127.0.0.1:20001", "socks5://localhost:20002"]
            .map { try ProxyProfile($0) }
        let route = DirectXrayRoute(interface: "en0", label: "Wi-Fi (en0)", address: "192.0.2.31")
        var configurations = try fixtures.map {
            try $0.xrayJSON(listenPort: 23456, directRoute: $0.kind == .xray ? route : nil)
        }
        precondition((try? fixtures[0].xrayJSON(listenPort: 23456)) == nil, "VLESS must require a physical route")
        let dictionaries = try configurations.map {
            try JSONSerialization.jsonObject(with: $0) as! [String: Any]
        }
        let outbounds = dictionaries.map { dictionary in
            let inbounds = dictionary["inbounds"] as! [[String: Any]]
            precondition(inbounds.count == 1 && inbounds[0]["listen"] as? String == "127.0.0.1")
            precondition(inbounds[0]["protocol"] as? String == "http" && inbounds[0]["port"] as? Int == 23456)
            let outbounds = dictionary["outbounds"] as! [[String: Any]]
            precondition(outbounds.count == 1)
            return outbounds[0]
        }
        let grpcStream = outbounds[0]["streamSettings"] as! [String: Any]
        let tls = grpcStream["tlsSettings"] as! [String: Any]
        precondition(tls["serverName"] as? String == "edge.example")
        precondition(grpcStream["sockopt"] as? [String: String] == ["interface": "en0"])
        let grpcDestinations = (outbounds[0]["settings"] as! [String: Any])["vnext"] as! [[String: Any]]
        precondition(grpcDestinations[0]["address"] as? String == "192.0.2.31")
        precondition(tls["allowInsecure"] == nil && tls["alpn"] as? [String] == ["h2"])
        let grpcSettings = grpcStream["grpcSettings"] as! [String: Any]
        precondition(grpcSettings["serviceName"] as? String == "CloudService")
        precondition(grpcSettings["multiMode"] as? Bool == false)
        let realityStream = outbounds[1]["streamSettings"] as! [String: Any]
        let realitySettings = realityStream["realitySettings"] as! [String: Any]
        precondition(realitySettings["password"] as? String == key)
        precondition(realitySettings["shortId"] as? String == "aabb")
        precondition(realitySettings["serverName"] as? String == "edge.example")
        precondition(realityStream["sockopt"] as? [String: String] == ["interface": "en0"])
        precondition(outbounds[2]["protocol"] as? String == "http")
        precondition(outbounds[3]["protocol"] as? String == "socks")
        precondition(outbounds[2]["streamSettings"] == nil && outbounds[3]["streamSettings"] == nil)
        precondition(fixtures[3].upstreamPort == 20002)
        let telegram = try fixtures[0].xrayJSON(listenPort: 23457, directRoute: route, listener: .socks5)
        let telegramConfig = try JSONSerialization.jsonObject(with: telegram) as! [String: Any]
        let telegramInbounds = telegramConfig["inbounds"] as! [[String: Any]]
        precondition(telegramInbounds.count == 1 && telegramInbounds[0]["listen"] as? String == "127.0.0.1")
        precondition(telegramInbounds[0]["protocol"] as? String == "socks"
                     && telegramInbounds[0]["port"] as? Int == 23457)
        let telegramOutbounds = telegramConfig["outbounds"] as! [[String: Any]]
        precondition(NSDictionary(dictionary: telegramOutbounds[0]).isEqual(to: outbounds[0]))
        configurations.append(telegram)

        for invalid in [
            "http://other.example:20001", "http://user:pass@127.0.0.1:20001",
            "http://127.0.0.1:0", "http://127.0.0.1:70000", "socks5://127.0.0.1:1/other",
            "vpn://sample", grpc + "\nvless://another.example", grpc.replacingOccurrences(of: "#Mac", with: "&allowInsecure=1"),
            grpc.replacingOccurrences(of: "type=grpc", with: "type=kcp"),
            grpc.replacingOccurrences(of: "type=grpc", with: "type=grpc&type=tcp"),
            reality.replacingOccurrences(of: "sid=aabb", with: "sid=z"),
            reality.replacingOccurrences(of: "pbk=\(key)", with: "pbk=invalid")
        ] {
            precondition((try? ProxyProfile(invalid)) == nil, "Accepted an invalid profile")
        }

        let direct = CodexLaunchOptions(proxyPort: nil)
        precondition(direct.environment.isEmpty && direct.arguments.isEmpty)
        let proxied = CodexLaunchOptions(proxyPort: 23456)
        let expectedProxy = "http://127.0.0.1:23456"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            precondition(proxied.environment[key] == expectedProxy)
        }
        precondition(proxied.environment["NO_PROXY"] == "localhost,127.0.0.1,::1,.localhost,.local,.internal")
        precondition(proxied.environment["NO_PROXY"] == proxied.environment["no_proxy"])
        precondition(proxied.environment["CODEX_APP_SERVER_FORCE_CLI"] == "1")
        precondition(proxied.arguments.contains("--proxy-server=\(expectedProxy)") && !proxied.arguments.contains("--no-proxy-server"))

        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, configuration) in configurations.enumerated() {
                try configuration.write(to: directory.appendingPathComponent("test-\(index).json"))
            }
        }
        print("Profile and launch checks passed")
    }
}
