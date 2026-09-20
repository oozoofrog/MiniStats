import AppKit
import Darwin

let appID = "local.jay.RetroStats"
let totalMemory = ProcessInfo.processInfo.physicalMemory
let hostPort = mach_host_self()

let machTimebase: Double = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()

func diagnostic(_ message: String) {
    guard let index = CommandLine.arguments.firstIndex(of: "--diagnostics-output"), CommandLine.arguments.count > index + 1 else { return }
    let path = CommandLine.arguments[index + 1]
    let data = Data((message + "\n").utf8)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    if let handle = FileHandle(forWritingAtPath: path) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
}
