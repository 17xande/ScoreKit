import Foundation

// Per-measure analysis for the engraver: which glyphs go where relative to a column, which
// accidentals to print, and how wide each column needs to be. No absolute x/y here.

enum BarKind: Sendable, Hashable {
    case none, regular, double, final, heavy, repeatBackward

    /// Horizontal room the line(s) take, ending at the barline's right edge.
    var width: Double {
        switch self {
        case .none: 0
        case .regular: 0.16
        case .double: 0.16 * 2 + 0.4
        case .final: 0.16 + 0.4 + 0.5
        case .heavy: 0.5
        case .repeatBackward: 0.4 + 0.16 + 0.16 + 0.4 + 0.5
        }
    }
}

struct Slot: Hashable { var part: Int; var staff: Int }

struct HeadNote {
    var note: Note
    var p: Int
    /// Offset of the notehead from the column's x (second flips).
    var dx = 0.0
    var acc: Glyph?
    var parens = false
    var accCol = 0
    /// The other voice's note whose head this one shares (the head is drawn once, there).
    var sharedWith: NoteID?
}

struct Group {
    /// The first note of the group in document order: the group's id.
    var leadID: NoteID
    var onset: Rational
    /// Ascending staff position.
    var notes: [HeadNote]
    var isRest = false
    var measureRest = false
    var grace = false
    var value: NoteValue = .quarter
    var dots = 0
    var stemUp = false
    var scale = 1.0
    var head: Glyph = .noteheadBlack
    var accColW: [Double] = []
    var voice = "1"
    /// Rank of the voice among the staff's voices in the measure (0 is the upper one).
    var voiceRank = 0
    var multiVoice = false
    /// `<stem>none</stem>`: no stem, flag or beam.
    var stemNone = false
    /// Whole-group shift to the right, to clear another voice's heads.
    var voiceDX = 0.0
    /// Extra room before the dots, to clear heads of other voices at the same onset.
    var dotExtra = 0.0
    /// Vertical shift of a rest in multi-voice measures, in staff spaces.
    var restDY = 0.0
    /// Left edge (relative to the column) of the leftmost head at this onset over all voices.
    var leftEdge: Double?
    /// Index into the staff-measure's beams.
    var beamIndex: Int?

    var size: Double { Glyph.standardSize * scale }
    var headWidth: Double { head.metrics.advance * scale }
    /// Centres wide heads (whole notes) on the column like a standard head.
    var baseDX: Double { isRest ? 0 : -(headWidth - Glyph.noteheadBlack.metrics.advance * scale) / 2 + voiceDX }
    var accTotal: Double { accColW.reduce(0, +) }
    var hasAccidental: Bool { notes.contains { $0.acc != nil } }
    var dotsWidth: Double { dots > 0 ? 0.4 + 0.55 * Double(dots) : 0 }

    /// Extent to the left of the column's x: accidentals and left-flipped heads.
    var leftW: Double {
        let minX = leftEdge.map { min($0, baseDX + (notes.map(\.dx).min() ?? 0)) } ?? (baseDX + (notes.map(\.dx).min() ?? 0))
        return accTotal + (hasAccidental ? 0.2 * scale : 0) + max(0, -minX)
    }
    /// Extent to the right of the column's x: heads, flipped heads and dots.
    var rightW: Double {
        if isRest { return Glyph.rest(value).metrics.advance + dotsWidth }
        let maxDX = notes.map(\.dx).max() ?? 0
        return baseDX + maxDX + headWidth + dotsWidth + (dots > 0 ? dotExtra : 0)
    }
    /// Room a grace group takes before its column.
    var graceWidth: Double { leftW + rightW + 0.45 * scale }
}

extension Glyph {
    static func rest(_ v: NoteValue) -> Glyph {
        switch v {
        case .breve: .restDoubleWhole
        case .whole: .restWhole
        case .half: .restHalf
        case .quarter: .restQuarter
        case .eighth: .rest8th
        case .sixteenth: .rest16th
        case .thirtySecond: .rest32nd
        case .sixtyFourth: .rest64th
        case .oneTwentyEighth: .rest128th
        }
    }

    static func notehead(_ v: NoteValue) -> Glyph {
        switch v {
        case .breve: .noteheadDoubleWhole
        case .whole: .noteheadWhole
        case .half: .noteheadHalf
        default: .noteheadBlack
        }
    }

