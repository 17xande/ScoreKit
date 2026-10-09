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
