import AppKit
import SwiftUI

extension DashboardContentView {
    var displayedVolumes: [StorageVolume] { storage?.volumes ?? [] }
    var selectedVolume: StorageVolume? {
        if let id = model.selectedStorageVolumeID { return displayedVolumes.first { $0.id == id } }
        return displayedVolumes.first { $0.isMain } ?? displayedVolumes.first
    }

    var volumeCatalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(displayedVolumes.count) mounted volumes").font(.bitmap(12))
                Spacer(minLength: 6)
                Button(storage?.refreshingVolumes == true ? "Refreshing…" : "Refresh") { storage?.refreshVolumes() }
                    .font(.bitmap(11)).buttonStyle(.pixelGhost).disabled(storage == nil || storage?.refreshingVolumes == true)
            }
            if displayedVolumes.isEmpty {
                Text(storage?.refreshingVolumes == true ? "Reading mounted volumes…" : "No volume capacities available. Refresh to try again.")
                    .font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            ForEach(StorageVolume.Location.allCases, id: \.self) { location in
                let group = displayedVolumes.filter { $0.location == location }
                if !group.isEmpty {
                    Text(location.rawValue.uppercased()).font(.bitmap(10)).foregroundStyle(palette.muted).padding(.top, 4)
                    ForEach(group) { volume in
                        Button {
                            model.selectedStorageVolumeID = volume.id
                            explorer.reset()
                        } label: {
                            StorageVolumeRow(volume: volume, showsPath: true)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selectedVolume?.id == volume.id ? palette.soft : palette.paper)
                        .overlay(Rectangle().strokeBorder(selectedVolume?.id == volume.id ? ink : palette.line, lineWidth: selectedVolume?.id == volume.id ? 2 : 1))
                        .accessibilityAddTraits(selectedVolume?.id == volume.id ? .isSelected : [])
                        .accessibilityHint("Show volume details")
                    }
                }
            }
            if let date = storage?.volumesMeasuredAt {
                Text("Measured \(englishDateTime(date))").font(.bitmap(10)).foregroundStyle(palette.muted)
            }
        }
    }

    @ViewBuilder var selectedVolumeDetails: some View {
        if let volume = selectedVolume {
            if let capacity = volume.capacity {
                LCDScreen {
                    VStack(alignment: .leading, spacing: 14) {
                        RetroSectionHeading(title: volume.name.uppercased(), detail: bytes(capacity.total))
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                LCDValue(text: bytes(capacity.free)).font(.bitmap(32))
                                Text("free").font(.bitmap(12))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                LCDValue(text: bytes(capacity.free)).font(.bitmap(26))
                                Text("free").font(.bitmap(12))
                            }
                        }
                        RetroDiskMap(percent: capacity.usedPercent)
                        RetroSectionHeading(title: String(format: "%.1f%% USED", capacity.usedPercent), detail: "FREE SPACE")
                    }
                }
                if let estimate = capacity.purgeable {
                    Text("Purgeable estimate: \(bytes(estimate)) · not guaranteed free space")
                        .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                let peers = StorageVolumeCatalog.sharedNames(for: volume, in: displayedVolumes)
                if volume.sharedContainerID != nil {
                    Text(peers.isEmpty ? "APFS container space may be shared with hidden volumes. Do not add volume capacities."
                         : "Shares APFS container space with \(peers.joined(separator: ", ")). Do not add these capacities.")
                        .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                if volume.isMain, storage?.disk?.warning == true {
                    attentionText("Main disk storage is at or above the 50% alert threshold.")
                }
            } else {
                attentionText("\(volume.name): capacity unavailable. Check the connection or file access, then refresh.")
            }
            ViewThatFits(in: .horizontal) {
                HStack { volumeActions(volume) }
                VStack(alignment: .leading) { volumeActions(volume) }
            }
            if explorer.volumeID == volume.id { folderExplorer(volume) }
        } else if model.selectedStorageVolumeID != nil {
            attentionText("The selected volume is no longer mounted. Select another volume or reconnect it.")
        }
    }

    private func volumeActions(_ volume: StorageVolume) -> some View {
        Group {
            Button("Explore Space") { explorer.open(volume) }.buttonStyle(.pixel)
                .disabled(volume.capacity == nil || explorer.running || renderOnly)
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.path) }
                .buttonStyle(.pixelGhost).disabled(renderOnly)
        }.font(.bitmap(11))
    }

    var overviewVolumes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STORAGE").font(.bitmap(11))
                Spacer(minLength: 6)
                Button("All Volumes ↗") { model.page = .storage }.font(.bitmap(11)).buttonStyle(.pixelGhost)
            }
            if displayedVolumes.isEmpty {
                Text(storage?.refreshingVolumes == true ? "Reading mounted volumes…" : "Capacity unavailable")
                    .font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            ForEach(displayedVolumes) { volume in
                Button {
                    model.selectedStorageVolumeID = volume.id
                    model.page = .storage
                } label: {
                    StorageVolumeRow(volume: volume).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Open this volume in Storage")
                if volume.id != displayedVolumes.last?.id { RetroRule() }
            }
        }.padding(16).overlay(Rectangle().strokeBorder(palette.line, lineWidth: 1))
    }
}