    static func accidental(alter: Int) -> Glyph {
        switch alter {
        case ...(-2): .accidentalDoubleFlat
        case -1: .accidentalFlat
        case 0: .accidentalNatural
        case 1: .accidentalSharp
        default: .accidentalDoubleSharp
        }
    }

    /// The glyph for a written `<accidental>` value, if it is one we draw.
    static func accidental(named name: String) -> Glyph? {
        switch name {
        case "sharp", "natural-sharp": .accidentalSharp
        case "flat", "natural-flat": .accidentalFlat
        case "natural": .accidentalNatural
        case "double-sharp", "sharp-sharp": .accidentalDoubleSharp
        case "flat-flat", "double-flat": .accidentalDoubleFlat
        default: nil
        }
    }

    static func timeDigit(_ d: Int) -> Glyph {
        [.timeSig0, .timeSig1, .timeSig2, .timeSig3, .timeSig4, .timeSig5, .timeSig6, .timeSig7, .timeSig8, .timeSig9][d]
    }
}

/// One drawn beam line: members `from...to` (indices into `BeamGroup.members`); a single member
/// is a hook, `forward` pointing right.
struct BeamSegment {
    var level: Int
    var from: Int
    var to: Int
    var forward = true
}

struct BeamGroup {
    /// Indices into the staff-measure's groups, in time order.
    var members: [Int]
    var segments: [BeamSegment]
    var stemUp: Bool
    var maxLevel: Int
}

struct TupletSpan {
    var members: [Int]
    var number: Int
    var bracket: Bool
    var above: Bool
}

struct SlotMeasure {
    var groups: [Group] = []
    var beams: [BeamGroup] = []
    var tuplets: [TupletSpan] = []
    /// The clef in effect at the start of the measure (after any onset-0 change).
    var clef = Clef(sign: "G", line: 2, octaveChange: 0)
    /// A clef change at onset 0 (drawn small when the measure is not first on its system).
    var startClefChange: Clef?
    var midClefs: [(onset: Rational, clef: Clef)] = []
    /// A clef at the end of the measure (before the barline), applying to the next measure.
    var endClef: Clef?
    var key = Key(fifths: 0)
    var keyBefore = Key(fifths: 0)
    var keyChanged = false
    /// Key changes after the start of the measure.
    var midKeys: [(onset: Rational, key: Key, before: Key)] = []
    var time: TimeSignature?
    var timeChanged = false
}

struct Column {
    var onset: Rational
    /// Duration that drives the space after this column, in quarters.
    var spaceDur: Double
    var accW = 0.0
    var graceW = 0.0
    var clefW = 0.0
    var keyW = 0.0
    var rightW = 0.0
    var leftW: Double { accW + graceW + clefW + keyW }
}

struct MeasureData {
    var index: Int
    var number: String
    var duration: Rational
    var slots: [SlotMeasure]
    var columns: [Column] = []
    /// Stretchable gaps: before the first column, between columns, after the last (count + 1).
    var gaps: [Double] = []
    /// The part of each gap that does not stretch when the system is justified.
    var fixedGaps: [Double] = []
    /// Fixed width after the last gap: an end-of-measure clef and the barline.
    var endFixed = 0.0
    var endClefW = 0.0
    var bars: [Int: BarKind] = [:]
    var leftRepeat = false
    var hasOnlyMeasureRests = false
    var number0Based: Int { index }
}

enum Spacing {
    /// Space after a note of `quarters` duration: log-scaled, with a floor.
    static func space(_ quarters: Double) -> Double {
        let q = max(quarters, 1.0 / 64)
        return max(1.9, 3.6 + 1.25 * log2(q))
    }
}

/// Splits a duration into a note value and dots, if it is one.
func noteValueAndDots(quarters: Rational) -> (NoteValue, Int) {
    for v in NoteValue.allCases.reversed() {
        for dots in 0...3 {
            // value * (2 - 2^-dots)
            let f = Rational((1 << (dots + 1)) - 1, 1 << dots)
            if v.quarters * f == quarters { return (v, dots) }
        }
    }
    // Not a plain value: the shortest value at least as long.
    for v in NoteValue.allCases.reversed() where v.quarters >= quarters { return (v, 0) }
    return (.breve, 0)
}
