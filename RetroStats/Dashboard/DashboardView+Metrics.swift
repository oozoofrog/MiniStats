import SwiftUI

extension DashboardContentView {
    var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { model.page = .cpu } label: {
                RetroProcessorPanel(model: model, compact: compact)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Processor, view top processes")

            let summaryLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            summaryLayout {
                memorySummary
                if compact { RetroRule() }
                else { Rectangle().fill(palette.line).frame(width: 1) }
                networkSummary
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(Rectangle().strokeBorder(palette.line, lineWidth: 1))

            if compact {
                DisclosureGroup("Top Processes", isExpanded: $showsProcesses) {
                    VStack(alignment: .leading, spacing: 18) {
                        topProcesses(order: .cpu)
                        topProcesses(order: .memory)
                    }.padding(.top, 12)
                }.font(.bitmap(11))
            } else {
                HStack(alignment: .top, spacing: 24) {
                    topProcesses(order: .cpu)
                    topProcesses(order: .memory)
                }
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
                    if !compact { Text("Storage ↗").font(.bitmap(11)) }
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

    private var memorySummary: some View {
        Button { model.page = .memory } label: {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if compact {
                    HStack {
                        Text("MEMORY").font(.bitmap(11))
                        Spacer(minLength: 8)
                        Text(model.memory.map { bytes($0.used) } ?? "—").font(.bitmap(16))
                    }
                } else {
                    RetroSectionHeading(title: "MEMORY", detail: "↗")
                    Text(model.memory.map { bytes($0.used) } ?? "—").font(.bitmap(22))
                    UsageBar(percent: model.memory?.percent ?? 0, color: ink)
                }
                Text(model.memory.map { String(format: "%.0f%% of %@", $0.percent, bytes(totalMemory)) } ?? "Measuring…")
                    .font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 12 : 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Memory, view top processes")
    }

    private var networkSummary: some View {
        Button { model.page = .network } label: {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if compact {
                    HStack {
                        Text("NETWORK").font(.bitmap(11))
                        Spacer(minLength: 8)
                        Text("↓ " + model.download).font(.bitmap(14))
                    }
                } else {
                    RetroSectionHeading(title: "NETWORK", detail: "↗")
                    Text("↓ " + model.download).font(.bitmap(20))
                }
                Text("↑ " + model.upload).font(.bitmap(12))
                if !compact { Text("Physical interfaces").font(.bitmap(11)).foregroundStyle(palette.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 12 : 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
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
                    Text(value).font(.bitmap(compact ? 24 : 32))
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
                RetroSectionHeading(title: "PROCESSOR", detail: "CPU LOAD")
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
