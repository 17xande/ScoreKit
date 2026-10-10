import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// What to lay out and how. Everything is in staff spaces.
public struct LayoutOptions: Sendable, Equatable {
    public enum Width: Sendable, Equatable {
        /// Fill systems up to this width, justified.
        case fixed(Double)
        /// One system as long as the music needs.
        case singleLine
    }

    /// One staff of one part.
    public struct StaffRef: Sendable, Hashable {
        public var part: Int
        /// 1-based staff within the part.
        public var staff: Int
        public init(part: Int, staff: Int) { self.part = part; self.staff = staff }
    }

    public var width: Width
    public var showFingering: Bool
    public var showMeasureNumbers: Bool
    /// Clear space between the staves of a part, bottom line to top line, at least.
    public var staffDistance: Double
    /// Clear space between consecutive parts' staves, at least.
    public var partDistance: Double
    /// Clear space between systems, at least.
    public var systemDistance: Double
    /// Staves to engrave; nil is every staff of every part. Indices are the score's.
    public var staves: [StaffRef]?
    /// Key and time changes shown at the end of the system before they take effect.
    /// Not implemented in S4a (off, and ignored).
    public var courtesyChanges: Bool
    /// Leave out the staves of `staves` (or of every part) that have no note at all in the whole
    /// score, only rests. Staves of one part are kept or dropped independently. Default false.
    public var hideEmptyStaves: Bool

    public init(width: Width = .fixed(80), showFingering: Bool = false, showMeasureNumbers: Bool = true,
                staffDistance: Double = 7, partDistance: Double = 8, systemDistance: Double = 9,
                staves: [StaffRef]? = nil, courtesyChanges: Bool = false, hideEmptyStaves: Bool = false) {
        self.width = width
        self.showFingering = showFingering
        self.showMeasureNumbers = showMeasureNumbers
        self.staffDistance = staffDistance
        self.partDistance = partDistance
        self.systemDistance = systemDistance
        self.staves = staves
        self.courtesyChanges = courtesyChanges
        self.hideEmptyStaves = hideEmptyStaves
    }

    /// The staves of the score's piano part(s) (`Score.pianoPartIndices`), all of their staves;
    /// nil when the score has no piano part.
    public static func pianoStaves(of score: Score) -> [StaffRef]? {
        let idx = score.pianoPartIndices
        guard !idx.isEmpty else { return nil }
        return idx.flatMap { pi in (1...max(1, score.parts[pi].staves)).map { StaffRef(part: pi, staff: $0) } }
    }

    /// Restricts `staves` to the score's piano part(s), leaving every other option alone. Does
    /// nothing when the score has no piano part. Tempo marks of the hidden parts are still drawn.
    public mutating func restrict(toPianoOf score: Score) {
        if let p = Self.pianoStaves(of: score) { staves = p }
    }

    public static let `default` = LayoutOptions()
    public static let singleLine = LayoutOptions(width: .singleLine)
}

/// Identifies a beam: it joins several groups, so it has an identity of its own.
/// `ScoreLayout.beams[id]` lists the groups it joins.
public struct BeamID: Sendable, Hashable, Comparable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public static func < (a: BeamID, b: BeamID) -> Bool { a.value < b.value }
}

