import IOKit.ps

func batteryText() -> String {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "Battery: read failed" }
    for source in sources {
        guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let capacity = values[kIOPSCurrentCapacityKey] as? Int,
              let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
        let pluggedIn = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = values[kIOPSIsChargingKey] as? Bool == true
        return "Battery: \(capacity * 100 / maximum)% · \(charging ? "Charging" : pluggedIn ? "Plugged in" : "On battery")"
    }
    return "Battery: none"
}
