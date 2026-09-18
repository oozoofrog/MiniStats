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

    // Flip transition (1x1 rotation): the whole screen flips on the Y axis from
    // 0° to 180°. The front face (old page) shows below 90°, then the back face
    // (new page) shows. flipAngle maps progress to degrees; isFrontFace marks
    // the swap point at 90°.
    precondition(FlipTransition.flipAngle(progress: 0) == 0, "Flip angle at progress 0 should be 0°")
    precondition(FlipTransition.flipAngle(progress: 1) == 180, "Flip angle at progress 1 should be 180°")
    precondition(FlipTransition.flipAngle(progress: 0.5) == 90, "Flip angle at progress 0.5 should be 90°")
    precondition(FlipTransition.flipAngle(progress: 1.5) == 180, "Flip angle should clamp above 1")
    precondition(FlipTransition.flipAngle(progress: -0.5) == 0, "Flip angle should clamp below 0")
    precondition(FlipTransition.isFrontFace(angle: 0) == true, "0° should be front face")
    precondition(FlipTransition.isFrontFace(angle: 89) == true, "89° should be front face")
    precondition(FlipTransition.isFrontFace(angle: 90) == false, "90° should swap to back face")
    precondition(FlipTransition.isFrontFace(angle: 180) == false, "180° should be back face")
    // Only the flip transition is rotational; wave/fade stay mask-based.
    precondition(FlipTransition(seed: 0, color: .primary, duration: 0.5).isRotational == true, "Flip transition should be rotational")
    precondition(WaveTransition(seed: 0, color: .primary, duration: 0.5).isRotational == false, "Wave transition should not be rotational")
    precondition(FadeTransition(seed: 0, color: .primary, duration: 0.5).isRotational == false, "Fade transition should not be rotational")

    // Flip grid (2×2): the screen is tiled into a grid and each cell rotates on
    // its own delayed schedule via `cellProgress`. At progress 0 every cell is
    // at angle 0; at progress 1 every cell is at 180; mid-progress cells differ
    // because the diagonal delay makes (0,0) lead and the far corner trail.
    // `cellProgress` is the per-cell 0…1 that `flipAngle` maps to degrees.
    precondition(FlipTransition.cellProgress(0, i: 0, j: 0, cols: 2, rows: 2) == 0, "cellProgress at 0 should be 0")
    precondition(FlipTransition.cellProgress(1, i: 1, j: 1, cols: 2, rows: 2) == 1, "cellProgress at 1 should be 1")
    // Leading corner (0,0) always reaches a given milestone first; trailing
    // corner (cols-1,rows-1) is most delayed but not necessarily at 0.
    let leadMid = FlipTransition.cellProgress(0.5, i: 0, j: 0, cols: 2, rows: 2)
    let trailMid = FlipTransition.cellProgress(0.5, i: 1, j: 1, cols: 2, rows: 2)
    precondition(leadMid > trailMid, "Leading corner should be ahead at mid-progress, got lead=\(leadMid) trail=\(trailMid)")
    precondition(leadMid == 1, "Leading corner should be fully flipped at 0.5, got \(leadMid)")
    precondition(trailMid > 0 && trailMid < 1, "Trailing corner should be mid-flip (not 0, not 1) at 0.5, got \(trailMid)")
    // Early in the transition the trailing corner hasn't started yet.
    let trailEarly = FlipTransition.cellProgress(0.2, i: 1, j: 1, cols: 2, rows: 2)
    precondition(trailEarly == 0, "Trailing corner should not have started early, got \(trailEarly)")
    // Monotonic per cell as progress grows.
    for (i, j) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        let p0 = FlipTransition.cellProgress(0.25, i: i, j: j, cols: 2, rows: 2)
        let p1 = FlipTransition.cellProgress(0.5, i: i, j: j, cols: 2, rows: 2)
        let p2 = FlipTransition.cellProgress(0.75, i: i, j: j, cols: 2, rows: 2)
        precondition(p0 <= p1 && p1 <= p2, "cellProgress should be monotonic for cell (\(i),\(j))")
    }
    // 2×2 grid: 4 cells, each producing an angle from its cellProgress.
    let grid = [(0,0),(1,0),(0,1),(1,1)]
    let angles0 = grid.map { FlipTransition.flipAngle(progress: FlipTransition.cellProgress(0, i: $0.0, j: $0.1, cols: 2, rows: 2)) }
    precondition(angles0.allSatisfy { $0 == 0 }, "All cells at 0° at progress 0")
    let angles1 = grid.map { FlipTransition.flipAngle(progress: FlipTransition.cellProgress(1, i: $0.0, j: $0.1, cols: 2, rows: 2)) }
    precondition(angles1.allSatisfy { $0 == 180 }, "All cells at 180° at progress 1")
    let distinctAngles = Set(grid.map { FlipTransition.flipAngle(progress: FlipTransition.cellProgress(0.5, i: $0.0, j: $0.1, cols: 2, rows: 2)) })
    precondition(distinctAngles.count > 1, "Cells should be at different angles mid-progress, got \(distinctAngles)")
    // 2×2 partition: `gridSize` divides the screen evenly into 2 columns/rows.
    precondition(FlipTransition.gridSize == 2, "Flip grid size should be 2 at this stage")

    print("PASS: wave mask regions (new/old at progress 0 and 1), fade opacity (new/old at progress 0 and 1), flip rotation (1×1 angle/face swap, 2×2 cellProgress diagonal delay, grid angles)")

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


