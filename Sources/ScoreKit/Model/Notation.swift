/// A place in a part: a measure (0-based index) and quarter notes into it.
public struct ScorePosition: Sendable, Hashable, Comparable {
    public var measure: Int
    public var onset: Rational
    public init(measure: Int, onset: Rational) { self.measure = measure; self.onset = onset }
    public static func < (a: ScorePosition, b: ScorePosition) -> Bool {
        (a.measure, a.onset) < (b.measure, b.onset)
    }
}

/// An octave line (`<octave-shift>`): notes of `staff` from `start` up to (not including) `end`
/// are written `octaves` octaves away from where they sound. MusicXML pitches are sounding
/// pitches, so the shift only moves where the heads are drawn (`Note.displayOctaves`); the
/// timeline plays `Note.pitch` as it is.
public struct OctaveShift: Sendable, Hashable {
    public var staff: Int
    public var start: ScorePosition
    /// Where the line stops; the end of the part when the file never stops it.
    public var end: ScorePosition
    /// Written minus sounding, in octaves: -1 for 8va, -2 for 15ma, +1 for 8vb, +2 for 15mb.
    public var octaves: Int
}

/// A pedal mark (`<pedal>`): pressed at `start`, re-pressed at each of `changes`, released at `end`.
public struct Pedal: Sendable, Hashable {
    public var start: ScorePosition
    public var end: ScorePosition
    public var changes: [ScorePosition]
    /// `line="yes"`: a bracket line; otherwise "Ped." and "*" signs.
    public var line: Bool
    /// "Ped." is printed at the start (`sign`, defaulting to the opposite of `line`; a `resume` defaults to
    /// none). A sostenuto pedal is drawn like a damper pedal (as Ped.).
    public var startSign: Bool
    /// Ends with a release (`stop`) rather than `discontinue`, a new `start` or the end of the part.
    public var released: Bool
}

/// A hairpin (`<wedge>`).
public struct Wedge: Sendable, Hashable {
    public var staff: Int
    public var start: ScorePosition
    public var end: ScorePosition
    public var crescendo: Bool
    /// `placement="above"`; below the staff otherwise.
    public var above: Bool
}

/// A dynamic mark (`<dynamics>`): "p", "mf", "sfz", "fp" ...
public struct Dynamic: Sendable, Hashable {
    public var staff: Int
    public var at: ScorePosition
    public var text: String
    public var above: Bool
}

/// One end of a slur (`<notations><slur>`).
public struct SlurMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case start, stop, `continue` }
    public var kind: Kind
    public var number: Int
    /// `placement` or `orientation` ("above"/"over" is true, "below"/"under" false); nil when absent.
    public var above: Bool?
}

// MARK: S6c part 2: articulations, fermatas, arpeggios, ornaments, tremolo, words

/// One articulation of a note (`<articulations>`), in the order of the file.
public struct ArticulationMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case staccato, staccatissimo, accent
        /// `<strong-accent>`: the marcato wedge.
        case strongAccent
        case tenuto
        /// `<detached-legato>`: tenuto and staccato together (portato). A tenuto and a staccato
        /// on one note are drawn as this too.
        case tenutoStaccato
    }
    public var kind: Kind
    /// `placement` ("above"/"below"); nil when absent.
    public var above: Bool?
}

/// A fermata on a note, rest or barline. `inverted` is `type="inverted"` (drawn below).
public struct FermataMark: Sendable, Hashable {
    public var inverted: Bool
}

/// `<arpeggiate>`: a wavy line left of the chord. Notes of one chord (also across the two staves
/// of a part) with the same `number` at one position share one line.
public struct ArpeggioMark: Sendable, Hashable {
    public var number: Int
    /// `direction`: up or down puts an arrowhead on that end; nil is a plain wavy line.
    public var up: Bool?
}

/// An ornament sign of a note (`<ornaments>`).
public struct OrnamentMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// `<trill-mark>`: "tr".
        case trill
        /// `<mordent>`: with the vertical stroke (a lower mordent).
        case mordent
        /// `<inverted-mordent>`: without it (an upper mordent).
        case invertedMordent
        case turn, invertedTurn
    }
    public var kind: Kind
    public var above: Bool?
    /// An `<accidental-mark>` that belongs to this ornament: the accidental's name ("sharp") and
    /// `placement` (nil: above, except below a mordent).
    public var accidental: String?
    public var accidentalAbove: Bool?
}

/// `<wavy-line>`: the extension line of a trill, from this note to the note with the `stop`.
public struct WavyMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case start, stop, `continue` }
    public var kind: Kind
    public var number: Int
}

/// `<tremolo>`. A `single` one is drawn on the stem; the two notes of a double tremolo (`start`
/// and `stop`) are parsed, and drawn as slashes between their stems.
public struct TremoloMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case single, start, stop }
    public var kind: Kind
    /// Number of slashes (1...8).
    public var marks: Int
}

/// A plain words direction (`<words>`) that is no tempo or jump mark: "rit.", "dolce", "cresc.".
public struct TextMark: Sendable, Hashable {
    public var staff: Int
    public var at: ScorePosition
    /// With whitespace runs collapsed.
    public var text: String
    /// `placement`; nil when absent (the engraver picks: above for tempo-like words).
    public var above: Bool?
}

/// A `<dashes>` line ("cresc. - - -") from `start` to `end`, on `staff`.
public struct DashLine: Sendable, Hashable {
    public var staff: Int
    public var start: ScorePosition
    public var end: ScorePosition
    /// `placement` of the direction; nil when absent.
    public var above: Bool?
}
