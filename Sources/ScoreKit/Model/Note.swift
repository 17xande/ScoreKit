/// Identifies a note across the whole score: assigned in document order
/// (part by part, measure by measure), starting at 0.
public struct NoteID: Sendable, Hashable, Comparable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (a: NoteID, b: NoteID) -> Bool { a.value < b.value }
}

/// A written note value (`<type>`).
public enum NoteValue: String, Sendable, Hashable, CaseIterable {
    case breve, whole, half, quarter, eighth, sixteenth, thirtySecond, sixtyFourth, oneTwentyEighth

    /// From a MusicXML `<type>` / `<beat-unit>` name ("16th", "quarter", ...).
    public init?(xml: String) {
        switch xml {
        case "breve": self = .breve
        case "whole": self = .whole
        case "half": self = .half
        case "quarter": self = .quarter
        case "eighth": self = .eighth
        case "16th": self = .sixteenth
        case "32nd": self = .thirtySecond
        case "64th": self = .sixtyFourth
        case "128th": self = .oneTwentyEighth
        default: return nil
        }
    }

    /// Length in quarter notes, undotted.
    public var quarters: Rational {
        switch self {
        case .breve: Rational(8)
        case .whole: Rational(4)
        case .half: Rational(2)
        case .quarter: Rational(1)
        case .eighth: Rational(1, 2)
        case .sixteenth: Rational(1, 4)
        case .thirtySecond: Rational(1, 8)
        case .sixtyFourth: Rational(1, 16)
        case .oneTwentyEighth: Rational(1, 32)
        }
    }
}

public enum Stem: String, Sendable, Hashable {
    case up, down, none, double
}

public enum BeamValue: Sendable, Hashable {
    case begin, `continue`, end, forwardHook, backwardHook
}

/// One beam line on a note; `number` 1 is the outermost (eighth) beam.
public struct Beam: Sendable, Hashable {
    public var number: Int
    public var value: BeamValue
}

/// `<time-modification>`: `actual` notes in the time of `normal` (a triplet is 3 in 2).
public struct TimeModification: Sendable, Hashable {
    public var actual: Int
    public var normal: Int
}

/// The `cautionary`, `editorial`, `parentheses` and `bracket` attributes of `<accidental>`.
public struct AccidentalMarks: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let cautionary = AccidentalMarks(rawValue: 1)
    public static let editorial = AccidentalMarks(rawValue: 2)
    public static let parentheses = AccidentalMarks(rawValue: 4)
    public static let bracket = AccidentalMarks(rawValue: 8)
}

/// A `<notations><tuplet>` element.
public struct TupletMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case start, stop }
    public var kind: Kind
    public var number: Int?
    /// `bracket="yes"/"no"`, nil when absent.
    public var bracket: Bool?
    /// `show-number`: "actual", "both" or "none".
    public var showNumber: String?
}

public struct Grace: Sendable, Hashable {
    /// Drawn with a slash (acciaccatura).
    public var slash: Bool
}

public struct Note: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case pitched(Pitch)
        /// `measureRest` is `<rest measure="yes"/>`; the display pair is where to draw it.
        case rest(measureRest: Bool, displayStep: Step?, displayOctave: Int?)
        case unpitched(displayStep: Step?, displayOctave: Int?)
    }

    public var id: NoteID
    public var kind: Kind
    /// Position in the measure, in quarter notes. Chord tones share the first tone's onset.
    public var onset: Rational
    /// Sounding length in quarter notes; 0 for grace notes. Includes tuplet scaling.
    /// A non-grace note with `<duration>0</duration>` also has 0 and `grace == nil`
    /// (OSMD treats that as a grace note; S3 decides).
    public var duration: Rational
    /// The written value, when the file gives one.
    public var noteValue: NoteValue?
    public var dots: Int = 0
    public var voice: String = "1"
    /// 1-based staff within the part.
    public var staff: Int = 1
    /// Has `<chord/>`: sounds with the previous note.
    public var isChordTone = false
    public var grace: Grace?
    /// `<cue/>`, or `<type size="cue">`.
    public var cue = false
    /// False for `print-object="no"`: sounds but isn't drawn.
    public var printObject = true
    /// True for `<notehead>none</notehead>`: sounds but has no head drawn. OSMD's cursor, like
    /// `print-object="no"`, skips a position where every note is headless.
    public var noHead = false
    /// Ties as sounded, from `<tie type>`. Note that OSMD ignores these and
    /// builds ties only from the drawn `<tied>` elements below.
    public var soundTieStart = false
    public var soundTieStop = false
    /// Ties as drawn, from `<notations><tied type>`.
    public var drawnTieStart = false
    public var drawnTieStop = false
    /// `<tied type="continue">`, `<tied type="let-ring">`.
    public var drawnTieContinue = false
    public var drawnTieLetRing = false
    /// The written `<accidental>` ("sharp", "natural", ...), if any.
    public var accidental: String?
    public var accidentalMarks: AccidentalMarks = []
    /// `<notations><tuplet>` marks, in document order.
    public var tuplets: [TupletMark] = []
    public var stem: Stem?
    public var beams: [Beam] = []
    /// First `<fingering>` in the note's technical notations.
    public var fingering: String?
    /// `placement` ("above" / "below") of that fingering, when given.
    public var fingeringPlacement: String?
    public var timeModification: TimeModification?
    /// `<notations><slur>` ends on this note, in document order.
    public var slurs: [SlurMark] = []
    /// Where an octave line (`OctaveShift`) draws this note, in octaves from its sounding pitch
    /// (8va is -1). `pitch` stays the sounding pitch.
    public var displayOctaves = 0
    /// `<articulations>`, `<fermata>`, `<arpeggiate>`, `<ornaments>` and `<tremolo>` of the note.
    public var articulations: [ArticulationMark] = []
    public var fermata: FermataMark?
    public var arpeggio: ArpeggioMark?
    public var ornaments: [OrnamentMark] = []
    public var wavyLines: [WavyMark] = []
    public var tremolo: TremoloMark?

    public var isGrace: Bool { grace != nil }
    public var isRest: Bool { if case .rest = kind { true } else { false } }
    public var pitch: Pitch? { if case .pitched(let p) = kind { p } else { nil } }
}
