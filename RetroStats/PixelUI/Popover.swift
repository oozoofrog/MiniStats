import AppKit

/// Borderless transient panel anchored below a status item. NSPopover draws its
/// own opaque chrome, so the glass dashboard surface uses this panel instead.
final class TransparentPopover {
    private final class PopoverPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private enum State { case hidden, showing, shown, closing }

    var contentViewController: NSViewController? {
        didSet {
            panel.contentViewController = contentViewController
            contentViewController?.view.wantsLayer = true
            contentViewController?.view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
    var contentSize = NSSize(width: 320, height: 400)
    var animates = true
    weak var delegate: NSPopoverDelegate?
    var isShown: Bool { state != .hidden }

    private let panel = PopoverPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                     styleMask: [.borderless], backing: .buffered, defer: true)
    private var state = State.hidden
    private weak var positioningView: NSView?
    private var localEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    deinit { removeTransientTracking() }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        guard state == .hidden, let window = positioningView.window else { return }
        self.positioningView = positioningView
        panel.setContentSize(contentSize)
        let anchor = window.convertToScreen(positioningView.convert(positioningRect, to: nil))
        state = .showing
        panel.setFrame(popupFrame(anchoredTo: anchor, preferredEdge: preferredEdge), display: false)
        panel.alphaValue = animates ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        installTransientTracking()
        fade(to: 1, duration: 0.12, timing: .easeOut) { [weak self] in
            guard let self, state == .showing else { return }
            state = .shown
            delegate?.popoverDidShow?(Notification(name: NSPopover.didShowNotification, object: self))
        }
    }

    func performClose(_ sender: Any?) {
        guard state == .showing || state == .shown else { return }
        state = .closing
        removeTransientTracking()
        fade(to: 0, duration: 0.10, timing: .easeIn) { [weak self] in
            guard let self, state == .closing else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            state = .hidden
            delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName, completion: @escaping () -> Void) {
        guard animates else { panel.alphaValue = alpha; completion(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    // MARK: - Position

    private func popupFrame(anchoredTo anchor: NSRect, preferredEdge: NSRectEdge) -> NSRect {
        let size = contentSize
        let spacing: CGFloat = 6
        let origin: NSPoint
        switch preferredEdge {
        case .maxY: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + spacing)
        case .minX: origin = NSPoint(x: anchor.minX - spacing - size.width, y: anchor.midY - size.height / 2)
        case .maxX: origin = NSPoint(x: anchor.maxX + spacing, y: anchor.midY - size.height / 2)
        default: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - spacing - size.height)
        }
        var frame = NSRect(origin: origin, size: size)
        guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(anchor).area < $1.frame.intersection(anchor).area }) else { return frame }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        if visible.width >= size.width { frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width) }
        if visible.height >= size.height { frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height) }
        return frame
    }

    // MARK: - Transient behavior

    private func installTransientTracking() {
        removeTransientTracking()
        // NSApp is activated before showing, so clicking another app fires didResignActive;
        // no global event monitor (and no Input Monitoring permission) is needed.
        resignActiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.performClose(nil)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }  // ESC
                performClose(nil)
                return nil
            }
            // Clicks inside the panel keep it open. Clicks on the status item are left to
            // toggleDashboard(); closing here first would make that action reopen it.
            if event.window === panel || isEventInsidePositioningView(event) { return event }
            performClose(nil)
            return event
        }
    }

    private func removeTransientTracking() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        localEventMonitor = nil
        resignActiveObserver = nil
    }

    private func isEventInsidePositioningView(_ event: NSEvent) -> Bool {
        guard let view = positioningView, event.window === view.window else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
