import Testing
@testable import TiesCore

@Test func packageLoads() {
    #expect(TiesCore.version == "0.1.0")
}
