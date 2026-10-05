//
//  NetworkInterface.swift
//  Beaver
//

import Foundation
import SystemConfiguration

/// The addresses a device on the same network can reach this Mac at: for
/// Copy IP, Copy WebSocket Address, the Scheme Generator, the empty-state
/// placeholder and `beaver_status`.
public enum NetworkInterface {

    public struct Interface: Sendable, Equatable {
        public let name: String
        public let family: Int32
        public let address: String
        /// Up, running and not loopback.
        public let isUp: Bool

        public init(name: String, family: Int32, address: String, isUp: Bool = true) {
            self.name = name; self.family = family; self.address = address; self.isUp = isUp
        }
    }

    /// What Copy IP says instead of copying a ws://localhost a phone can't use.
    public static let noAddressMessage = "This Mac has no network address a device can reach. Connect it to the device's Wi-Fi."

    /// The best address, or nil when this Mac is on no network a device can use.
    public static func bestAddress() -> String? { usableAddresses().first }

    /// `ws://<address>:<port>` for every usable address, best first.
    public static func deviceURLs(port: Int = 9080) -> [String] {
        usableAddresses().map { "ws://\($0):\(port)" }
    }

    /// IPv4 only: a phone types it, and an IPv6 address on a LAN is mostly
    /// link-local (`fe80::…%en0`), which no URL can carry. The interface with
    /// the default route comes first, then Ethernet/Wi-Fi (`en*`). Skipped:
    /// interfaces that are down, loopback, link-local 169.254.x (no DHCP),
    /// VPN tunnels (utun), bridges (VMs, Internet Sharing) and AirDrop's
    /// peer-to-peer links (awdl, llw).
    public static func usableAddresses(_ interfaces: [Interface] = listInterfaces(),
                                       primary: String? = primaryInterface()) -> [String] {
        let skipped = ["lo", "utun", "bridge", "awdl", "llw", "gif", "stf", "anpi", "ap"]
        let usable = interfaces.enumerated().filter { _, i in
            i.isUp && i.family == AF_INET
                && !i.address.hasPrefix("169.254.") && !i.address.hasPrefix("127.")
                && !skipped.contains { i.name.hasPrefix($0) }
        }
        func rank(_ i: Interface) -> Int { i.name == primary ? 0 : i.name.hasPrefix("en") ? 1 : 2 }
        return usable
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element.address)
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The interface macOS routes through by default (Wi-Fi or Ethernet).
    public static func primaryInterface() -> String? {
        let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return value?["PrimaryInterface"] as? String
    }

    public static func listInterfaces() -> [Interface] {
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
            let flags = Int32(interface.ifa_flags)
            let isUp = flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 && flags & IFF_LOOPBACK == 0

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
            // `getnameinfo` NUL-terminates into a fixed NI_MAXHOST
            // buffer, so the array is mostly trailing zeros. Cut at the
            // terminator before decoding — the deprecated
            // `String(cString: [CChar])` did that for us.
            let address = String(
                decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            result.append(Interface(name: name, family: family, address: address, isUp: isUp))
        }
        return result
    }
}
