import AppKit
import SwiftUI

extension DashboardContentView {
    func processDetails(order: ProcessOrder) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LCDScreen {
                VStack(alignment: .leading, spacing: 14) {
                    RetroSectionHeading(title: order == .cpu ? "CPU LOAD" : "MEMORY USED", detail: "RECENT SAMPLES")
                    HStack(alignment: .firstTextBaseline) {
                        Text(order == .cpu ? (model.cpu.map { String(format: "%.0f%%", $0.total) } ?? "—") : model.memory.map { bytes($0.used) } ?? "—")
                            .font(.bitmap(32))
                        Text(order == .cpu ? "All cores" : "/ \(bytes(totalMemory))").font(.bitmap(12)).foregroundStyle(palette.muted)
                    }
                    HistoryLine(values: order == .cpu ? model.cpuHistory : model.memoryHistory, color: palette.phosphor)
                }
            }
            if order == .cpu {
                Text(model.cpu.map { String(format: "User %.1f%% · System %.1f%%", $0.user, $0.system) } ?? "Measuring…").font(.bitmap(11)).foregroundStyle(palette.muted)
                Text(model.load).font(.bitmap(11)).foregroundStyle(palette.muted)
            } else {
                if let memory = model.memory {
                    Text("App \(bytes(memory.app)) · Wired \(bytes(memory.wired)) · Compressed \(bytes(memory.compressed))").font(.bitmap(11)).foregroundStyle(palette.muted)
                }
                Text(model.pressure + "\n" + model.swap).font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            HStack {
                Text("Top 5").font(.bitmap(12))
                Spacer()
                Text(order == .cpu ? "CPU %" : "Memory").font(.bitmap(11)).foregroundStyle(palette.muted)
            }.padding(.top, 4)
            let rows = Array(order.sorted(model.processes).prefix(5))
            if rows.isEmpty { Text(model.sampled && model.processes.isEmpty ? "No process information is available." : (order == .cpu ? "Measuring CPU usage…" : "Measuring memory usage…")).font(.bitmap(11)).foregroundStyle(palette.muted).padding(.vertical, 20) }
            ForEach(rows) { process in
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed").foregroundStyle(palette.muted).font(.system(size: 19)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).font(.bitmap(12)).lineLimit(1)
                        Text("PID \(String(process.pid))").font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    Spacer()
                    Text(processValue(process, order: order)).font(.bitmap(12))
                }.padding(.vertical, 7)
                RetroRule()
            }
            Text(order == .cpu ? "Only processes accessible to RetroStats are shown. Process CPU 100% represents one core; using multiple cores can exceed 100%." : "Only processes accessible to RetroStats are shown. Memory uses the same basis as the Memory column in Activity Monitor.")
                .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            Button("Open Activity Monitor") { openActivityMonitor() }.buttonStyle(.pixelGhost).controlSize(.small)
        }
    }
}
