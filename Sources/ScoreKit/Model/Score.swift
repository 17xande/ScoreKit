import Foundation

/// A parsed score: metadata plus its parts.
public struct Score: Sendable, Equatable {
    /// `work-title`, else `movement-title`, else a title credit.
    public var title: String?
    /// The `creator type="composer"`, else a composer credit.
    public var composer: String?
    public var parts: [Part]

    /// Parse partwise MusicXML. Timewise scores throw `.unsupported("score-timewise")`.
    public static func parse(xml: Data) throws -> Score {
        try MusicXMLParser.parse(root: XNode.parse(xml))
    }

    /// Parse a `.musicxml` or `.mxl` file's bytes.
    public static func load(data: Data) throws -> Score {
        try parse(xml: ScoreFile.xmlData(from: data))
    }

    /// Indices of the piano parts: every part that `Part.isPiano`; else, when no part says so
    /// and the score has other parts, the parts that look like a piano (`Part.looksLikeGrandStaff`:
    /// two staves, G clef above F clef, not named or sounding like a harp, organ, voice or choir).
    /// A lone grand-staff part already is the whole score. Empty when none.
    public var pianoPartIndices: [Int] {
        let named = parts.indices.filter { parts[$0].isPiano }
        if !named.isEmpty { return named }
        return parts.count > 1 ? parts.indices.filter { parts[$0].looksLikeGrandStaff } : []
    }
}

public struct Part: Sendable, Equatable {
    public var id: String
    public var name: String
    public var abbreviation: String?
    /// The largest `<staves>` seen (or staff used), at least 1.
    public var staves: Int
    public var measures: [Measure]
    /// The first `<score-instrument>`'s `<instrument-name>` ("Piano"), nil when absent.
    public var instrumentName: String?
    /// The first `<score-instrument>`'s `<instrument-sound>` ("keyboard.piano", "voice.vocals").
    public var instrumentSound: String?
    /// The first `<midi-instrument>`'s `<midi-program>` (1-based).
    public var midiProgram: Int?
    /// Octave lines, pedal marks, hairpins and dynamics of the part, with their ends paired up.
    public var octaveShifts: [OctaveShift] = []
    public var pedals: [Pedal] = []
    public var wedges: [Wedge] = []
    public var dynamics: [Dynamic] = []
    /// Plain words directions and dashed lines of the part (tempo words are in `Measure.directions`).
    public var words: [TextMark] = []
    public var dashes: [DashLine] = []

    public init(id: String, name: String, abbreviation: String? = nil, staves: Int, measures: [Measure],
                instrumentName: String? = nil, instrumentSound: String? = nil, midiProgram: Int? = nil) {
        self.id = id; self.name = name; self.abbreviation = abbreviation; self.staves = staves; self.measures = measures
        self.instrumentName = instrumentName; self.instrumentSound = instrumentSound; self.midiProgram = midiProgram
    }

    private static func tokens(_ s: String?) -> Set<String> {
        Set((s ?? "").lowercased().split { !$0.isLetter }.map(String.init))
    }

    /// True for a keyboard part, from its `<instrument-sound>` (any `keyboard.*` counts, so
    /// harpsichord, celesta and clavinet do as well; `keyboard.organ` and accordions do not),
    /// else from a whole word in its part name, abbreviation or instrument name: piano,
    /// pianoforte, fortepiano, klavier, clavier, keyboard, pno, pf. A MIDI program 1-8 (the piano
    /// family) counts only when the part has no name and no instrument information at all.
    public var isPiano: Bool {
        if let s = instrumentSound?.lowercased(), s.hasPrefix("keyboard.") {
            return !s.contains("organ") && !s.contains("accordion")
        }
        let words: Set<String> = ["piano", "pianos", "pianoforte", "fortepiano", "klavier", "clavier", "keyboard", "pno", "pf"]
        let named = Self.tokens(name).union(Self.tokens(abbreviation)).union(Self.tokens(instrumentName))
        if !words.isDisjoint(with: named) { return true }
        if named.isEmpty, instrumentSound == nil, let p = midiProgram, (1...8).contains(p) { return true }
        return false
    }

