//
//  NetworkInterface.swift
//  Beaver
//

import Foundation

/// Local-IP discovery for the "Copy WebSocket URL" menu command.
///
/// Returns the best human-shareable address: IPv4 wifi → IPv4 wired →
/// IPv6 fallback. Returns nil if the machine has no usable interface
/// (offline).
public enum NetworkInterface {

    public static func bestAddress() -> String? {
        let interfaces = listInterfaces()
        let preference: [(name: String, family: Int32)] = [
            ("en0", AF_INET),  // wifi or primary ethernet
            ("en1", AF_INET),
            ("en2", AF_INET),
            ("en0", AF_INET6),
        ]
        for (name, family) in preference {
            if let addr = interfaces.first(where: {
                $0.name == name && $0.family == family
            }) {
                return addr.address
            }
        }
        // First non-loopback IPv4 as a last resort.
        return interfaces.first(where: {
            $0.family == AF_INET && $0.address != "127.0.0.1"
        })?.address
    }

    // MARK: - Internal

    private struct Interface {
        let name: String
        let family: Int32
        let address: String
    }

    private static func listInterfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            guard let sa = interface.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: interface.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                socklen_t(0),
                NI_NUMERICHOST
            )
            guard r == 0 else { continue }
            let address = String(cString: hostname)
            result.append(Interface(name: name, family: family, address: address))
        }
        return result
    }
}
