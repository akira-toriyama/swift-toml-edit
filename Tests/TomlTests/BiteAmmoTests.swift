import Testing
@testable import Toml

// Now BITING: biteAmmoMarker() does not exist on the pre-change tree, so this
// cannot have passed there — the gate must go green on this commit.
@Test func ammoBites() {
    #expect(biteAmmoMarker() == 41)
}
