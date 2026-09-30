import AppKit
import SwiftUI

enum StatusMetric: Equatable {
    case unavailable, percent(Int), maximum

    init(_ value: Double?) {
        guard let value, value.isFinite else { self = .unavailable; return }
        let rounded = max(0, value).rounded()
        self = rounded >= 100 ? .maximum : .percent(Int(rounded))
    }
}

/// Retains the existing 26pt, two-line readout and PixelMax at 100%.
struct BitmapStatusText: View {
    let cpu: Double?
    let memory: Double?

    var body: some View {
        VStack(spacing: 1) {
            row(StatusMetric(cpu))
            row(StatusMetric(memory))
        }
        .font(.bitmap(9, scaled: false))
        .frame(width: 26)
        .textRenderer(BitmapTextRenderer())
        .tracking(1)
    }

    @ViewBuilder private func row(_ value: StatusMetric) -> some View {
        switch value {
        case .unavailable: Text("—")
        case .percent(let percent): Text("\(percent)%")
        case .maximum: PixelMax(size: 9, color: .white)
        }
    }
}

/// The approved ripple uses 1pt frontier cells whose opacity changes gradually.
/// Solid columns below the frontier are batched; integrated coverage stays exact.
struct StorageBitFill {
    static let period: Double = 5.5
    static let framesPerSecond: Double = 30
    static let amplitude: CGFloat = 0.55

    struct Cell: Equatable {
        let rect: CGRect
        let opacity: CGFloat
    }

    static func percent(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    static func cells(size: CGSize, percent value: Double?, phase: Double? = nil) -> [Cell] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        let amount = CGFloat(percent(value) / 100)
        guard amount > 0 else { return [] }
        let columns = Int(ceil(size.width))
        let widths = (0..<columns).map { min(1, size.width - CGFloat($0)) }
        let phase = phase.flatMap { $0.isFinite ? $0.truncatingRemainder(dividingBy: 2 * .pi) : nil }
        let heightScale = amplitude * min(1, amount * 12, (1 - amount) * 12)
        let offsets = (0..<columns).map { x -> CGFloat in
            guard let phase else { return 0 }
            let angle = 2 * Double.pi * (Double(x) + 0.5) / Double(columns)
            return heightScale * CGFloat(0.7 * sin(angle - phase) + 0.3 * sin(2 * angle + phase))
        }
        let target = amount * size.width * size.height
        var low = -heightScale, high = size.height + heightScale
        for _ in 0..<32 {
            let mid = (low + high) / 2
            let area = offsets.enumerated().reduce(CGFloat.zero) {
                $0 + widths[$1.offset] * min(size.height, max(0, mid + $1.element))
            }
            if area < target { low = mid } else { high = mid }
        }
        let base = (low + high) / 2
        return offsets.enumerated().flatMap { x, offset -> [Cell] in
            let height = min(size.height, max(0, base + offset))
            let solid = floor(height)
            var cells: [Cell] = []
            if solid > 0 {
                cells.append(Cell(rect: CGRect(x: CGFloat(x), y: 0, width: widths[x], height: solid), opacity: 1))
            }
            let edgeHeight = min(1, size.height - solid)
            if height > solid, edgeHeight > 0 {
                cells.append(Cell(rect: CGRect(x: CGFloat(x), y: solid, width: widths[x], height: edgeHeight),
                                  opacity: (height - solid) / edgeHeight))
            }
            return cells
        }
    }
}

/// Both operands are white. XOR leaves white text above the fill and true
/// transparent glyphs within it. Composite offscreen so XOR never erases the
/// system menu bar's own backing surface or substitutes a sampled background.
@MainActor func statusTextImage(size: CGSize, scale: CGFloat, cpu: Double?, memory: Double?) -> CGImage? {
    let renderer = ImageRenderer(content: BitmapStatusText(cpu: cpu, memory: memory)
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .environment(\.displayScale, scale))
    renderer.scale = scale
    return renderer.cgImage
}

@MainActor func statusReadoutImage(size: CGSize, scale: CGFloat, cpu: Double?, memory: Double?, storagePercent: Double?, phase: Double? = nil) -> CGImage? {
    guard let text = statusTextImage(size: size, scale: scale, cpu: cpu, memory: memory) else { return nil }
    return compositeStatusReadout(size: size, scale: scale, text: text, storagePercent: storagePercent, phase: phase)
}

@MainActor private func compositeStatusReadout(size: CGSize, scale: CGFloat, text: CGImage, storagePercent: Double?, phase: Double?) -> CGImage? {
    guard size.width > 0, size.height > 0, scale > 0,
          let context = CGContext(data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(false)
    context.setFillColor(NSColor.white.cgColor)
    for cell in StorageBitFill.cells(size: size, percent: storagePercent, phase: phase) {
        context.setAlpha(cell.opacity)
        context.fill(cell.rect)
    }
    context.setAlpha(1)
    context.setBlendMode(.xor)
    context.interpolationQuality = .none
    context.draw(text, in: CGRect(origin: .zero, size: size))
    return context.makeImage()
}

final class StatusReadout: NSView {
    private var cpu: Double?
    private var memory: Double?
    private var storagePercent: Double = 0
    private var textImage: CGImage?
    private var image: CGImage?
    private var imageSize = CGSize.zero
    private var imageScale: CGFloat = 0
    private var animationTimer: Timer?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeMotionPreference()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeMotionPreference()
    }

    deinit {
        animationTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func observeMotionPreference() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged(_:)),
                                                         name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    static func shouldAnimate(storagePercent: Double, attached: Bool, reduceMotion: Bool) -> Bool {
        attached && !reduceMotion && storagePercent > 0 && storagePercent < 100
    }

    @objc private func motionPreferenceChanged(_ notification: Notification) {
        updateAnimation()
        image = nil
        needsDisplay = true
    }

    private func updateAnimation() {
        let enabled = Self.shouldAnimate(storagePercent: storagePercent, attached: window != nil,
                                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if enabled && animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / StorageBitFill.framesPerSecond, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.image = nil
                self.needsDisplay = true
            }
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !enabled {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    func update(cpu: Double?, memory: Double?, storagePercent: Double?) {
        let percent = StorageBitFill.percent(storagePercent)
        let textChanged = StatusMetric(cpu) != StatusMetric(self.cpu) || StatusMetric(memory) != StatusMetric(self.memory)
        guard textChanged || percent != self.storagePercent else { return }
        self.cpu = cpu
        self.memory = memory
        self.storagePercent = percent
        if textChanged { textImage = nil }
        image = nil
        needsDisplay = true
        updateAnimation()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        textImage = nil
        image = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if imageSize != bounds.size || imageScale != scale {
            textImage = nil
            image = nil
            imageSize = bounds.size
            imageScale = scale
        }
        if textImage == nil { textImage = statusTextImage(size: bounds.size, scale: scale, cpu: cpu, memory: memory) }
        if image == nil, let textImage {
            let phase = animationTimer.map { _ in
                2 * Double.pi * ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: StorageBitFill.period) / StorageBitFill.period
            }
            image = compositeStatusReadout(size: bounds.size, scale: scale, text: textImage, storagePercent: storagePercent, phase: phase)
        }
        guard let image else { return }
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }
}
