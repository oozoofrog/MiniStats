//
//  Popover.swift
//  
//
//  Created by oozoofrog on 9/14/26.
//

import Foundation
import AppKit
import QuartzCore

final class TransparentPopover {
    
    var contentViewController: NSViewController? {
        didSet {
            panel.contentViewController = contentViewController
            
            if let view = contentViewController?.view {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
    
    var contentSize: NSSize = NSSize(width: 320, height: 400) {
        didSet {
            panel.setContentSize(contentSize)
        }
    }
    
    var behavior: NSPopover.Behavior = .applicationDefined {
        didSet {
            if isShown {
                updateTransientTracking()
            }
        }
    }
    
    var animates: Bool = true

    weak var delegate: NSPopoverDelegate?
    
    var isShown: Bool {
        state != .hidden
    }
    
    var edgeSpacing: CGFloat = 6
    
    private final class PopoverPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    
    private enum State {
        case hidden
        case showing
        case shown
        case closing
    }
    
    private let panel: PopoverPanel
    
    private var state: State = .hidden
    
    private weak var positioningView: NSView?
    private var positioningRect: NSRect = .zero
    
    private var localEventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    
    init() {
        panel = PopoverPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 320,
                height: 240
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        
        configurePanel()
    }
    
    deinit {
        removeTransientTracking()
    }
    
    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        
        panel.hasShadow = false
        panel.level = .popUpMenu
        
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        
        panel.animationBehavior = .none
        
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    func show(
        relativeTo positioningRect: NSRect,
        of positioningView: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard state == .hidden else {
            return
        }
        
        guard let window = positioningView.window else {
            return
        }

        self.positioningView = positioningView
        self.positioningRect = positioningRect

        panel.setContentSize(contentSize)

        let rectInWindow = positioningView.convert(
            positioningRect,
            to: nil
        )

        let anchorRect = window.convertToScreen(rectInWindow)

        let frame = popupFrame(
            anchoredTo: anchorRect,
            preferredEdge: preferredEdge
        )

        state = .showing

        notifyWillShow()

        panel.setFrame(frame, display: false)

        if animates {
            panel.alphaValue = 0
        } else {
            panel.alphaValue = 1
        }

        panel.makeKeyAndOrderFront(nil)

        updateTransientTracking()

        guard animates else {
            finishShowing()
            return
        }

        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }

            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(
                name: .easeOut
            )

            panel.animator().alphaValue = 1

        } completionHandler: { [weak self] in
            self?.finishShowing()
        }
    }

    func performClose(_ sender: Any?) {
        close()
    }

    func close() {
        guard state != .hidden,
              state != .closing else {
            return
        }

        state = .closing

        removeTransientTracking()
        notifyWillClose()

        guard animates else {
            finishClosing()
            return
        }

        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }

            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(
                name: .easeIn
            )

            panel.animator().alphaValue = 0

        } completionHandler: { [weak self] in
            self?.finishClosing()
        }
    }

    // MARK: - Show / close completion

    private func finishShowing() {
        // opening animation 도중 close되었을 수도 있다.
        guard state == .showing else {
            return
        }

        state = .shown
        panel.alphaValue = 1

        notifyDidShow()
    }

    private func finishClosing() {
        guard state == .closing else {
            return
        }

        panel.orderOut(nil)
        panel.alphaValue = 1

        state = .hidden

        notifyDidClose()
    }

    // MARK: - Position

    private func popupFrame(
        anchoredTo anchor: NSRect,
        preferredEdge: NSRectEdge
    ) -> NSRect {
        let size = contentSize

        var origin: NSPoint

        switch preferredEdge {

        case .minY:
            // anchor 아래
            origin = NSPoint(
                x: anchor.midX - size.width / 2,
                y: anchor.minY - edgeSpacing - size.height
            )

        case .maxY:
            // anchor 위
            origin = NSPoint(
                x: anchor.midX - size.width / 2,
                y: anchor.maxY + edgeSpacing
            )

        case .minX:
            // anchor 왼쪽
            origin = NSPoint(
                x: anchor.minX - edgeSpacing - size.width,
                y: anchor.midY - size.height / 2
            )

        case .maxX:
            // anchor 오른쪽
            origin = NSPoint(
                x: anchor.maxX + edgeSpacing,
                y: anchor.midY - size.height / 2
            )

        @unknown default:
            origin = NSPoint(
                x: anchor.midX - size.width / 2,
                y: anchor.minY - edgeSpacing - size.height
            )
        }

        let candidate = NSRect(
            origin: origin,
            size: size
        )

        guard let screen = screen(containing: anchor) else {
            return candidate
        }

        return constrain(
            candidate,
            to: screen.visibleFrame
        )
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(rect).area
                < rhs.frame.intersection(rect).area
        }
    }

    private func constrain(
        _ frame: NSRect,
        to visibleFrame: NSRect
    ) -> NSRect {
        let margin: CGFloat = 8

        var result = frame

        let minimumX = visibleFrame.minX + margin
        let maximumX =
            visibleFrame.maxX - frame.width - margin

        let minimumY = visibleFrame.minY + margin
        let maximumY =
            visibleFrame.maxY - frame.height - margin

        if maximumX >= minimumX {
            result.origin.x = min(
                max(result.origin.x, minimumX),
                maximumX
            )
        }

        if maximumY >= minimumY {
            result.origin.y = min(
                max(result.origin.y, minimumY),
                maximumY
            )
        }

        return result
    }

    // MARK: - Transient behavior

    private func updateTransientTracking() {
        removeTransientTracking()

        guard state != .hidden else {
            return
        }

        guard behavior == .transient else {
            return
        }

        /*
         NSApp은 현재 코드에서 popover를 띄우기 전에
         activate(ignoringOtherApps:) 되고 있으므로,
         다른 앱을 클릭하면 didResignActive가 발생한다.

         따라서 global event monitor가 필요 없다.
         이 방식은 Input Monitoring 같은 추가 권한도 요구하지 않는다.
         */

        resignActiveObserver =
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                self?.performClose(nil)
            }

        localEventMonitor =
            NSEvent.addLocalMonitorForEvents(
                matching: [
                    .leftMouseDown,
                    .rightMouseDown,
                    .otherMouseDown,
                    .keyDown
                ]
            ) { [weak self] event in

                guard let self else {
                    return event
                }

                // ESC
                if event.type == .keyDown {
                    if event.keyCode == 53 {
                        performClose(nil)
                        return nil
                    }

                    return event
                }

                // Panel 안을 클릭한 경우 유지.
                if event.window === panel {
                    return event
                }

                /*
                 status item 자체를 클릭한 경우 여기서 닫지 않는다.

                 그렇지 않으면:
                     event monitor -> close
                     status button action -> isShown == false -> 다시 open

                 순서가 되어 한 번의 클릭으로 다시 열리는 문제가 생긴다.

                 status button action의 toggleDashboard()에게
                 닫는 동작을 맡긴다.
                 */
                if isEventInsidePositioningView(event) {
                    return event
                }

                // 동일 앱의 다른 UI 클릭.
                performClose(nil)

                // 원래 클릭은 그대로 전달.
                return event
            }
    }

    private func removeTransientTracking() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(
                resignActiveObserver
            )

            self.resignActiveObserver = nil
        }
    }

    private func isEventInsidePositioningView(
        _ event: NSEvent
    ) -> Bool {
        guard let view = positioningView,
              let window = view.window,
              event.window === window else {
            return false
        }

        let point = view.convert(
            event.locationInWindow,
            from: nil
        )

        return view.bounds.contains(point)
    }

    // MARK: - NSPopoverDelegate compatibility

    private func notifyWillShow() {
        let notification = Notification(
            name: NSPopover.willShowNotification,
            object: self
        )

        delegate?.popoverWillShow?(notification)

        NotificationCenter.default.post(notification)
    }

    private func notifyDidShow() {
        let notification = Notification(
            name: NSPopover.didShowNotification,
            object: self
        )

        delegate?.popoverDidShow?(notification)

        NotificationCenter.default.post(notification)
    }

    private func notifyWillClose() {
        let notification = Notification(
            name: NSPopover.willCloseNotification,
            object: self
        )

        delegate?.popoverWillClose?(notification)

        NotificationCenter.default.post(notification)
    }

    private func notifyDidClose() {
        let notification = Notification(
            name: NSPopover.didCloseNotification,
            object: self
        )

        delegate?.popoverDidClose?(notification)

        NotificationCenter.default.post(notification)
    }
}

// MARK: - Helpers

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }

        return width * height
    }
}
