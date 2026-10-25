// NET_RT_IFLIST2 counter approach adapted from exelban/stats,
// Modules/Net/readers.swift, revision 7d3f70dcd6a07177d0a529a1b907021eef740158.
// Copyright (c) 2019 Serhiy Mytrovtsiy (MIT); see ThirdParty/Stats-LICENSE.txt.
import Foundation
import Darwin
import MoPanelCore

/// Called only by the existing serial native sampler. No sockets or requests.
final class NativeNetworkReader {
    private struct Counter { let index: UInt32; let rx: UInt64; let tx: UInt64; let time: Double }
    private var previous: [String: Counter] = [:]
    func reset() { previous = [:] }
    func read() -> [NetworkStatus] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var names = Set<String>(), addresses: [String: String] = [:], pointer = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let info = current.pointee, name = String(cString: info.ifa_name)
            guard names.count < 128, ["en", "bridge", "utun", "ppp", "ipsec", "tun", "tap"].contains(where: name.hasPrefix) else { continue }
            names.insert(name)
            guard Int32(info.ifa_flags) & IFF_UP != 0, let address = info.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if address.pointee.sa_family == UInt8(AF_INET) || (addresses[name] == nil && !value.hasPrefix("fe80:")) { addresses[name] = value }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        var next: [String: Counter] = [:], readings: [NetworkStatus] = []
        for name in names.sorted() {
            let index = if_nametoindex(name)
            guard index != 0, let counters = Self.counters(index) else { continue }
            next[name] = Counter(index: index, rx: counters.0, tx: counters.1, time: now)
            guard let old = previous[name], old.index == index,
                  let rate = NetworkCounterDelta.rates(previousRX: old.rx, previousTX: old.tx, currentRX: counters.0, currentTX: counters.1, elapsed: now - old.time) else { continue }
            // Supplement usable interfaces. Mole's own inactive entries remain
            // available separately, without adding every unconfigured tunnel.
            guard addresses[name] != nil else { continue }
            readings.append(NetworkStatus(name: name, rxRateMbs: rate.down, txRateMbs: rate.up, ip: addresses[name]))
        }
        previous = next
        return readings
    }
    private static func counters(_ index: UInt32) -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var count: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &count, nil, 0) == 0, count > 0, count <= 262_144 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let capacity = count
        guard sysctl(&mib, u_int(mib.count), &bytes, &count, nil, 0) == 0, count <= capacity else { return nil }
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= count {
            var header = if_msghdr()
            bytes.withUnsafeBytes { _ = memcpy(&header, $0.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr>.size) }
            let length = Int(header.ifm_msglen)
            guard length >= MemoryLayout<if_msghdr>.size, offset + length <= count else { return nil }
            if Int32(header.ifm_type) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                var value = if_msghdr2()
                bytes.withUnsafeBytes { _ = memcpy(&value, $0.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr2>.size) }
                if UInt32(value.ifm_index) == index { return (value.ifm_data.ifi_ibytes, value.ifm_data.ifi_obytes) }
            }
            offset += length
        }
        return nil
    }
}
