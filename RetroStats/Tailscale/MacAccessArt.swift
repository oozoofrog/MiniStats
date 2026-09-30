import SwiftUI

// Dot matrices from the dedicated mobile setup design preview (2026-09-30).
// Graphics illustrate an action. Only observed request evidence selects the ready scene.
enum MacAccessArt: String { case get, signIn, allow, check, ready, macGuide, files, screen, terminal, web
    private static let sprites: [String: [String]] = [
        "phone": ["0111110", "1100011", "1000001", "1000001", "1000001", "1000001", "1000001", "1000001", "1000001", "1000001", "1000001", "1100011", "0111110"],
        "pad": ["01111111110", "11000000011", "10000000001", "10000000001", "10000000001", "10000000001", "10000000001", "10000000001", "10000000001", "10000000001", "11000000011", "01111111110"],
        "mac": ["0111111111110", "1100000000011", "1000000000001", "1000000000001", "1000000000001", "1000000000001", "1000000000001", "1000000000001", "1111111111111", "0000010100000", "0000010100000", "0001111111000"],
        "download": ["0001000", "0001000", "0001000", "1001001", "0101010", "0011100", "0001000", "0000000", "1111111"],
        "person": ["0011100", "0100010", "0100010", "0011100", "0000000", "0111110", "1000001", "1000001"],
        "equal": ["00000", "11111", "00000", "11111", "00000"],
        "allow": ["000000001", "000000011", "000000110", "100001100", "110011000", "011110000", "001100000"],
        "lock": ["0011100", "0100010", "0100010", "1111111", "1001001", "1001001", "1111111"],
        "arrow": ["0001000", "0001100", "1111110", "0001100", "0001000"],
        "web": ["01111111110", "10000000001", "11111111111", "10000000001", "10001110001", "10001010001", "10001110001", "10000000001", "11111111111"],
        "files": ["01111000000", "10000111110", "10000000001", "10000000001", "10000000001", "10000000001", "10000000001", "11111111111"],
        "screen": ["01111111110", "10000000001", "10000000001", "10000000001", "10000000001", "11111111111", "00001010000", "00111111100"],
        "terminal": ["11111111111", "10000000001", "10100000001", "10010000001", "10100000001", "10000111001", "10000000001", "11111111111"],
    ]
    var rows: [String] {
        let parts: [(String, Int, Int)]
        switch self {
        case .get: parts = [("download", 6, 1), ("phone", 6, 13), ("pad", 22, 13)]
        case .signIn: parts = [("person", 4, 0), ("person", 29, 0), ("mac", 1, 12), ("equal", 18, 16), ("phone", 29, 12)]
        case .allow: parts = [("phone", 4, 6), ("lock", 17, 7), ("allow", 27, 10)]
        case .check: parts = [("phone", 3, 6), ("arrow", 15, 10), ("mac", 25, 6)]
        case .ready: parts = [("phone", 3, 6), ("allow", 14, 8), ("mac", 27, 6)]
        case .macGuide: parts = [("mac", 1, 7), ("arrow", 17, 10), ("phone", 29, 2), ("pad", 28, 17)]
        default: return Self.sprites[rawValue] ?? []
        }
        let dimensions: (Int, Int) = [.get: (39, 27), .signIn: (43, 27), .allow: (39, 25), .check: (41, 25), .ready: (41, 25), .macGuide: (43, 30)][self] ?? (43, 30)
        var cells = Array(repeating: Array(repeating: Character("0"), count: dimensions.0), count: dimensions.1)
        for (name, x, y) in parts {
            for (dy, row) in (Self.sprites[name] ?? []).enumerated() {
                for (dx, bit) in row.enumerated() where bit == "1" { if y + dy < dimensions.1 && x + dx < dimensions.0 { cells[y + dy][x + dx] = "1" } }
            }
        }
        return cells.map { String($0) }
    }
    var svg: String {
        let rows = self.rows, width = rows.first?.count ?? 1
        let compact = [.files, .screen, .terminal, .web].contains(self)
        let pitch = compact ? 3 : 5, square = compact ? 2 : 3
        var dots = ""
        for (y, row) in rows.enumerated() { for (x, bit) in row.enumerated() where bit == "1" { dots += "<rect x='\(x * pitch)' y='\(y * pitch)' width='\(square)' height='\(square)'/>" } }
        return "<svg aria-hidden='true' width='\(width * pitch)' height='\(rows.count * pitch)' viewBox='0 0 \(width * pitch) \(rows.count * pitch)' fill='currentColor'>\(dots)</svg>"
    }
}
struct MacAccessDotArt: View {
    var scene: MacAccessArt
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Canvas { context, size in
            let rows = scene.rows, width = rows.first?.count ?? 1
            let cell = floor(min(5, size.width / CGFloat(width), size.height / CGFloat(rows.count)) * displayScale) / displayScale
            let square = floor(cell * 0.6 * displayScale) / displayScale
            let x0 = (size.width - CGFloat(width) * cell) / 2, y0 = (size.height - CGFloat(rows.count) * cell) / 2
            for (y, row) in rows.enumerated() { for (x, bit) in row.enumerated() where bit == "1" {
                let rect = CGRect(x: floor((x0 + CGFloat(x) * cell) * displayScale) / displayScale, y: floor((y0 + CGFloat(y) * cell) * displayScale) / displayScale, width: square, height: square)
                context.fill(Path(rect), with: .color(.primary))
            } }
        }.accessibilityHidden(true)
    }
}
