import Foundation

struct Traffic {
    let received: UInt64
    let sent: UInt64
}

func networkCounters() -> [String: Traffic]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
    guard read == 0 else { return nil }
    data.count = size
    return parseNetwork(data)
}

func parseNetwork(_ data: Data) -> [String: Traffic]? {
    var result: [String: Traffic] = [:]
    return data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            guard raw.count - offset >= 4 else { return nil }
            let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length >= 4, length <= raw.count - offset else { return nil }
            defer { offset += length }
            guard raw[offset + 3] == RTM_IFINFO2 else { continue }
            guard length >= MemoryLayout<if_msghdr2>.size else { return nil }
            let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            guard info.ifm_flags & IFF_UP != 0 else { continue }
            var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil else { continue }
            let name = String(cString: nameBuffer)
            // ponytail: physical en* interfaces avoid counting VPN/bridge traffic twice; add other hardware prefixes if needed.
            guard name.hasPrefix("en") else { continue }
            result[name] = Traffic(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
        }
        return result
    }
}

func networkRate(_ before: [String: Traffic], _ after: [String: Traffic], seconds: Double) -> (Double, Double)? {
    guard seconds > 0, seconds.isFinite else { return nil }
    var received = 0.0
    var sent = 0.0
    for (name, current) in after {
        guard let old = before[name], current.received >= old.received, current.sent >= old.sent else { continue }
        received += Double(current.received - old.received) / seconds
        sent += Double(current.sent - old.sent) / seconds
    }
    return (received, sent)
}
