/// A diatonic letter name.
public enum Step: String, Sendable, Hashable, CaseIterable {
    case C, D, E, F, G, A, B

    /// Semitones above C within the octave.
    public var semitone: Int {
        switch self {
        case .C: 0
        case .D: 2
        case .E: 4
        case .F: 5
        case .G: 7
        case .A: 9
        case .B: 11
        }
    }
}

/// A written pitch: letter, alteration and octave (4 = the octave of middle C).
public struct Pitch: Sendable, Hashable {
    public var step: Step
    /// Semitones of alteration; MusicXML allows fractions for microtones.
    public var alter: Double
    public var octave: Int

    public init(step: Step, alter: Double = 0, octave: Int) {
        self.step = step
        self.alter = alter
        self.octave = octave
    }

    /// The alteration rounded to whole semitones.
    public var semitoneAlter: Int { Int(alter.rounded()) }
    /// MIDI note number (middle C = 60).
    public var midi: Int { (octave + 1) * 12 + step.semitone + semitoneAlter }
    /// The letter name alone: "C", "F", ...
    public var letter: String { step.rawValue }
    /// Letter plus accidental, without octave: "F#", "Bb", "Cx".
    public var spelling: String {
        switch semitoneAlter {
        case 0: letter
        case 1: letter + "#"
        case 2: letter + "x"
        case -1: letter + "b"
        case -2: letter + "bb"
        case let a: letter + (a > 0 ? "+\(a)" : "\(a)")
        }
    }
}