/// A drawn element, in layout coordinates (staff spaces, y down).
///
/// Colouring: an item with a `noteID` belongs to that one note (its head, accidental, dots,
/// fingering and the rest glyph); colour it with that note's colour. An item with a `groupID`
/// and no `noteID` belongs to a chord or rest as a whole (the stem, shared ledger lines, and
/// later flags and beams); `ScoreLayout.groups[groupID]` lists the member notes, and the
/// renderer picks the policy (the suggested one: the first marked member's colour, else the
/// default). Furniture (clefs, barlines, staff lines) has neither.
///
/// Beams: a beam joins several groups, so it belongs to none of them. Each beam segment is a
/// `.beam` item carrying a `BeamID`, and `ScoreLayout.beams[id]` lists the member groups. The
/// renderer decides the colour; the suggested policy is plain ink.
/// Flags belong to their group (`groupID` is the group id, no `noteID`). Tuplet numbers and
/// brackets have neither id and are drawn in ink.
/// Articulations, tremolo slashes, arpeggio lines, ornaments, fermatas and words are items with no ids,
/// drawn in ink, and `LaidSystem.marks` says which items belong to which mark. Slurs are filled `.path` items with no ids: they span several notes, so they are drawn in ink and
/// not painted with a note's mark. Dynamics, hairpins,
/// octave lines and pedal marks have no ids and are drawn in ink; `LaidSystem.marks` says which
/// items belong to which mark.
/// Ties are filled `.path` items carrying the *start* note's `noteID` (and no `groupID`); a tie
/// split across a system break gives two items, an outgoing half and an incoming half, both with
/// the start note's id. Colour a tie like its start note. Voltas, jump marks, tempo marks and
/// measure numbers have no ids and are drawn in ink. Fingering digits belong to their note.
/// Shared heads: when two voices share one notehead (a unison of the same value), only the
/// first note draws it (head, accidental and dots); the other note's `LaidNote.headBox` is the
/// same box and `ScoreLayout.sharedHeads[second] = first`. Colour the single head by either
/// note's mark.
public enum LayoutItem: Sendable, Hashable {
    /// A SMuFL glyph with its origin (baseline-left) at `position`; `size` is the em in
    /// staff spaces (nil is the standard 4).
    case glyph(codepoint: UInt32, position: CGPoint, size: Double? = nil, noteID: NoteID? = nil, groupID: NoteID? = nil)
    /// A straight stroke of the given thickness (staff lines, stems, barlines, ledger lines).
    case line(from: CGPoint, to: CGPoint, thickness: Double, noteID: NoteID? = nil, groupID: NoteID? = nil)
    /// A filled rectangle (thick barlines).
    case rect(CGRect, noteID: NoteID? = nil, groupID: NoteID? = nil)
    case text(String, position: CGPoint, style: TextStyle)
    /// A path, stroked when `stroke` is a thickness and filled when `fill` is true: beams are
    /// filled polygons, ties and slurs are filled bezier crescents or stroked curves.
    case path([PathElement], stroke: Double? = nil, fill: Bool = false, noteID: NoteID? = nil, groupID: NoteID? = nil)
    /// One filled beam segment (a polygon) of the beam `beamID`.
    case beam([PathElement], beamID: BeamID)

    /// The same item moved down by `dy`.
    public func translated(dy: Double) -> LayoutItem {
        switch self {
        case .glyph(let c, let p, let s, let n, let g): .glyph(codepoint: c, position: p.offset(dy: dy), size: s, noteID: n, groupID: g)
        case .line(let a, let b, let t, let n, let g): .line(from: a.offset(dy: dy), to: b.offset(dy: dy), thickness: t, noteID: n, groupID: g)
        case .rect(let r, let n, let g): .rect(r.offsetBy(dx: 0, dy: dy), noteID: n, groupID: g)
        case .text(let s, let p, let st): .text(s, position: p.offset(dy: dy), style: st)
        case .path(let els, let st, let f, let n, let g): .path(els.map { $0.translated(dy: dy) }, stroke: st, fill: f, noteID: n, groupID: g)
        case .beam(let els, let id): .beam(els.map { $0.translated(dy: dy) }, beamID: id)
        }
    }

    public var noteID: NoteID? {
        switch self {
        case .glyph(_, _, _, let n, _), .line(_, _, _, let n, _), .rect(_, let n, _), .path(_, _, _, let n, _): n
        case .text, .beam: nil
        }
    }

    public var beamID: BeamID? {
        if case .beam(_, let id) = self { id } else { nil }
    }

    public var groupID: NoteID? {
        switch self {
        case .glyph(_, _, _, _, let g), .line(_, _, _, _, let g), .rect(_, _, let g), .path(_, _, _, _, let g): g
        case .text, .beam: nil
        }
    }
}

