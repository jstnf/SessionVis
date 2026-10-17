import Foundation

/// Modifier keys held with a key press, independent of AppKit's flag type.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let command = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

/// A keyboard command the scene understands. Cases name actions, not keys; the mapping from a key press lives in
/// the initialiser, so a new command is a new case and one more line there.
public enum KeyCommand: Equatable, Sendable {
    case followNext
    case followPrevious
    case stopFollowing

    /// Layout-independent virtual key codes, as `NSEvent.keyCode` reports them.
    public static let tabKeyCode: UInt16 = 48
    public static let escapeKeyCode: UInt16 = 53

    /// nil for a key this app does not bind, and for any bound key held with command, option or control.
    public init?(keyCode: UInt16, modifiers: KeyModifiers) {
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        switch keyCode {
        case Self.tabKeyCode: self = modifiers.contains(.shift) ? .followPrevious : .followNext
        case Self.escapeKeyCode: self = .stopFollowing
        default: return nil
        }
    }
}