    /// A part with two staves, a G clef on the upper and an F clef on the lower one, that is not
    /// called or sounding like a harp, organ, accordion, voice or choir.
    public var looksLikeGrandStaff: Bool {
        guard staves == 2 else { return false }
        let firstClef = { (staff: Int) in measures.lazy.flatMap(\.clefChanges).first { $0.staff == staff }?.clef.sign }
        guard firstClef(1) == "G", firstClef(2) == "F" else { return false }
        let excluded: Set<String> = ["harp", "organ", "accordion", "choir", "chorus", "voice", "vocal", "vocals", "chant",
                                     "soprano", "alto", "tenor", "bass", "baritone", "marimba", "vibraphone"]
        let named = Self.tokens(name).union(Self.tokens(abbreviation)).union(Self.tokens(instrumentName))
            .union(Self.tokens(instrumentSound))
        return excluded.isDisjoint(with: named)
    }
}

/// A clef. One recorded at an onset equal to the measure's duration (a clef
/// before the barline) applies to the next measure.
public struct Clef: Sendable, Hashable {
    /// "G", "F", "C", "percussion", "TAB", ...
    public var sign: String
    public var line: Int?
    public var octaveChange: Int
    public var afterBarline = false
    public var printObject = true
    public var additional = false
}

/// A key signature. `fifths` is negative for flats.
public struct Key: Sendable, Hashable {
    public var fifths: Int
    public var mode: String?
    /// The file spelled the key with `<key-step>`/`<key-alter>` instead of
    /// `<fifths>`; `fifths` is then 0.
    public var nonTraditional = false
}

public struct TimeSignature: Sendable, Hashable {
    public enum Symbol: Sendable, Hashable { case common, cut }
    /// Numerator (1...1000); "3+2" is summed to 5.
    public var beats: Int
    public var beatType: Int
    public var symbol: Symbol?

    /// A bar's length in quarter notes.
    public var quarters: Rational { Rational(beats * 4, beatType) }
}

/// `staff` is nil when the element applied to every staff.
public struct KeyChange: Sendable, Hashable {
    public var onset: Rational
    public var staff: Int?
    public var key: Key
}

public struct TimeChange: Sendable, Hashable {
    public var onset: Rational
    public var staff: Int?
    public var time: TimeSignature
}

public struct ClefChange: Sendable, Hashable {
    public var onset: Rational
    public var staff: Int
    public var clef: Clef
}

/// A `<metronome>` mark. Fields are raw so S3 can follow OSMD (raw per-minute,
/// beat unit ignored); `quarterBPM` is the musically correct reading.
public struct Metronome: Sendable, Hashable {
    public var beatUnit: NoteValue?
    public var dots: Int
    /// First number found in `<per-minute>` ("c. 120" and "120-132" give 120); nil if none.
    public var perMinute: Double?
    /// `<per-minute>` as written.
    public var perMinuteText: String?

    /// Tempo as quarter notes per minute (beat unit and dots applied), nil if
    /// either part is missing.
    public var quarterBPM: Double? {
        guard let beatUnit, let perMinute else { return nil }
        var unit = beatUnit.quarters.double
        var add = unit / 2
        for _ in 0..<dots { unit += add; add /= 2 }
        return perMinute * unit
    }
}

/// A direction or standalone `<sound>` that carries a tempo (other directions are not kept,
/// except jump marks, see `JumpMark`).
public struct TempoDirection: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// Inside a `<direction>`.
        case direction
        /// A `<sound>` directly in the measure (OSMD only honours these in measure index 0).
        case standaloneSound
    }
    public var source: Source
    /// Cursor position in the measure, in quarters, before `offset`.
    public var onset: Rational
    /// The direction's `<offset>` in quarters (0 when absent). Per the MusicXML spec it moves the
    /// *sound* only when `offsetSound` is true; otherwise it just moves the printed mark.
    public var offset: Rational
    /// `<offset sound="yes">`.
    public var offsetSound = false
    /// An `<offset>` inside the `<sound>` element itself (quarters): it always moves the sound.
    public var soundOffset: Rational?

    /// Where the tempo takes effect, per the spec: `<sound><offset>`, else the direction's offset
    /// when `sound="yes"`, else the cursor position.
    public var soundPosition: Rational { onset + (soundOffset ?? (offsetSound ? offset : .zero)) }
    public var placement: String?
    public var staff: Int?
    /// `<sound tempo>` as a number when it is a positive number.
    public var soundTempo: Double?
    /// `<sound tempo>` exactly as written.
    public var soundTempoText: String?
    public var metronome: Metronome?
    /// The `<words>` of the direction ("Allegro"), when it also carries a tempo; nil when empty.
    public var words: String?

    /// The musically correct tempo in quarters per minute (`<sound>` wins, else the
    /// metronome with its beat unit and dots applied). This is NOT OSMD's playback
    /// tempo (`TempoMap`): that uses the raw per-minute of a metronome mark, ignoring its
    /// beat unit and dots, and rounds sound tempos. Use this for display only.
    public var quarterBPM: Double? { soundTempo ?? metronome?.quarterBPM }
}

