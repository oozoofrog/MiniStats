import SwiftUI

// MARK: - Pixel Button

/// Retro bitmap button: 2px border, bitmap-rendered label, pressed state fills with a 2x2
/// dither and nudges the label down-right. All variants use the active finish.
struct PixelButtonStyle: ButtonStyle {
    enum Variant { case `default`, primary, ghost }
    var variant: Variant = .default

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.retroPalette) private var palette

    private var ink: Color { palette.ink }
    private var screen: Color { palette.paper }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let dim = !isEnabled
        return configuration.label
            .foregroundStyle(variant == .primary ? screen : ink)
            .opacity(dim ? 0.4 : 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if variant == .primary {
                    ink.opacity(dim ? 0.4 : 1)
                } else if pressed {
                    DitherCell(color: ink).opacity(0.45)
                } else if variant != .ghost {
                    screen
                }
            }
            .overlay {
                if variant == .primary && pressed {
                    DitherCell(color: screen).opacity(0.2)
                }
            }
            .overlay {
                if variant != .ghost {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(ink.opacity(dim ? 0.4 : 1), lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .background {
                if variant != .ghost && !pressed && !dim {
                    RoundedRectangle(cornerRadius: 2).fill(ink).offset(x: 1, y: 1)
                }
            }
            .offset(pressed && !reduceMotion ? CGSize(width: 1, height: 1) : .zero)
    }
}

extension ButtonStyle where Self == PixelButtonStyle {
    static var pixel: PixelButtonStyle { .init() }
    static var pixelPrimary: PixelButtonStyle { .init(variant: .primary) }
    static var pixelGhost: PixelButtonStyle { .init(variant: .ghost) }
}

// MARK: - Pixel Toggle

/// Retro bitmap checkbox: a 16pt box with a 2px border, a 2x2 dither fill when
/// on, and a bitmap check mark assembled from 1-unit cells.
struct PixelToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.retroPalette) private var palette

    private var ink: Color { palette.ink }
    private var screen: Color { palette.paper }

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let dim = !isEnabled
        return Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(screen)
                    if on {
                        DitherCell(color: ink)
                        PixelCheckMark(color: screen)
                    }
                }
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .stroke(ink.opacity(dim ? 0.4 : 1), lineWidth: 2)
                )
                .opacity(dim ? 0.5 : 1)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .disabled(dim)
        .accessibilityValue(on ? "On" : "Off")
    }
}

extension ToggleStyle where Self == PixelToggleStyle {
    static var pixelToggle: PixelToggleStyle { .init() }
}

// MARK: - Pixel Segmented Control

/// Buttons keep their Text views intact; a native segmented Picker converts its
/// labels to AppKit strings before the bitmap text renderer can draw them.
struct PixelSegmentedControl<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.retroPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = selection == option.value
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(.bitmap(11))
                        .textRenderer(BitmapTextRenderer())
                        .tracking(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? palette.paper : palette.ink)
                .background(selected ? palette.ink : palette.paper)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(palette.paper)
        .overlay(Rectangle().strokeBorder(palette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Bitmap marks

/// Check mark drawn as 1-unit cells on a 14x14 grid, two cells thick.
private struct PixelCheckMark: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let N: CGFloat = 14
            let s = size.width / N
            var path = Path()
            var x: CGFloat = 1, y: CGFloat = 11
            while x <= 3 { addPixel(&path, x: x, y: y, s: s); x += 1; y -= 1 }
            x = 3; y = 9
            while x <= 11 { addPixel(&path, x: x, y: y, s: s); x += 1; y -= 1 }
            ctx.fill(path, with: .color(color))
        }
    }

    private func addPixel(_ path: inout Path, x: CGFloat, y: CGFloat, s: CGFloat) {
        path.addRect(CGRect(x: x * s, y: y * s, width: s, height: s))
        path.addRect(CGRect(x: x * s, y: (y + 1) * s, width: s, height: s))
    }
}
