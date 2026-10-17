import Testing
@testable import SessionVisCore

@Suite struct KeyCommandTests {
    @Test func tabAndShiftTabCycle() {
        #expect(KeyCommand(keyCode: KeyCommand.tabKeyCode, modifiers: []) == .followNext)
        #expect(KeyCommand(keyCode: KeyCommand.tabKeyCode, modifiers: [.shift]) == .followPrevious)
    }

    @Test func escapeStopsFollowingWithOrWithoutShift() {
        #expect(KeyCommand(keyCode: KeyCommand.escapeKeyCode, modifiers: []) == .stopFollowing)
        #expect(KeyCommand(keyCode: KeyCommand.escapeKeyCode, modifiers: [.shift]) == .stopFollowing)
    }

    @Test func boundKeysWithOtherModifiersFallThrough() {
        for m: KeyModifiers in [[.command], [.option], [.control], [.shift, .command], [.command, .option]] {
            #expect(KeyCommand(keyCode: KeyCommand.tabKeyCode, modifiers: m) == nil, "\(m.rawValue)")
            #expect(KeyCommand(keyCode: KeyCommand.escapeKeyCode, modifiers: m) == nil, "\(m.rawValue)")
        }
    }

    @Test func unboundKeysAreNil() {
        for code: UInt16 in [0, 1, 36, 49, 123, 126] {
            #expect(KeyCommand(keyCode: code, modifiers: []) == nil, "\(code)")
            #expect(KeyCommand(keyCode: code, modifiers: [.shift]) == nil, "\(code)")
        }
    }
}
