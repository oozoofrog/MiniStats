import AppKit
import SwiftUI

extension DashboardContentView {
    @ViewBuilder func folderExplorer(_ volume: StorageVolume) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RetroRule()
            HStack {
                Text("SPACE EXPLORER").font(.bitmap(12))
                Spacer(minLength: 6)
                if explorer.canGoUp {
                    Button("Up") { explorer.goUp(volume) }.buttonStyle(.pixelGhost).disabled(explorer.running)
                }
                if explorer.running {
                    Button("Cancel") { explorer.cancel() }.buttonStyle(.pixel)
                } else {
                    Button("Rescan") { explorer.open(volume, path: explorer.path) }.buttonStyle(.pixelGhost)
                }
            }.font(.bitmap(11))
            if let path = explorer.path {
                Text(path).font(.bitmap(10)).foregroundStyle(palette.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if explorer.running {
                HStack {
                    PixelHourglass(size: 12, color: ink)
                    Text("Reading allocated file sizes…").font(.bitmap(11))
                }
                Text("Limited to 20 seconds or 200,000 entries. Cancellation waits for the current filesystem call.")
                    .font(.bitmap(10)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let error = explorer.error { attentionText("Could not inspect this folder: \(error)") }
            if let snapshot = explorer.result {
                Text("\(bytes(snapshot.measuredBytes)) allocated in measured files").font(.bitmap(13))
                if snapshot.cancelled || snapshot.limited || snapshot.excluded > 0 {
                    attentionText("\(snapshot.cancelled ? "Cancelled · " : "")Partial measurement · \(snapshot.inspected) inspected · \(snapshot.excluded) excluded or unreadable")
                }
                Text("File allocations can share APFS blocks. This is not unique disk usage or reclaimable space. Links and other mounted volumes are excluded.")
                    .font(.bitmap(10)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if snapshot.measuredBytes > 0 {
                    StorageFolderMap(entries: Array(snapshot.entries.prefix(8)), total: snapshot.measuredBytes) { entry in
                        inspect(entry, on: volume)
                    }.frame(height: 58)
                    Text("Map shows the largest measured entries. Unlabelled space contains the remaining measured entries.")
                        .font(.bitmap(10)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.entries.isEmpty {
                    Text(snapshot.cancelled || snapshot.limited || snapshot.excluded > 0 ? "No entries measured." : "No files or folders found.")
                        .font(.bitmap(11)).foregroundStyle(palette.muted)
                }
                ForEach(Array(snapshot.entries.prefix(explorerRowLimit))) { entry in
                    Button { inspect(entry, on: volume) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc").font(.system(size: 12)).accessibilityHidden(true)
                            Text(entry.name).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(bytes(entry.allocatedBytes)).fixedSize()
                            if entry.isDirectory { Text("›") }
                        }
                        .font(.bitmap(11)).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.path)
                    .accessibilityHint(entry.isDirectory ? "Inspect this folder" : "Reveal this file in Finder")
                    RetroRule()
                }
                if snapshot.entries.count > explorerRowLimit {
                    Button("Show more (\(snapshot.entries.count - explorerRowLimit) remaining)") { explorerRowLimit += 30 }
                        .font(.bitmap(11)).buttonStyle(.pixelGhost)
                }
                Text("Measured \(englishDateTime(snapshot.measuredAt))").font(.bitmap(10)).foregroundStyle(palette.muted)
            }
        }
    }

    private func inspect(_ entry: StorageFolderEntry, on volume: StorageVolume) {
        if entry.isDirectory { explorer.open(volume, path: entry.path) }
        else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
    }
}

private struct StorageFolderMap: View {
    let entries: [StorageFolderEntry]
    let total: UInt64
    let select: (StorageFolderEntry) -> Void
    @Environment(\.retroPalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let width = geometry.size.width * CGFloat(entry.allocatedBytes) / CGFloat(max(1, total))
                    Button { select(entry) } label: {
                        Rectangle().fill(palette.ink.opacity(index.isMultiple(of: 2) ? 0.8 : 0.45))
                            .overlay {
                                if width > 65 {
                                    Text(entry.name).font(.bitmap(10)).foregroundStyle(palette.paper)
                                        .lineLimit(2).padding(5)
                                }
                            }
                    }
                    .buttonStyle(.plain).frame(width: width)
                    .help("\(entry.name): \(bytes(entry.allocatedBytes)) allocated")
                    .accessibilityLabel("\(entry.name), \(bytes(entry.allocatedBytes)) allocated")
                }
                Spacer(minLength: 0)
            }.background(palette.soft)
        }
    }
}