/// A tempo word on its own, e.g. "Largo", and the tempo OSMD gives it.
public struct TempoWord: Sendable, Hashable {
    public var onset: Rational
    public var bpm: Double
}

/// A navigation mark: `<sound dacapo|dalsegno|segno|coda|tocoda|fine>` or a
/// `<segno/>` / `<coda/>` direction type. Words such as "D.C. al Fine" are not
/// interpreted; only the playback attributes are.
public struct JumpMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case dacapo, dalsegno, segno, coda, toCoda, fine }
    public enum Source: Sendable, Hashable {
        /// A `<sound>` attribute (inside a `<direction>` or directly in the measure).
        case sound
        /// A `<segno/>` or `<coda/>` direction type (no playback id).
        case directionType
        /// A `segno`/`coda` attribute or child element of a `<barline>`.
        case barline
    }
    public var kind: Kind
    /// The attribute value naming the target ("segno1"); nil when it is just a flag
    /// ("yes" on `dacapo`/`fine`, or a direction type).
    public var id: String?
    /// Cursor position in the measure, in quarters.
    public var onset: Rational
    public var source: Source
}

public struct Repeat: Sendable, Hashable {
    public enum Direction: Sendable, Hashable { case forward, backward }
    public var direction: Direction
    public var times: Int?
}

/// A volta bracket marker.
public struct Ending: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case start, stop, discontinue }
    /// The pass numbers it applies to ("1, 2" gives [1, 2], "1-3" gives [1, 2, 3]).
    public var numbers: [Int]
    /// The `number` attribute as written.
    public var rawNumber: String
    /// The element's text (the label to print, e.g. "1.").
    public var text: String
    public var printObject: Bool
    public var kind: Kind
}

public struct Barline: Sendable, Hashable {
    public enum Location: Sendable, Hashable { case left, right, middle }
    public var location: Location
    /// Quarters into the measure: 0 for left, the measure's duration for right.
    public var onset: Rational
    public var style: String?
    public var repeatMark: Repeat?
    public var ending: Ending?
    /// A `<fermata>` on the barline.
    public var fermata: FermataMark?
}

public struct Measure: Sendable, Equatable {
    /// 0-based, in document order.
    public var index: Int
    /// The printed number (may be "0" for a pickup, or non-numeric; an implicit non-numeric label takes the previous measure's number).
    public var number: String
    public var implicit: Bool
    /// Length in quarters: the furthest the time cursor reached, else the time signature's.
    /// OSMD uses the longest duration over all parts for each measure index; S3 handles that.
    public var duration: Rational
    /// Divisions per quarter in effect at the end of the measure.
    public var divisions: Int
    /// A `<staves>` declared in this measure.
    public var staves: Int?
    public var keyChanges: [KeyChange] = []
    public var timeChanges: [TimeChange] = []
    public var clefChanges: [ClefChange] = []
    public var barlines: [Barline] = []
    public var directions: [TempoDirection] = []
    /// Tempo words ("Largo") in a direction with no `<sound tempo>` or metronome, with the BPM OSMD
    /// plays for them (`TempoWords`). Display is unchanged: these are drawn as plain words.
    public var tempoWords: [TempoWord] = []
    /// D.C./D.S./segno/coda/to coda/fine marks, in document order.
    public var jumpMarks: [JumpMark] = []
    public var notes: [Note] = []
}