/// One staff row of a system. `top` is the y of its top line; the bottom line is `top + 4`.
public struct LaidStaff: Sendable, Hashable {
    public var partIndex: Int
    /// 1-based staff within the part.
    public var staffInPart: Int
    public var top: Double
    public init(partIndex: Int, staffInPart: Int, top: Double) {
        self.partIndex = partIndex; self.staffInPart = staffInPart; self.top = top
    }
}

/// A shared horizontal position: every staff and part aligns notes starting at `onset` of
/// measure `measureIndex` to `x`.
public struct LaidColumn: Sendable, Hashable {
    public var measureIndex: Int
    /// Quarter notes into the measure.
    public var onset: Rational
    /// The left edge of a standard notehead at this onset.
    public var x: Double
}

/// Horizontal extent of one measure on a system.
public struct LaidMeasure: Sendable, Hashable {
    public var index: Int
    /// Length in quarter notes (the longest over the selected parts).
    public var duration: Rational
    /// Where the measure begins: just after the previous barline (or the system's left edge).
    public var x0: Double
    /// Where the music begins, after clef/key/time and a leading repeat.
    public var bodyStart: Double
    /// The right edge of the closing barline.
    public var barX: Double
    public var columns: [LaidColumn]
    /// The clef, key and time of each staff (`LaidSystem.staves` order) at the start of the measure.
    public var contexts: [StaffContext] = []
    /// Clef and key changes inside the measure (and a clef at its end), by x, per staff.
    public var contextChanges: [LaidContextChange] = []
}

/// The clef, key and time signature in effect on one staff.
public struct StaffContext: Sendable, Hashable {
    public var clef: Clef
    public var key: Key
    /// Nil when the score has not stated a time signature yet.
    public var time: TimeSignature?
}

/// The staves' contexts from `x` on, until the next step.
public struct LaidContextStep: Sendable, Hashable {
    public var x: Double
    public var contexts: [StaffContext]
}

/// A clef or key change inside a measure: from `x` on, `staff` (index into `LaidSystem.staves`)
/// is in `context`.
public struct LaidContextChange: Sendable, Hashable {
    public var staff: Int
    public var x: Double
    public var context: StaffContext
}

/// One slur, dynamic, hairpin, octave line or pedal mark of a system, and which of
/// `LaidSystem.items` draw it (a mark that breaks across systems gives one per system).
struct LaidMark: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case slur, crossStaffSlur, dynamic, hairpin, octaveLine, pedal
        case articulation, tremolo, arpeggio, ornament, fermata, words }
    var kind: Kind
    /// Index into `LaidSystem.staves`: the staff whose buffer it was placed with.
    var staffIndex: Int
    var items: Range<Int>
}

public struct LaidSystem: Sendable {
    public var frame: CGRect
    public var staves: [LaidStaff]
    /// Measure indices (0-based, as in `Part.measures`) on this system.
    public var measureRange: Range<Int>
    public var items: [LayoutItem]
    public var columns: [LaidColumn]
    public var measures: [LaidMeasure]
    var marks: [LaidMark] = []
    /// The system barline, braces and bracket at the left (the sticky header copies them).
    public var leftFurniture: [LayoutItem] = []
    /// Where the clef, key or time of some staff changes along the system, ascending in x: from `x` on,
    /// the staves are in `contexts` (`ScoreLayout.stickyContext` searches it).
    public var contextSteps: [LaidContextStep] = []
    public var columnXs: [Double] { columns.map(\.x) }
}

/// Where one note was put. Coordinates are layout coordinates.
public struct LaidNote: Sendable, Hashable {
    public var id: NoteID
    public var systemIndex: Int
    /// Index into `LaidSystem.staves`.
    public var staffIndex: Int
    /// The notehead's bounding box (for a rest, the rest glyph's).
    public var headBox: CGRect
    /// Its chord (or rest, or lone note): the lead note's id, see `ScoreLayout.groups`.
    public var groupID: NoteID
    /// Where the group's stem ends (the far end from the heads), nil without a stem.
    public var stemEnd: CGPoint?
    public var isRest: Bool
    /// A grace note: it has no timeline entry of its own (see `HitResult`).
    public var isGrace = false
}

