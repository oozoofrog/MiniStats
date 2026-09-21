import SwiftUI

extension DashboardView {
    var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.order = .cpu; model.page = .processes } label: {
                RetroProcessorPanel(model: model)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Processor, view top processes")

            HStack(alignment: .top, spacing: 0) {
                Button { model.order = .memory; model.page = .processes } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        RetroSectionHeading(title: "02 / MEMORY", detail: "↗")
                        Text(model.memory.map { bytes($0.used) } ?? "—").font(.bitmap(22))
                        UsageBar(percent: model.memory?.percent ?? 0, color: ink)
                        Text(model.memory.map { String(format: "%.0f%% of %@", $0.percent, bytes(totalMemory)) } ?? "Measuring…")
                            .font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Memory, view top processes")
                Rectangle().fill(palette.line).frame(width: 1)
                Button { model.page = .network } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        RetroSectionHeading(title: "03 / NETWORK", detail: "↗")
                        Text("↓ " + model.download).font(.bitmap(20))
                        Text("↑ " + model.upload).font(.bitmap(12))
                        Text("Physical interfaces").font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(Rectangle().strokeBorder(palette.line, lineWidth: 1))

            HStack(alignment: .top, spacing: 24) {
                topProcesses(order: .cpu)
                topProcesses(order: .memory)
            }

            RetroRule()
            Button { model.page = .storage } label: {
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(storage?.disk?.name ?? "Storage")
                        Text(storage?.disk.map { "\(bytes($0.free)) free of \(bytes($0.total))" } ?? "Read failed")
                            .font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: 4)
                    Text("Storage ↗").font(.bitmap(11))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                Text(model.battery).font(.bitmap(11)).foregroundStyle(palette.muted)
                Spacer(minLength: 8)
                Button("Activity Monitor") { openActivityMonitor() }.font(.bitmap(11)).buttonStyle(.pixelGhost)
            }
        }
    }

    private func topProcesses(order: ProcessOrder) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            RetroSectionHeading(title: "TOP " + order.rawValue.uppercased())
            let rows = Array(order.sorted(model.processes).prefix(3))
            if rows.isEmpty {
                Text(model.sampled ? "No readable processes" : "Measuring…")
                    .foregroundStyle(palette.muted)
            }
            ForEach(rows) { process in
                HStack(spacing: 5) {
                    Text(process.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(processValue(process, order: order)).foregroundStyle(palette.muted).fixedSize()
                }
            }
        }
        .font(.bitmap(11))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var networkDetails: some View {
        VStack(alignment: .leading, spacing: 22) {
            transferPanel("DOWNLOAD", value: model.download, icon: "arrow.down")
            transferPanel("UPLOAD", value: model.upload, icon: "arrow.up")
            RetroRule()
            Text("Rates are sampled every 3 seconds across active physical network interfaces.")
            Text("VPN and bridge traffic is excluded to avoid counting the same transfer twice.")
                .foregroundStyle(palette.muted)
        }
        .font(.bitmap(12))
    }

    private func transferPanel(_ title: String, value: String, icon: String) -> some View {
        LCDScreen {
            VStack(alignment: .leading, spacing: 20) {
                RetroSectionHeading(title: title, detail: "TRANSFER RATE")
                HStack(spacing: 16) {
                    Image(systemName: icon).font(.system(size: 24)).accessibilityHidden(true)
                    Text(value).font(.bitmap(32))
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct RetroProcessorPanel: View {
    @ObservedObject var model: DashboardModel
    var compact = false
    @Environment(\.retroPalette) private var palette

    var body: some View {
        LCDScreen {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                RetroSectionHeading(title: compact ? "PROCESSOR" : "01 / PROCESSOR", detail: "CPU LOAD")
                HStack(alignment: .bottom, spacing: 8) {
                    Text(model.cpu.map { String(format: "%.0f", $0.total) } ?? "—")
                        .font(.bitmap(compact ? 40 : 48))
                    Text("%").font(.bitmap(18)).padding(.bottom, 4)
                    Spacer(minLength: 0)
                    if !compact {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text("\(ProcessInfo.processInfo.activeProcessorCount)-core CPU")
                            Text(model.cpu.map { String(format: "%.0f%% idle", max(0, 100 - $0.total)) } ?? "Measuring…")
                        }
                        .font(.bitmap(11)).foregroundStyle(palette.muted).padding(.bottom, 4)
                    }
                }
                HistoryLine(values: model.cpuHistory, color: palette.phosphor, height: compact ? 30 : 46)
                if !compact { RetroSectionHeading(title: "RECENT SAMPLES", detail: "NOW") }
            }
        }
    }
}
