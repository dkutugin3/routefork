import Darwin
import Foundation
import SystemConfiguration

enum DirectEgressError: LocalizedError {
    case noInterface
    case dns
    case unreachable(String, [String])

    var errorDescription: String? {
        switch self {
        case .noInterface:
            return "Подключись к Wi‑Fi или Ethernet. Для Xray нужен прямой сетевой интерфейс."
        case .dns:
            return "Не удалось получить IP сервера Xray. Укажи его IP в VLESS-ссылке и сохрани исходный sni."
        case .unreachable(let interface, let addresses):
            return "Сервер Xray недоступен через \(interface). Если активный VPN перехватывает маршрут, добавь IP сервера Xray в исключения VPN.\n\n\(addresses.joined(separator: ", "))"
        }
    }
}

enum DirectEgress {
    struct Interface {
        let name: String
        let label: String
        let families: Set<Int32>
    }

    static func verify(
        _ endpoint: XrayEndpoint, interfaces: [Interface] = activeInterfaces(),
        fallbackAddresses: [String: String] = [:]
    ) throws -> DirectXrayRoute {
        do {
            return try connect(to: endpoint, through: interfaces)
        } catch DirectEgressError.unreachable(let interface, let addresses) {
            guard let alternate = addresses.lazy.compactMap({ fallbackAddresses[$0] }).first,
                  !addresses.contains(alternate)
            else { throw DirectEgressError.unreachable(interface, addresses) }
            do {
                return try connect(to: XrayEndpoint(host: alternate, port: endpoint.port), through: interfaces)
            } catch DirectEgressError.unreachable(let interface, let tried) {
                throw DirectEgressError.unreachable(interface, addresses + tried.filter { !addresses.contains($0) })
            }
        }
    }

    private static func connect(to endpoint: XrayEndpoint, through interfaces: [Interface]) throws -> DirectXrayRoute {
        guard let preferred = interfaces.first else { throw DirectEgressError.noInterface }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_NUMERICSERV
        var result: UnsafeMutablePointer<addrinfo>?
        // Resolve only the Xray server. Xray receives a numeric address and keeps the link's TLS hostname.
        guard getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result) == 0, let result else {
            throw DirectEgressError.dns
        }
        defer { freeaddrinfo(result) }
        var addresses: [(addrinfo, String)] = []
        var entry: UnsafeMutablePointer<addrinfo>? = result
        while let current = entry {
            let address = current.pointee
            entry = address.ai_next
            guard address.ai_family == AF_INET || address.ai_family == AF_INET6,
                  let host = numericAddress(address), !addresses.contains(where: { $0.1 == host })
            else { continue }
            addresses.append((address, host))
        }
        guard !addresses.isEmpty else { throw DirectEgressError.dns }

        let deadline = ContinuousClock.now + .seconds(7)
        for interface in interfaces {
            let index = if_nametoindex(interface.name)
            guard index != 0 else { continue }
            for (address, host) in addresses where interface.families.contains(address.ai_family) {
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let milliseconds = remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000
                guard milliseconds > 0 else { break }
                if reachable(address, interfaceIndex: index, timeout: Int32(min(milliseconds, 2000))) {
                    return DirectXrayRoute(interface: interface.name, label: interface.label, address: host)
                }
            }
        }
        throw DirectEgressError.unreachable(preferred.label, addresses.map(\.1))
    }

    static func activeInterfaces() -> [Interface] {
        let client = "RouteFork" as CFString
        guard let preferences = SCPreferencesCreate(nil, client, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService],
              let store = SCDynamicStoreCreate(nil, client, nil, nil)
        else { return [] }
        let order = SCNetworkSetGetServiceOrder(set) as? [String] ?? []
        let physicalTypes = [kSCNetworkInterfaceTypeIEEE80211 as String: "Wi‑Fi",
                             kSCNetworkInterfaceTypeEthernet as String: "Ethernet"]
        var interfaces: [(position: Int, interface: Interface)] = []
        for service in services where SCNetworkServiceGetEnabled(service) {
            guard let device = SCNetworkServiceGetInterface(service),
                  let name = SCNetworkInterfaceGetBSDName(device) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(device) as String?,
                  let typeLabel = physicalTypes[type],
                  let id = SCNetworkServiceGetServiceID(service) as String?
            else { continue }
            let families = [("IPv4", AF_INET), ("IPv6", AF_INET6)].compactMap { entity, family -> Int32? in
                let key = "State:/Network/Service/\(id)/\(entity)" as CFString
                let state = SCDynamicStoreCopyValue(store, key) as? [String: Any]
                return state?["Router"] is String ? family : nil
            }
            guard !families.isEmpty else { continue }
            interfaces.append((order.firstIndex(of: id) ?? order.count,
                               Interface(name: name, label: "\(typeLabel) (\(name))", families: Set(families))))
        }
        return interfaces.sorted { $0.position < $1.position }.map(\.interface)
    }

    private static func numericAddress(_ address: addrinfo) -> String? {
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address.ai_addr, address.ai_addrlen, &text, socklen_t(text.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: text)
    }

    private static func reachable(_ address: addrinfo, interfaceIndex: UInt32, timeout: Int32) -> Bool {
        let fd = socket(address.ai_family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var index = interfaceIndex
        let level = address.ai_family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6
        let option = address.ai_family == AF_INET ? IP_BOUND_IF : IPV6_BOUND_IF
        let length = socklen_t(MemoryLayout<UInt32>.size)
        guard setsockopt(fd, level, option, &index, length) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0
        else { return false }
        if Darwin.connect(fd, address.ai_addr, address.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pending, 1, timeout) == 1 else { return false }
        var status: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &size) == 0 && status == 0
    }
}
