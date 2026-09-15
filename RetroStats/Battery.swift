import IOKit.ps

func batteryText() -> String {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "배터리: 읽기 실패" }
    for source in sources {
        guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let capacity = values[kIOPSCurrentCapacityKey] as? Int,
              let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        let pluggedIn = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = values[kIOPSIsChargingKey] as? Bool == true
        return "배터리: \(capacity * 100 / maximum)% · \(charging ? "충전 중" : pluggedIn ? "전원 연결" : "배터리 사용")"
    }
    return "배터리: 없음"
}
