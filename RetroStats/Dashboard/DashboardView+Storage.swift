import AppKit
import SwiftUI

extension DashboardContentView {
    var storageDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            volumeCatalog
            selectedVolumeDetails
            RetroRule()
            autoCleanupSection
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
        Text("Recovery moves retain same-volume space. Verified external copies retain their original source. Source reclamation remains unavailable pending safety validation. Review measured changes per volume in history.")
            .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
    }
    /// Error text: ink, not red, with a 50% dither edge as the attention mark.
    func attentionText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DitherCell(color: ink).frame(width: 4)
            Text(text).font(.bitmap(11)).textSelection(.enabled)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