/// A note's place in the score: 0-based measure and quarters into it.
public struct NoteTime: Sendable, Hashable {
    public var measureIndex: Int
    public var onset: Rational
    public init(measureIndex: Int, onset: Rational) { self.measureIndex = measureIndex; self.onset = onset }
}

/// The result of laying a score out: pure geometry in staff spaces.
public struct ScoreLayout: Sendable {
    public var size: CGSize
    public var systems: [LaidSystem]
    /// Every drawn note (pitched, unpitched and rest) by id.
    public var notes: [NoteID: LaidNote]
    /// Notehead bounding boxes of pitched and unpitched notes, in layout coordinates.
    public var noteBoxes: [NoteID: CGRect]
    /// Group id (the lead note's id) to its member notes, ascending staff position.
    public var groups: [NoteID: [NoteID]]
    /// Beam id to the groups it joins, in time order.
    public var beams: [BeamID: [NoteID]]
    /// A note that shares another note's head (see `LayoutItem`), to that other note.
    public var sharedHeads: [NoteID: NoteID]
    /// Tied notes that were both drawn: end note to start note (a tie split across systems is
    /// still one entry). Half ties (let-ring, abandoned) have none.
    public var tiedFrom: [NoteID: NoteID] = [:]
    /// Where each drawn note (rests included) sits in time: its measure and onset.
    public var noteTimes: [NoteID: NoteTime] = [:]

    /// Where a measure was laid out: the system and the measure's index in `LaidSystem.measures`.
    public struct MeasureLocation: Sendable, Hashable {
        public var systemIndex: Int
        public var slot: Int
    }

    /// Measure index to its place, built once by the engraver (queries are O(1)).
    public var measureLocations: [Int: MeasureLocation] = [:]
    /// Every drawn note of each system, ascending id (hit testing scans only one system).
    public var systemNotes: [[LaidNote]] = []

    /// A horizontal position on a system.
    public struct LaidX: Sendable, Hashable {
        public var systemIndex: Int
        public var x: Double
    }

    /// Fills `measureLocations` and `systemNotes` from `systems` and `notes`.
    mutating func buildIndexes() {
        measureLocations = [:]
        for (si, sys) in systems.enumerated() {
            for (slot, m) in sys.measures.enumerated() where measureLocations[m.index] == nil {
                measureLocations[m.index] = MeasureLocation(systemIndex: si, slot: slot)
            }
        }
        systemNotes = Array(repeating: [], count: systems.count)
        for n in notes.values where systemNotes.indices.contains(n.systemIndex) { systemNotes[n.systemIndex].append(n) }
        for i in systemNotes.indices { systemNotes[i].sort { $0.id < $1.id } }
    }

    /// The x of a position in a measure, interpolated between the drawn columns and the
    /// measure's bounds (start of the music, closing barline). Nil when the measure was not
    /// laid out (not selected, or out of range). `position` is quarter notes into the measure
    /// and is clamped to it. No allocation; O(columns of the measure).
    public func x(measureIndex: Int, position: Rational) -> LaidX? {
        guard let loc = measureLocations[measureIndex] else { return nil }
        let si = loc.systemIndex
        let m = systems[si].measures[loc.slot]
        // Anchors: (0, first column at onset 0 or the start of the music), the columns after 0,
        // and (duration, closing barline) unless a column already reaches the end.
        var prevP = Rational.zero
        var prevX = m.columns.first.flatMap { $0.onset <= .zero ? $0.x : nil } ?? m.bodyStart
        if position <= prevP { return LaidX(systemIndex: si, x: prevX) }
        for c in m.columns where c.onset > .zero {
            if position <= c.onset {
                let t = (position - prevP).double / (c.onset - prevP).double
                return LaidX(systemIndex: si, x: prevX + (c.x - prevX) * t)
            }
            prevP = c.onset
            prevX = c.x
        }
        if prevP < m.duration, position <= m.duration {
            let t = (position - prevP).double / (m.duration - prevP).double
            return LaidX(systemIndex: si, x: prevX + (m.barX - prevX) * t)
        }
        return LaidX(systemIndex: si, x: prevP < m.duration ? m.barX : prevX)
    }
}
