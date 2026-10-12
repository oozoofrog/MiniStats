import AppKit
import SwiftUI

extension DashboardContentView {
    @ViewBuilder var autoCleanupSection: some View {
        if let cleanup = storage?.autoCleanup {
            VStack(alignment: .leading, spacing: 12) {
                RetroSectionHeading(title: "AUTOMATIC CLEANUP")
                Toggle("Enable scheduled cleanup", isOn: Binding(get: { cleanup.settings.enabled }, set: { cleanup.setEnabled($0) }))
                    .toggleStyle(.pixelToggle).font(.bitmap(12))
                Text("Permanently removes eligible items while RetroStats is running.")
                    .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                PixelSegmentedControl(title: "Cleanup schedule", options: [(1, "Daily"), (7, "Weekly")],
                                      selection: Binding(get: { cleanup.settings.intervalDays }, set: { cleanup.setInterval($0) }))
                    .disabled(storage?.busy == true)
                ForEach(CleanupCategory.allCases, id: \.self) { category in
                    Toggle("\(category.label) · \(category == .derivedData ? "8 hours" : "\(category.days) days")",
                           isOn: Binding(get: { cleanup.settings.categories.contains(category) }, set: { cleanup.setCategory(category, enabled: $0) }))
                        .toggleStyle(.pixelToggle).font(.bitmap(11)).disabled(storage?.busy == true)
                }
                Text("Shared DerivedData, active apps, unverified paths and linked files are kept. App folders must match a registered app. Application Support, containers, Downloads and Trash are excluded.")
                    .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if cleanup.settings.enabled {
                    if cleanup.settings.categories.isEmpty {
                        attentionText("Select at least one cleanup category.")
                    } else if let next = cleanup.settings.nextRun {
                        Text("Next check: \(englishDateTime(next)) · after launch if the app is closed")
                            .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text("Exclusions").font(.bitmap(12))
                    Spacer()
                    Button("Add…") { cleanup.chooseExclusion() }.buttonStyle(.pixelGhost).disabled(storage?.busy == true)
                }
                ForEach(cleanup.settings.exclusions.sorted(), id: \.self) { path in
                    HStack {
                        Text(path).font(.bitmap(11)).lineLimit(2).truncationMode(.middle).help(path)
                        Spacer(minLength: 4)
                        Button { cleanup.removeExclusion(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove exclusion \(path)").disabled(storage?.busy == true)
                    }
                }
                if cleanup.busy {
                    HStack(spacing: 8) {
                        PixelHourglass(size: 12, color: ink)
                        Text(cleanup.running ? "Cleaning…" : "Checking cleanup candidates…").font(.bitmap(11))
                        Spacer(minLength: 0)
                        Button("Cancel") { cleanup.cancel() }.buttonStyle(.pixel)
                    }
                    if let path = cleanup.currentPath {
                        Text(path).font(.bitmap(11)).lineLimit(1).truncationMode(.middle).help(path)
                    }
                } else {
                    Button("Preview Cleanup") { cleanup.preview() }.buttonStyle(.pixel)
                        .disabled(storage?.busy == true || cleanup.settings.categories.isEmpty)
                }
                if let error = cleanup.error { attentionText(error) }
                if let scan = cleanup.scan, !cleanup.busy {
                    Text("\(scan.candidates.count) candidates · \(bytes(UInt64(scan.bytes))) estimated")
                        .font(.bitmap(12))
                    Button("Show Full Preview") { NSWorkspace.shared.activateFileViewerSelecting([cleanup.previewURL]) }
                        .buttonStyle(.pixelGhost)
                    if scan.candidates.isEmpty {
                        Text("No eligible items in the selected categories.").font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    ForEach(Array(scan.candidates.prefix(30)), id: \.path) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.bitmap(11)).lineLimit(1).truncationMode(.middle)
                                Text("\(item.root.category.label) · \(bytes(UInt64(item.size)))").font(.bitmap(11)).foregroundStyle(palette.muted)
                            }.help(item.path)
                            Spacer(minLength: 0)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.plain).accessibilityLabel("Show \(item.path) in Finder")
                            Button("Exclude") { cleanup.exclude(item.path) }.buttonStyle(.pixelGhost).disabled(storage?.busy == true)
                        }
                    }
                    if scan.candidates.count > 30 {
                        Text("Showing 30 of \(scan.candidates.count) items. Narrow the categories or add exclusions before deletion.").font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    if !scan.candidates.isEmpty {
                        Button("Permanently Delete \(scan.candidates.count) Items") { cleanup.confirmDeletion() }
                            .buttonStyle(.pixelPrimary).disabled(storage?.busy == true)
                    }
                    if !scan.skipped.isEmpty {
                        DisclosureGroup("Kept / skipped: \(scan.skipped.count)") {
                            ForEach(Array(scan.skipped.prefix(30).enumerated()), id: \.offset) { _, reason in
                                Text(reason).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                            }
                        }.font(.bitmap(11))
                    }
                }
                if let record = cleanup.history.first {
                    let inProgress = cleanup.running && cleanup.activeRecordID == record.id
                    RetroRule()
                    Text("\(record.automatic ? "Scheduled" : "Manual") · \(englishDateTime(record.date))")
                        .font(.bitmap(11)).foregroundStyle(palette.muted)
                    Text("\(inProgress ? "In progress" : (record.finished ? "Finished" : "Interrupted / incomplete")) · Deleted \(record.deletedCount) · Kept \(record.items.count - record.deletedCount) · \(bytes(UInt64(max(0, record.freedBytes)))) estimated")
                        .font(.bitmap(11)).fixedSize(horizontal: false, vertical: true)
                    if !record.finished && !inProgress {
                        Text("Some files may have been removed. Review the history before another cleanup.").font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    Button("Show Cleanup History") { NSWorkspace.shared.activateFileViewerSelecting([cleanup.historyURL]) }
                        .buttonStyle(.pixelGhost)
                }
            }
            .padding(14).retroPanel()
        }
    }
}
