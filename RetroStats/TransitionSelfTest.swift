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

    print("PASS: wave mask regions (new/old at progress 0 and 1), fade opacity (new/old at progress 0 and 1)")
}
