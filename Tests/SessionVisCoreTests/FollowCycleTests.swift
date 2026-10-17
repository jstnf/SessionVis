import Testing
@testable import SessionVisCore

@Suite struct FollowCycleTests {
    let a = AgentID("a"), b = AgentID("b"), c = AgentID("c")
    var order: [AgentID] { [a, b, c] }

    @Test func emptyOrderGivesNil() {
        #expect(FollowCycle.next(after: nil, in: [], forward: true) == nil)
        #expect(FollowCycle.next(after: a, in: [], forward: false) == nil)
    }

    @Test func nilCurrentStartsAtEitherEnd() {
        #expect(FollowCycle.next(after: nil, in: order, forward: true) == a)
        #expect(FollowCycle.next(after: nil, in: order, forward: false) == c)
    }

    @Test func stepsAndWrapsBothWays() {
        #expect(FollowCycle.next(after: a, in: order, forward: true) == b)
        #expect(FollowCycle.next(after: c, in: order, forward: true) == a)
        #expect(FollowCycle.next(after: b, in: order, forward: false) == a)
        #expect(FollowCycle.next(after: a, in: order, forward: false) == c)
        #expect(FollowCycle.next(after: a, in: [a], forward: true) == a)
    }

    @Test func unknownCurrentStartsAtEitherEnd() {
        let z = AgentID("z")
        #expect(FollowCycle.next(after: z, in: order, forward: true) == a)
        #expect(FollowCycle.next(after: z, in: order, forward: false) == c)
    }

    @Test func endedFollowedMainContinuesFromItsSlot() {
        let d = AgentID("d")
        // b (slot 1) ended: the live order is now [a, c, d]
        #expect(FollowCycle.next(after: b, lastIndex: 1, in: [a, c, d], forward: true) == c)
        #expect(FollowCycle.next(after: b, lastIndex: 1, in: [a, c, d], forward: false) == a)
        // the last slot ended: forward wraps to the first, backward takes the new last
        #expect(FollowCycle.next(after: d, lastIndex: 3, in: [a, b, c], forward: true) == a)
        #expect(FollowCycle.next(after: d, lastIndex: 3, in: [a, b, c], forward: false) == c)
        // the first slot ended: backward wraps to the last
        #expect(FollowCycle.next(after: a, lastIndex: 0, in: [b, c, d], forward: false) == d)
    }

    @Test func missingLastIndexBehavesAsBefore() {
        let z = AgentID("z")
        #expect(FollowCycle.next(after: z, lastIndex: nil, in: order, forward: true) == a)
        #expect(FollowCycle.next(after: z, lastIndex: nil, in: order, forward: false) == c)
        #expect(FollowCycle.next(after: b, lastIndex: nil, in: order, forward: true) == c)
    }
}
