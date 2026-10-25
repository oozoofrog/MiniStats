import SwiftUI

/// One capacity row used in the dashboard and the menu. Never aggregates volumes.
struct StorageVolumeRow: View {
    let volume: StorageVolume
    var showsPath = false
    @Environment(\.retroPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(freeLabel).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(volume.name).lineLimit(2).truncationMode(.middle)
                    Text(freeLabel)
                }
            }.font(.bitmap(12))
            if let capacity = volume.capacity {
                UsageBar(percent: capacity.usedPercent, color: palette.phosphor).frame(height: 7)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(volume.isMain ? "Main disk" : volume.location.rawValue)
                        Spacer(minLength: 6)
                        Text("\(bytes(capacity.used)) / \(bytes(capacity.total)) used")
                    }
                    Text("\(bytes(capacity.used)) used / \(bytes(capacity.total)) total")
                }.font(.bitmap(10)).foregroundStyle(palette.muted)
            }
            if showsPath {
                Text(volume.path).font(.bitmap(10)).foregroundStyle(palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .help("\(volume.name) · \(volume.path) · \(freeLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.name), \(volume.location.rawValue)\(volume.isMain ? ", main disk" : "")")
        .accessibilityValue(volume.capacity.map { "\(bytes($0.free)) free, \(bytes($0.used)) used, \(bytes($0.total)) total" } ?? "Capacity unavailable")
    }

    private var freeLabel: String { volume.capacity.map { "\(bytes($0.free)) free" } ?? "Unavailable" }
}
