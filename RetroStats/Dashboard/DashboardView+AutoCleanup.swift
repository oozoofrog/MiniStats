import AppKit
import SwiftUI

extension DashboardContentView {
    @ViewBuilder var autoCleanupSection: some View {
        if let cleanup = storage?.autoCleanup {
            VStack(alignment: .leading, spacing: 12) {
                RetroSectionHeading(title: "DISK CLEANUP")
                ForEach(cleanup.volumes) { volume in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(volume.name) · \(bytes(UInt64(volume.free))) free").font(.bitmap(12))
                        Text(volume.path).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                        Text(volume.topology.map { "APFS container: \($0.containerUUID)" } ?? "APFS container / physical storage identity: unknown")
                            .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        if let estimate = volume.purgeableEstimate {
                            Text("Purgeable estimate: \(bytes(UInt64(estimate))) · not guaranteed free space")
                                .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("APFS volumes may share container capacity. Do not add their free space. Moving caches on another volume does not free the main disk.")
                    .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                Toggle("Enable scheduled previews", isOn: Binding(get: { cleanup.settings.enabled }, set: { cleanup.setEnabled($0) }))
                    .toggleStyle(.pixelToggle).font(.bitmap(12)).disabled(cleanup.busy)
                PixelSegmentedControl(title: "Preview schedule", options: [(1, "Daily"), (7, "Weekly")],
                                      selection: Binding(get: { cleanup.settings.intervalDays }, set: { cleanup.setInterval($0) }))
                    .disabled(storage?.busy == true)
                ForEach([CleanupCategory.developerCaches, .appCaches], id: \.self) { category in
                    Toggle("\(category.label) · \(category.days) days",
                           isOn: Binding(get: { cleanup.settings.categories.contains(category) }, set: { cleanup.setCategory(category, enabled: $0) }))
                        .toggleStyle(.pixelToggle).font(.bitmap(11)).disabled(storage?.busy == true)
                }
                Text("Only known rebuildable tool and updater caches are eligible. Recent changes, running apps/builds/updates, open files, links and unknown permissions are kept. DerivedData, DeviceSupport, simulators and personal data are protected.")
                    .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if cleanup.settings.enabled, let next = cleanup.settings.nextRun {
                    Text("Next preview: \(englishDateTime(next))").font(.bitmap(11)).foregroundStyle(palette.muted)
                }
                HStack {
                    Text("Exclusions").font(.bitmap(12)); Spacer()
                    Button("Add…") { cleanup.chooseExclusion() }.buttonStyle(.pixelGhost).disabled(storage?.busy == true)
                }
                ForEach(cleanup.settings.exclusions.sorted(), id: \.self) { path in
                    HStack {
                        Text(path).font(.bitmap(11)).lineLimit(2).truncationMode(.middle).help(path); Spacer(minLength: 4)
                        Button { cleanup.removeExclusion(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove exclusion \(path)").disabled(storage?.busy == true)
                    }
                }
                if cleanup.busy {
                    HStack {
                        PixelHourglass(size: 12, color: ink)
                        Text(cleanup.running ? "Working on selected caches…" : "Checking…").font(.bitmap(11)); Spacer()
                        Button("Cancel") { cleanup.cancel() }.buttonStyle(.pixel)
                    }
                    if let path = cleanup.currentPath { Text(path).font(.bitmap(11)).lineLimit(2).truncationMode(.middle) }
                } else {
                    Button("Preview Cleanup") { cleanup.preview() }.buttonStyle(.pixel).disabled(storage?.busy == true || cleanup.settings.categories.isEmpty)
                }
                if let error = cleanup.error { attentionText(error) }
                if let scan = cleanup.scan, !cleanup.busy {
                    Text("\(scan.candidates.count) candidates · \(bytes(UInt64(scan.bytes))) allocated")
                        .font(.bitmap(12))
                    Text("Allocated size is not expected reclaimed space. Recovery stays on each source volume and remains until restored or managed manually.")
                        .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Show Full Preview") { NSWorkspace.shared.activateFileViewerSelecting([cleanup.previewURL]) }.buttonStyle(.pixelGhost)
                    if scan.candidates.isEmpty { Text("No verified idle caches are eligible.").font(.bitmap(11)).foregroundStyle(palette.muted) }
                    ForEach(scan.candidates, id: \.path) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: Binding(get: { cleanup.selected.contains(item.path) }, set: { cleanup.select(item.path, enabled: $0) })) {
                                Text("\(URL(fileURLWithPath: item.path).lastPathComponent) · \(bytes(UInt64(item.size)))").font(.bitmap(11))
                            }.toggleStyle(.pixelToggle)
                            Text(item.path).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                            Text("Volume: \(item.volume?.path ?? "Unknown") · \(item.reason)")
                                .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                            Button("Exclude") { cleanup.exclude(item.path) }.buttonStyle(.pixelGhost)
                        }.padding(.vertical, 4)
                    }
                    if !scan.candidates.isEmpty {
                        Button("Choose External Archive…") { cleanup.chooseArchiveDestination() }.buttonStyle(.pixel)
                        if let path = cleanup.archiveDestination {
                            Text(path).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                        }
                        Text(CleanupReclaimSafety.explanation)
                            .font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Create Verified External Copy") { cleanup.confirmExternalCopy() }
                            .buttonStyle(.pixel).disabled(cleanup.selected.isEmpty || cleanup.archiveDestination == nil || storage?.busy == true)
                        Button("Archive & Reclaim \(cleanup.selected.count) Selected") { cleanup.confirmArchive() }
                            .buttonStyle(.pixelPrimary).disabled(!AutoCleanupController.sourceReclaimEnabled || cleanup.selected.isEmpty || cleanup.archiveDestination == nil || storage?.busy == true)
                        Button("Move \(cleanup.selected.count) Selected to Recovery · \(bytes(UInt64(cleanup.selectedBytes)))") { cleanup.confirmMove() }
                            .buttonStyle(.pixelPrimary).disabled(cleanup.selected.isEmpty || storage?.busy == true)
                    }
                    DisclosureGroup("Kept / unknown: \(scan.skipped.count)") {
                        ForEach(Array(scan.skipped.enumerated()), id: \.offset) { _, reason in
                            Text(reason).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                        }
                    }.font(.bitmap(11))
                }
                ForEach(cleanup.history) { record in
                    RetroRule()
                    Text("\(englishDateTime(record.date)) · \(record.outcomeLabel)")
                        .font(.bitmap(11)).foregroundStyle(palette.muted)
                    Text("\(record.items.filter { $0.receipt != nil && $0.deleted }.count) recovery moves · \(bytes(UInt64(max(0, record.freedBytes)))) allocated; verified copies \(bytes(UInt64(max(0, record.copiedBytes)))) (not space freed)")
                        .font(.bitmap(11)).fixedSize(horizontal: false, vertical: true)
                    if let before = record.before, let after = record.after {
                        ForEach(CleanupVolume.delta(before: before, after: after), id: \.self) { text in
                            Text(text).font(.bitmap(11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Measured changes include APFS sharing and other writes; not attributable to these moves.")
                            .font(.bitmap(11)).foregroundStyle(palette.muted)
                    }
                    DisclosureGroup("Items / recovery: \(record.items.count)") {
                        ForEach(Array(record.items.enumerated()), id: \.offset) { index, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.path).font(.bitmap(11)).textSelection(.enabled)
                                Text(item.reason).font(.bitmap(11)).foregroundStyle(palette.muted)
                                if let staging = item.restoreStagingPath {
                                    Text("Restore staging: \(staging)").font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                                }
                                if let archive = item.archive {
                                    Text("External: \(archive.payload) · \(archive.phase)").font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                                    Button("Show Archive Manifest") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: archive.manifest)]) }.buttonStyle(.pixelGhost)
                                }
                                if let path = item.archive?.copiedTree != nil ? item.archive?.payload : item.recoveryPath {
                                    Text(path).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                                    HStack {
                                        Button(item.restored == true ? "Restored" : "Restore") { cleanup.restore(recordID: record.id, index: index) }
                                            .buttonStyle(.pixel).disabled(cleanup.busy || item.restored == true)
                                        Button("Show Recovery") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.buttonStyle(.pixelGhost)
                                    }
                                } else if item.deleted { Text("Legacy permanent deletion: no recovery receipt").font(.bitmap(11)).foregroundStyle(palette.muted) }
                            }.padding(.vertical, 4)
                        }
                        ForEach(Array(record.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.bitmap(11)).foregroundStyle(palette.muted).textSelection(.enabled)
                        }
                    }.font(.bitmap(11))
                }
                if !cleanup.history.isEmpty {
                    Button("Show Cleanup History") { NSWorkspace.shared.activateFileViewerSelecting([cleanup.historyURL]) }.buttonStyle(.pixelGhost)
                }
            }.padding(14).retroPanel()
        }
    }
}
