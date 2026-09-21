import AppKit
import SwiftUI

/// AppKit owns the window; SwiftUI owns the opaque classic surface and selection.
final class DashboardSurfaceController: NSViewController {
    private let model: DashboardModel

    init(model: DashboardModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let host = NSHostingView(rootView: DashboardView(model: model))
        host.frame = NSRect(origin: .zero, size: RetroLayout.dashboardSize)
        view = host
    }
}
