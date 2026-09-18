import SwiftUI

// MARK: - Pixel Button

/// Retro bitmap button: 2px border, pixel font, pressed state fills with a 2x2
/// dither and nudges the label down-right. Variants match the LCD design tokens.
struct PixelButtonStyle: ButtonStyle {
    enum Variant { case `default`, primary, ghost }
    var variant: Variant = .default

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { .primary }
    private var screen: Color { scheme == .dark ? .black : .white }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let dim = !isEnabled
        return configuration.label
            .foregroundStyle(variant == .primary ? screen : ink)
            .opacity(dim ? 0.4 : 1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                if variant == .primary {
                    ink.opacity(dim ? 0.4 : 1)
                } else if pressed {
                    DitherCell(color: ink).opacity(0.45)
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
                        .stroke(ink.opacity(dim ? 0.4 : 1), lineWidth: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
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
    @Environment(\.colorScheme) private var scheme

    private var ink: Color { .primary }
    private var screen: Color { scheme == .dark ? .black : .white }

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
    }
}

extension ToggleStyle where Self == PixelToggleStyle {
    static var pixelToggle: PixelToggleStyle { .init() }
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
