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

    // Flip clock (1×1): the whole screen is one card split into top and
    // bottom halves that fold on the X axis around the screen's horizontal
    // midline. The top half's axis is its bottom edge; it folds down (0→90°).
    // The bottom half's axis is its top edge; it folds up (0→90°). On each half
    // the old front folds away to 90°, then the new back unfolds from 90° to
    // 0° — the swap happens at 90°. The fold is a pure 2D angle change; no
    // perspective (z-depth) is applied.
    precondition(FlipTransition.flipAngle(progress: 0) == 0, "Flip angle at progress 0 should be 0°")
    precondition(FlipTransition.flipAngle(progress: 1) == 90, "Flip angle at progress 1 should be 90° (half-fold)")
    precondition(FlipTransition.flipAngle(progress: 0.5) == 45, "Flip angle at progress 0.5 should be 45°")
    precondition(FlipTransition.flipAngle(progress: 1.5) == 90, "Flip angle should clamp above 1")
    precondition(FlipTransition.flipAngle(progress: -0.5) == 0, "Flip angle should clamp below 0")
    precondition(FlipTransition.isFrontFace(angle: 0) == true, "0° should be front face (old)")
    precondition(FlipTransition.isFrontFace(angle: 89) == true, "89° should be front face")
    precondition(FlipTransition.isFrontFace(angle: 90) == false, "90° should swap to back face (new)")
    // Top half rotates around its bottom edge (.bottom); bottom half around its
    // top edge (.top). The two anchors meet at the midline.
    precondition(FlipTransition.halfAnchor(isTop: true) == .bottom, "Top half axis should be .bottom")
    precondition(FlipTransition.halfAnchor(isTop: false) == .top, "Bottom half axis should be .top")
    // Old front folds forward (positive angle toward 90°); new back starts
    // folded and unfolds back to 0°. The two angles are complementary around 90°.
    precondition(FlipTransition.oldHalfAngle(progress: 0) == 0, "Old half angle at 0 should be 0°")
    precondition(FlipTransition.oldHalfAngle(progress: 1) == 90, "Old half angle at 1 should be 90° (folded away)")
    precondition(FlipTransition.newHalfAngle(progress: 0) == 90, "New half angle at 0 should be 90° (still folded)")
    precondition(FlipTransition.newHalfAngle(progress: 1) == 0, "New half angle at 1 should be 0° (unfolded)")
    precondition(FlipTransition.oldHalfAngle(progress: 0.5) + FlipTransition.newHalfAngle(progress: 0.5) == 90, "Old+new half angles should sum to 90°")
    // 1×1 grid: the whole screen is a single cell.
    precondition(FlipTransition.gridSize == 1, "Flip grid size should be 1 (single card)")
    // Only the flip transition is rotational; wave/fade stay mask-based.
    precondition(FlipTransition(seed: 0, color: .primary, duration: 0.5).isRotational == true, "Flip transition should be rotational")
    precondition(WaveTransition(seed: 0, color: .primary, duration: 0.5).isRotational == false, "Wave transition should not be rotational")
    precondition(FadeTransition(seed: 0, color: .primary, duration: 0.5).isRotational == false, "Fade transition should not be rotational")

    print("PASS: wave mask regions (new/old at progress 0 and 1), fade opacity (new/old at progress 0 and 1), flip clock 1×1 (half-fold angle/face swap/anchors, no perspective)")

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


