import SwiftUI

/// Self-tests for page transition mask logic. Verifies that wave and fade
/// transitions reveal/hide the correct screen regions at progress 0 and 1.
func transitionSelfTest() {
    let rect = CGRect(x: 0, y: 0, width: 400, height: 600)

    var pages = TransitionPages(initial: .overview)
    precondition(pages.request(.storage))
    precondition(pages.previous == .overview && pages.visible == .storage)
    precondition(!pages.request(.cpu))
    precondition(!pages.request(.settings))
    precondition(pages.visible == .storage && pages.requested == .settings)
    pages.finish()
    precondition(pages.beginPending())
    precondition(pages.previous == .storage && pages.visible == .settings)
    pages.finish()
    precondition(!pages.beginPending())
    precondition(pages.previous == nil && pages.visible == .settings)

    // A request back to the current target cancels the queued page.
    pages = TransitionPages(initial: .overview)
    precondition(pages.request(.storage))
    precondition(!pages.request(.settings))
    precondition(!pages.request(.storage))
    pages.finish()
    precondition(!pages.beginPending() && pages.visible == .storage)

    // CPU and Memory are separate targets; a rapid return must not replace
    // the incoming metric page while its transition is still running.
    pages = TransitionPages(initial: .cpu)
    precondition(pages.request(.memory))
    precondition(pages.previous == .cpu && pages.visible == .memory)
    precondition(!pages.request(.cpu))
    precondition(pages.visible == .memory && pages.requested == .cpu)
    pages.finish()
    precondition(pages.beginPending())
    precondition(pages.previous == .memory && pages.visible == .cpu)
    pages.finish()
    precondition(!pages.beginPending())
    print("PASS: independent CPU/Memory page transitions and rapid-return queue")

    // Both masks must cover their exact endpoints for every seed, including
    // the old fixed seed 0. Check a non-grid-aligned height as well.
    for seed in [0, 1, 42, 123_456] {
        for height in [rect.height, 601] {
            let region = CGRect(x: 0, y: 0, width: rect.width, height: height)
            for y in [1.0, Double(height / 2), Double(height - 1)] {
                for x in [1.0, Double(rect.width - 1)] {
                    let point = CGPoint(x: x, y: y)
                    precondition(!PixelWaveMaskShape(seed: seed, animatableData: 0).path(in: region).contains(point))
                    precondition(PixelWaveMaskShape(seed: seed, animatableData: 0, inverted: true).path(in: region).contains(point))
                    precondition(PixelWaveMaskShape(seed: seed, animatableData: 1).path(in: region).contains(point))
                    precondition(!PixelWaveMaskShape(seed: seed, animatableData: 1, inverted: true).path(in: region).contains(point))
                }
            }
        }
        let newMiddle = PixelWaveMaskShape(seed: seed, animatableData: 0.5).path(in: rect)
        let oldMiddle = PixelWaveMaskShape(seed: seed, animatableData: 0.5, inverted: true).path(in: rect)
        for y in [1.0, 301, 597] {
            for x in [1.0, 101, 201, 301, 397] {
                let point = CGPoint(x: x, y: y)
                precondition(newMiddle.contains(point) != oldMiddle.contains(point), "Wave masks must meet without gaps")
            }
        }
    }
    let waveA = PixelTransition.waveFront(y: 280, progress: 0.5, width: rect.width, harmonics: PixelTransition.harmonics(seed: 1))
    let waveB = PixelTransition.waveFront(y: 280, progress: 0.5, width: rect.width, harmonics: PixelTransition.harmonics(seed: 42))
    precondition(waveA != waveB, "Different seeds must produce different wave fronts")

    // Dither fade: every block belongs to exactly one page at each stage.
    let ditherRect = CGRect(x: 0, y: 0, width: 32, height: 32)
    var halfRevealed = 0
    for row in 0..<4 {
        for col in 0..<4 {
            let point = CGPoint(x: CGFloat(col) * PixelFadeMask.cellSize + 4,
                                y: CGFloat(row) * PixelFadeMask.cellSize + 4)
            for p in [0.0, 0.5, 1.0] {
                let newVisible = PixelFadeMask(animatableData: p).path(in: ditherRect).contains(point)
                let oldVisible = PixelFadeMask(animatableData: p, inverted: true).path(in: ditherRect).contains(point)
                precondition(newVisible != oldVisible, "Fade masks must be complementary at \(p)")
                if p == 0 { precondition(!newVisible) }
                if p == 1 { precondition(newVisible) }
                if p == 0.5 && newVisible { halfRevealed += 1 }
            }
        }
    }
    precondition(halfRevealed == 8, "Half progress must reveal half the dither cells")

    // A flip tile contains two square faces around a horizontal hinge. The
    // old upper face folds down, then the new lower face opens downward.
    let panelGrid = FlipTransition.grid(in: CGSize(width: 400, height: 600))!
    precondition(panelGrid.columns == 32 && panelGrid.rows == 24 && panelGrid.faceSize == 12.5,
                 "The 400×600 panel must use 768 tiles with 1536 square faces")
    precondition(panelGrid.columns * panelGrid.rows == 768)
    precondition(panelGrid.origin == .zero)
    precondition(FlipTransition.grid(in: .zero) == nil)
    precondition(FlipTransition.grid(in: CGSize(width: CGFloat.infinity, height: 200)) == nil)
    for size in [CGSize(width: 375, height: 667), CGSize(width: 200, height: 120),
                 CGSize(width: 10, height: 200), CGSize(width: 301, height: 299)] {
        let grid = FlipTransition.grid(in: size)!
        let coveredWidth = CGFloat(grid.columns) * grid.faceSize
        let coveredHeight = CGFloat(grid.rows) * grid.faceSize * 2
        precondition(grid.faceSize > 0 && grid.origin.x >= -0.000001 && grid.origin.y >= -0.000001)
        precondition(grid.origin.x * 2 + coveredWidth <= size.width + 0.000001)
        precondition(grid.origin.y * 2 + coveredHeight <= size.height + 0.000001,
                     "Only complete pairs of square faces may be drawn")
        precondition(size.width - coveredWidth < grid.faceSize + 0.000001)
        precondition(size.height - coveredHeight < grid.faceSize * 2 + 0.000001,
                     "Any ungridded margin must be narrower than one tile")
    }
    precondition(FlipTransition.flapScale(progress: 0) == 1)
    precondition(abs(FlipTransition.flapScale(progress: 0.25) - sqrt(0.5)) < 0.000001)
    precondition(abs(FlipTransition.flapScale(progress: 0.5)) < 0.000001)
    precondition(abs(FlipTransition.flapScale(progress: 0.75) - sqrt(0.5)) < 0.000001)
    precondition(FlipTransition.flapScale(progress: 1) == 1)
    precondition(FlipTransition.flapScale(progress: -1) == 1)
    precondition(FlipTransition.flapScale(progress: 2) == 1)
    let flipCells = (0..<6).flatMap { row in (0..<6).map { (row, $0) } }
    let delays = flipCells.map { FlipTransition.startDelay(row: $0.0, column: $0.1, seed: 7) }
    precondition(Set(delays).count == flipCells.count, "Pixels should have distinct start times")
    precondition(delays.allSatisfy { (0..<0.55).contains($0) }, "Every pixel must have time to finish")
    precondition(delays == flipCells.map { FlipTransition.startDelay(row: $0.0, column: $0.1, seed: 7) },
                 "Pixel timing must stay fixed across frames")
    precondition(delays != flipCells.map { FlipTransition.startDelay(row: $0.0, column: $0.1, seed: 8) },
                 "A new transition seed should change pixel timing")
    for (row, column) in flipCells {
        let delay = FlipTransition.startDelay(row: row, column: column, seed: 7)
        precondition(FlipTransition.cellProgress(0, row: row, column: column, seed: 7) == 0)
        precondition(FlipTransition.cellProgress(delay, row: row, column: column, seed: 7) == 0)
        precondition(FlipTransition.cellProgress(delay + 0.45, row: row, column: column, seed: 7) > 0.999,
                     "Each pixel should finish after its own fixed-duration flip")
        precondition(FlipTransition.cellProgress(1, row: row, column: column, seed: 7) == 1)
    }
    let inFlight = flipCells.map { FlipTransition.cellProgress(0.6, row: $0.0, column: $0.1, seed: 7) }
    precondition(inFlight.contains(1) && inFlight.contains(where: { $0 < 1 }),
                 "At an intermediate time some pixels should finish while others flip")
    // Flip masks cover each square face exactly once without resolving the
    // actual page hierarchy inside Canvas (which can include AppKit controls).
    let flipRect = CGRect(x: 0, y: 0, width: 200, height: 120)
    let flipGrid = FlipTransition.grid(in: flipRect.size)!
    for p in [0.0, 0.2, 0.5, 0.8, 1.0] {
        let oldMask = FlipPixelMaskShape(seed: 7, animatableData: p, inverted: true).path(in: flipRect)
        let newMask = FlipPixelMaskShape(seed: 7, animatableData: p).path(in: flipRect)
        for row in 0..<flipGrid.rows {
            for column in 0..<flipGrid.columns {
                let x = flipGrid.origin.x + (CGFloat(column) + 0.37) * flipGrid.faceSize
                for faceY in [0.17, 0.41, 0.73, 1.18, 1.39, 1.77] {
                    let y = flipGrid.origin.y + (CGFloat(row) * 2 + faceY) * flipGrid.faceSize
                    let point = CGPoint(x: x, y: y)
                    precondition(oldMask.contains(point) != newMask.contains(point),
                                 "Old and new flip masks must be complementary at progress \(p)")
                }
            }
        }
    }
    let margin = FlipMarginMaskShape().path(in: CGRect(x: 0, y: 0, width: 310, height: 430))
    precondition(margin.contains(CGPoint(x: 1, y: 215)))
    precondition(!margin.contains(CGPoint(x: 155, y: 215)))

    print("PASS: wave mask endpoints and seed variation, complementary dissolve and flip masks, seeded per-pixel timing")

    // Transition style selection: default is wave, every style round-trips
    // through UserDefaults, unknown values fall back, and each style produces a
    // distinct transition type.
    let suiteName = "RetroStats.TransitionSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "transitionStyle"
    defaults.removeObject(forKey: key)
    precondition(TransitionStyle(rawValue: defaults.string(forKey: key) ?? "") ?? .wave == .wave, "Default transition style should be wave")
    for style in TransitionStyle.allCases {
        defaults.set(style.rawValue, forKey: key)
        precondition(TransitionStyle(rawValue: defaults.string(forKey: key) ?? "") == style, "Style \(style) should round-trip")
    }
    precondition(TransitionStyle(rawValue: "nope") == nil, "Unknown transition style raw value should not resolve")
    let typeNames = Set(TransitionStyle.allCases.map { String(describing: type(of: $0.makeTransition(color: .primary, duration: 0.5))) })
    precondition(typeNames.count == TransitionStyle.allCases.count, "Each style should produce a distinct transition type, got \(typeNames)")
    defaults.removeObject(forKey: key)

    print("PASS: transition style default/round-trip/invalid fallback, distinct transition types")

    // Transition speed: default is normal, every speed round-trips through
    // UserDefaults, unknown values fall back, the duration mapping is strictly
    // ordered (slower = longer), and makeTransition threads the duration into
    // the transition instance so TransitionContainer and the overlay share it.
    let speedKey = "transitionSpeed"
    defaults.removeObject(forKey: speedKey)
    precondition(TransitionSpeed(rawValue: defaults.string(forKey: speedKey) ?? "") ?? .normal == .normal, "Default transition speed should be normal")
    for speed in TransitionSpeed.allCases {
        defaults.set(speed.rawValue, forKey: speedKey)
        precondition(TransitionSpeed(rawValue: defaults.string(forKey: speedKey) ?? "") == speed, "Speed \(speed) should round-trip")
    }
    precondition(TransitionSpeed(rawValue: "nope") == nil, "Unknown transition speed raw value should not resolve")
    precondition(TransitionSpeed.slow.duration > TransitionSpeed.normal.duration, "Slow duration should be longer than normal")
    precondition(TransitionSpeed.normal.duration > TransitionSpeed.fast.duration, "Normal duration should be longer than fast")
    precondition(TransitionSpeed.slow.duration == 1.0 && TransitionSpeed.normal.duration == 0.5 && TransitionSpeed.fast.duration == 0.25)
    for speed in TransitionSpeed.allCases {
        let t = TransitionStyle.wave.makeTransition(color: .primary, duration: speed.duration)
        precondition(t.duration == speed.duration, "Transition duration should match speed \(speed) (\(speed.duration)), got \(t.duration)")
    }
    defaults.removeObject(forKey: speedKey)

    print("PASS: transition speed default/round-trip/invalid fallback, duration mapping, makeTransition duration plumbing")
}
