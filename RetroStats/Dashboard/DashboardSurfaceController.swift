import AppKit
import SwiftUI

/// AppKit owns the window; SwiftUI owns the opaque classic surface and selection.
final class DashboardSurfaceController: NSViewController {
    private let model: DashboardModel

    private let toggleSize: () -> Void

    init(model: DashboardModel, toggleSize: @escaping () -> Void) {
        self.model = model
        self.toggleSize = toggleSize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let host = NSHostingView(rootView: DashboardView(model: model, toggleSize: toggleSize))
        host.frame = NSRect(origin: .zero, size: RetroLayout.compactSize)
        view = host
    }
}
