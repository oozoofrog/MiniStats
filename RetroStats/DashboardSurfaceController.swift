import AppKit
import SwiftUI

/// The Liquid Glass surface owns a single hosting content view; reduced transparency uses a solid surface.
final class DashboardSurfaceController: NSViewController {
    private let model: DashboardModel
    private lazy var host = NSHostingView(rootView: DashboardView(model: model))
    private var observer: NSObjectProtocol?

    init(model: DashboardModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerRadius = 20
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        installSurface()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.installSurface()
        }
    }

    private func installSurface() {
        // Preserve the NSHostingView so SwiftUI local @State survives a runtime
        // Reduce Transparency toggle; only the AppKit surface is replaced.
        host.removeFromSuperview()
        view.subviews.forEach { $0.removeFromSuperview() }

        let surface: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = SolidDashboardSurface()
            solid.addSubview(host)
            surface = solid
        } else {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            glass.clipsToBounds = true
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            glass.contentView = host
            surface = glass
        }

        view.addSubview(surface)
        surface.frame = view.bounds
        surface.autoresizingMask = [.width, .height]
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
