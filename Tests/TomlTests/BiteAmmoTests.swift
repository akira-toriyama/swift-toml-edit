import Testing
@testable import Toml

// Deliberately VACUOUS: true on the pre-change tree too. swift-bite must go
// red on this commit — that red is the point of the ammunition.
@Test func ammoVacuous() {
    #expect(1 + 1 == 2)
}
