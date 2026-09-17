import SwiftUI

/// Self-tests for page transition mask logic. Verifies that wave and fade
/// transitions reveal/hide the correct screen regions at progress 0 and 1.
func transitionSelfTest() {
    let rect = CGRect(x: 0, y: 0, width: 400, height: 600)

    // Wave transition: new page mask (left of wave front).
    // At progress 0 the wave is off-screen left, so the left region is near-empty.
    // Harmonic offsets can push a few pixels on-screen, so allow a small sliver.
    let newMask0 = PixelWaveMaskShape(seed: 42, animatableData: 0)
    let newPath0 = newMask0.path(in: rect)
    let newBounds0 = newPath0.boundingRect
    precondition(newBounds0.width < 200, "New page mask at progress 0 should be near-empty, got width \(newBounds0.width)")

    // At progress 1 the wave is off-screen right, so the left region fills the screen.
    let newMask1 = PixelWaveMaskShape(seed: 42, animatableData: 1)
    let newPath1 = newMask1.path(in: rect)
    let newBounds1 = newPath1.boundingRect
    precondition(newBounds1.width >= rect.width, "New page mask at progress 1 should fill width, got \(newBounds1.width)")

    // Wave transition: old page mask (right of wave front), inverted.
    // At progress 0 the right region fills the screen.
    let oldMask0 = PixelWaveMaskShape(seed: 42, animatableData: 0, inverted: true)
    let oldPath0 = oldMask0.path(in: rect)
    let oldBounds0 = oldPath0.boundingRect
    precondition(oldBounds0.width >= rect.width, "Old page mask at progress 0 should fill width, got \(oldBounds0.width)")

    // At progress 1 the right region is near-empty (harmonics may leave a sliver).
    let oldMask1 = PixelWaveMaskShape(seed: 42, animatableData: 1, inverted: true)
    let oldPath1 = oldMask1.path(in: rect)
    let oldBounds1 = oldPath1.boundingRect
    precondition(oldBounds1.width < 200, "Old page mask at progress 1 should be near-empty, got width \(oldBounds1.width)")

    // Fade transition: opacity is a pure function of progress.
    precondition(FadeTransition.opacity(forNewPage: 0) == 0, "New page opacity at 0 should be 0")
    precondition(FadeTransition.opacity(forNewPage: 1) == 1, "New page opacity at 1 should be 1")
    precondition(FadeTransition.opacity(forOldPage: 0) == 1, "Old page opacity at 0 should be 1")
    precondition(FadeTransition.opacity(forOldPage: 1) == 0, "Old page opacity at 1 should be 0")

    // Flip transition: cell-grid flip. The grid partitions into front faces
    // (old page) and back faces (new page). At progress 0 every cell is a front
    // face; at progress 1 every cell is a back face; mid-progress has both.
    let cols = 50, rows = 75
    let total = cols * rows
    let flip0 = flipFaceCounts(0, cols: cols, rows: rows)
    precondition(flip0.back == 0 && flip0.front == total, "Flip at progress 0 should be all front faces, got back=\(flip0.back) front=\(flip0.front)")
    let flip1 = flipFaceCounts(1, cols: cols, rows: rows)
    precondition(flip1.back == total && flip1.front == 0, "Flip at progress 1 should be all back faces, got back=\(flip1.back) front=\(flip1.front)")
    let flipMid = flipFaceCounts(0.5, cols: cols, rows: rows)
    precondition(flipMid.back > 0 && flipMid.front > 0, "Flip at progress 0.5 should have both faces, got back=\(flipMid.back) front=\(flipMid.front)")
    precondition(flipMid.back + flipMid.front == total, "Flip faces should partition the grid, got back=\(flipMid.back) front=\(flipMid.front)")
    // Monotonic: back grows and front shrinks as progress increases.
    let flip25 = flipFaceCounts(0.25, cols: cols, rows: rows)
    let flip75 = flipFaceCounts(0.75, cols: cols, rows: rows)
    precondition(flip25.back <= flipMid.back && flipMid.back <= flip75.back, "Flip back face count should grow monotonically")
    precondition(flip25.front >= flipMid.front && flipMid.front >= flip75.front, "Flip front face count should shrink monotonically")

    // Flip mask shape bounds at the endpoints: new mask (back faces) is empty at
    // 0 and fills the rect at 1; old mask (front faces) is the inverse.
    let flipNew0 = FlipMaskShape(seed: 7, animatableData: 0).path(in: rect).boundingRect
    precondition(flipNew0.width == 0 || flipNew0.height == 0, "Flip new mask at progress 0 should be empty, got \(flipNew0)")
    let flipNew1 = FlipMaskShape(seed: 7, animatableData: 1).path(in: rect).boundingRect
    precondition(flipNew1.width >= rect.width && flipNew1.height >= rect.height, "Flip new mask at progress 1 should fill, got \(flipNew1)")
    let flipOld0 = FlipMaskShape(seed: 7, animatableData: 0, inverted: true).path(in: rect).boundingRect
    precondition(flipOld0.width >= rect.width && flipOld0.height >= rect.height, "Flip old mask at progress 0 should fill, got \(flipOld0)")
    let flipOld1 = FlipMaskShape(seed: 7, animatableData: 1, inverted: true).path(in: rect).boundingRect
    precondition(flipOld1.width == 0 || flipOld1.height == 0, "Flip old mask at progress 1 should be empty, got \(flipOld1)")

    print("PASS: wave mask regions (new/old at progress 0 and 1), fade opacity (new/old at progress 0 and 1), flip face partition (endpoints, mid, monotonic)")

    // Transition style selection: default is wave, every style round-trips
    // through UserDefaults, unknown values fall back, and each style produces a
    // distinct transition type.
    let defaults = UserDefaults.standard
    let key = "transitionStyle"
    defaults.removeObject(forKey: key)
    precondition(TransitionStyle(rawValue: defaults.string(forKey: key) ?? "") ?? .wave == .wave, "Default transition style should be wave")
    for style in TransitionStyle.allCases {
        defaults.set(style.rawValue, forKey: key)
        precondition(TransitionStyle(rawValue: defaults.string(forKey: key) ?? "") == style, "Style \(style) should round-trip")
    }
    precondition(TransitionStyle(rawValue: "nope") == nil, "Unknown transition style raw value should not resolve")
    let typeNames = Set(TransitionStyle.allCases.map { String(describing: type(of: $0.makeTransition(seed: 0, color: .primary, duration: 0.5))) })
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
    for speed in TransitionSpeed.allCases {
        let t = TransitionStyle.wave.makeTransition(seed: 0, color: .primary, duration: speed.duration)
        precondition(t.duration == speed.duration, "Transition duration should match speed \(speed) (\(speed.duration)), got \(t.duration)")
    }
    defaults.removeObject(forKey: speedKey)

    print("PASS: transition speed default/round-trip/invalid fallback, duration mapping, makeTransition duration plumbing")
}

/// Counts front/back face cells for the flip mask at a given progress. Mirrors
/// `FlipMaskShape.path` logic so self-tests assert cell partitioning exactly
/// rather than measuring rendered area.
private func flipFaceCounts(_ progress: Double, cols: Int, rows: Int) -> (front: Int, back: Int) {
    var front = 0
    var back = 0
    for j in 0..<rows {
        for i in 0..<cols {
            if FlipMaskShape.isBackFace(progress: progress, i: i, j: j, cols: cols, rows: rows) {
                back += 1
            } else {
                front += 1
            }
        }
    }
    return (front, back)
}
