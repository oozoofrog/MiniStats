import AppKit
import SwiftUI

extension DashboardContentView {
    var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let disk = storage?.disk {
                LCDScreen {
                    VStack(alignment: .leading, spacing: 14) {
                        RetroSectionHeading(title: disk.name.uppercased(), detail: bytes(disk.total))
                        HStack(alignment: .firstTextBaseline) {
                            Text(bytes(disk.free)).font(.bitmap(32))
                            Text("free").font(.bitmap(12)).foregroundStyle(palette.muted)
                        }
                        RetroDiskMap(percent: disk.percent)
                        RetroSectionHeading(title: String(format: "%.1f%% USED", disk.percent), detail: "FREE SPACE")
                    }
                }
                if let detail = disk.detail { Text(detail).font(.bitmap(11)).foregroundStyle(palette.muted) }
                if disk.warning { attentionText("Storage is at or above the 50% alert threshold.") }
            } else {
                attentionText("Storage capacity could not be read.")
            }
            RetroRule()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DerivedData").font(.bitmap(14))
                    Text("Caches unused for more than 8 hours").font(.bitmap(11)).foregroundStyle(palette.muted)
                }
                Spacer()
                if storage?.busy == true && storage?.cleaning == true { PixelHourglass(size: 14, color: ink) }
                Button { storage?.refresh() } label: { PixelRefresh(size: 16, color: storage?.busy == true ? palette.muted : ink, animating: storage?.busy == true) }.buttonStyle(.pixel).disabled(storage?.busy == true).help("Check again").accessibilityLabel("Check DerivedData again")
            }
            if let progress = storage?.cleanProgress {
                cleanProgressSection(progress)
            } else {
                if storage?.busy == true { Text(storage?.cleaning == true ? "Cleaning selected caches…" : (storage?.scanPath.map { "Checking: \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Checking cache size…")).font(.bitmap(11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle) }
                if let error = storage?.lastError { attentionText(error) }
                if let report = storage?.report {
                    HStack {
                        Text("\(report.candidates.count) candidates · \(bytes(UInt64(report.candidateBytes)))")
                        Spacer()
                        Button(selection.count == candidatePaths.count && !selection.isEmpty ? "Deselect All" : "Select All") {
                            selection = selection.count == candidatePaths.count ? [] : Set(candidatePaths)
                        }.buttonStyle(.pixelGhost).disabled(storage?.busy == true || candidatePaths.isEmpty)
                    }.font(.bitmap(11))
                    if report.candidates.isEmpty { Text("No old caches need cleanup right now.").font(.bitmap(11)).foregroundStyle(palette.muted).padding(.vertical, 8) }
                    ForEach(report.candidates, id: \.path) { entry in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { selection.contains(entry.path) }, set: { if $0 { selection.insert(entry.path) } else { selection.remove(entry.path) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: entry.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.bitmap(11))
                                    Text(entry.workspace.isEmpty ? bytes(UInt64(entry.size)) : "\(entry.workspace) · \(bytes(UInt64(entry.size)))").font(.bitmap(11)).foregroundStyle(palette.muted)
                                }
                            }.toggleStyle(.pixelToggle).disabled(storage?.busy == true).help(entry.path)
                            Spacer(minLength: 0)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).help("Show in Finder").accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) Show in Finder")
                        }.padding(.vertical, 7)
                        RetroRule()
                    }
                    Text("\(report.items.count) total caches · \(bytes(UInt64(report.totalBytes)))").font(.bitmap(11)).foregroundStyle(palette.muted)
                    Text("Last checked \(englishDateTime(Date(timeIntervalSince1970: report.generatedAt)))")
                        .font(.bitmap(11)).foregroundStyle(palette.muted)
                }
            }
        }
    }
    @ViewBuilder
    func cleanProgressSection(_ progress: CleanProgress) -> some View {
        switch progress.phase {
        case .confirming: cleanConfirmCard(progress)
        case .running: cleanRunningSection(progress)
        case .done, .cancelled: cleanResultSection(progress)
        case .failed: cleanFailedSection(progress)
        }
    }
    func cleanConfirmCard(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permanently delete \(progress.totalCount) selected items totaling \(bytes(UInt64(progress.items.reduce(Int64(0)) { $0 + $1.size })))?").font(.bitmap(13))
            Text("Each item will be rechecked against the 8-hour threshold. Items in use are kept automatically.").font(.bitmap(11)).foregroundStyle(palette.muted)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(progress.items, id: \.path) { item in
                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.bitmap(11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Text("Quit Xcode and xcodebuild before cleanup, and do not start a new build while cleanup is running.").font(.bitmap(11)).foregroundStyle(palette.muted)
        }.padding(14).retroPanel()
    }
    func cleanRunningSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cleanup Progress").font(.bitmap(14))
                Spacer()
                PixelHourglass(size: 14, color: ink)
            }
            HStack {
                Text("\(progress.resolvedCount) / \(progress.totalCount) items").font(.bitmap(13))
                Spacer()
                Text("Freed \(bytes(UInt64(progress.freedBytes)))").font(.bitmap(12)).foregroundStyle(palette.muted)
            }
            UsageBar(percent: Double(progress.resolvedCount) / Double(max(progress.totalCount, 1)) * 100, color: ink)
            if let path = progress.currentPath {
                Text("Deleting: \(URL(fileURLWithPath: path).lastPathComponent)").font(.bitmap(11)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(progress.items, id: \.path) { item in
                    HStack(spacing: 8) {
                        cleanItemIcon(item.state)
                        Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1).truncationMode(.middle).font(.bitmap(11)).foregroundStyle(item.state == .pending || item.state == .kept ? palette.muted : ink)
                        Spacer(minLength: 0)
                        Text(bytes(UInt64(item.size))).font(.bitmap(11)).foregroundStyle(palette.muted)
                        Text(cleanItemTag(item.state)).font(.bitmap(11)).foregroundStyle(palette.muted)
                    }.padding(.vertical, 2)
                }
            }
        }
    }
    func cleanResultSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.phase == .cancelled ? "Cleanup Cancelled" : "Cleanup Complete").font(.bitmap(14))
                Spacer()
                Image(systemName: progress.phase == .cancelled ? "minus.circle" : "checkmark.circle").foregroundStyle(progress.phase == .cancelled ? palette.muted : ink)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(UInt64(progress.freedBytes))).font(.bitmap(26))
                Text("Space Freed").font(.bitmap(12)).foregroundStyle(palette.muted)
            }
            HStack(spacing: 16) {
                Text("Deleted \(progress.deletedCount)").font(.bitmap(11)).foregroundStyle(palette.muted)
                Text("Kept \(progress.keptCount)").font(.bitmap(11)).foregroundStyle(palette.muted)
                Text("Total \(progress.totalCount)").font(.bitmap(11)).foregroundStyle(palette.muted)
            }
            if progress.phase == .cancelled {
                Text("Cleanup was stopped. Only items processed before cancellation were applied.").font(.bitmap(11)).foregroundStyle(palette.muted)
            }
        }
    }
    func cleanFailedSection(_ progress: CleanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cleanup Failed").font(.bitmap(14))
                Spacer()
                DitherCell(color: ink).frame(width: 14, height: 14)
            }
            if let error = progress.error { attentionText(error) }
        }
    }
    @ViewBuilder
    func cleanItemIcon(_ state: CleanProgress.ItemState) -> some View {
        switch state {
        case .deleted: Image(systemName: "checkmark").foregroundStyle(ink).font(.system(size: 11))
        case .deleting: PixelHourglass(size: 11, color: ink)
        case .kept: Image(systemName: "minus").foregroundStyle(palette.muted).font(.system(size: 11))
        case .failed: DitherCell(color: ink).frame(width: 11, height: 11)
        case .pending: Image(systemName: "circle").foregroundStyle(palette.muted).font(.system(size: 11))
        }
    }
    func cleanItemTag(_ state: CleanProgress.ItemState) -> String {
        switch state {
        case .deleted: return "Deleted"
        case .deleting: return "Deleting"
        case .kept: return "Kept"
        case .failed: return "Failed"
        case .pending: return "Pending"
        }
    }
    var storageActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if storage?.cleanProgress?.phase == .confirming {
                Button { storage?.confirmCleanRun() } label: {
                    Text("Run Deletion").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Button { storage?.cancelClean() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                Text("Quit Xcode and xcodebuild before cleanup. Selected items are permanently deleted after confirmation.").font(.bitmap(11)).foregroundStyle(palette.muted)
            } else if storage?.cleanProgress?.phase == .running {
                Button { storage?.cancelClean() } label: {
                    Text("Cancel Cleanup").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
                Text("Do not start a new build while cleanup is running. Cancelling only applies items processed so far.").font(.bitmap(11)).foregroundStyle(palette.muted)
            } else if let phase = storage?.cleanProgress?.phase, phase == .done || phase == .cancelled || phase == .failed {
                Button { storage?.dismissCleanProgress(); storage?.refresh() } label: {
                    Text("Check Again").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary)
            } else {
                Toggle("Include Shared Caches", isOn: Binding(get: { storage?.includeShared == true }, set: { _ in selection = []; storage?.toggleShared() }))
                    .toggleStyle(.pixelToggle).font(.bitmap(11)).disabled(storage?.busy == true)
                Button { storage?.beginClean(paths: Set(selectedEntries.map(\.path))) } label: {
                    Text("Review \(selectedEntries.count) selected · \(bytes(UInt64(selectedEntries.reduce(Int64(0)) { $0 + $1.size })))").frame(maxWidth: .infinity)
                }.buttonStyle(.pixelPrimary).disabled(selectedEntries.isEmpty || storage?.busy == true || storage?.lastError != nil)
                Text("Quit Xcode and xcodebuild before cleanup. Selected items are permanently deleted after confirmation.").font(.bitmap(11)).foregroundStyle(palette.muted)
            }
        }
        .buttonStyle(.pixel)
    }
    /// Error text: ink, not red, with a 50% dither edge as the attention mark.
    func attentionText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DitherCell(color: ink).frame(width: 4)
            Text(text).font(.bitmap(11)).textSelection(.enabled)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
