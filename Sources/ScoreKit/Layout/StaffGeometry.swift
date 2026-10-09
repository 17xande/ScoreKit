import Foundation

/// Where things sit on a staff. A staff position is in half staff spaces above the bottom
/// line: 0 is the bottom line, 2 the second line, 4 the middle line, 8 the top line, -1 the
/// space under the staff, 10 the first ledger line above it.
enum StaffGeometry {
    static func stepIndex(_ s: Step) -> Int {
        switch s { case .C: 0; case .D: 1; case .E: 2; case .F: 3; case .G: 4; case .A: 5; case .B: 6 }
    }

    /// Diatonic index of a letter and octave: C0 is 0, C4 is 28.
    static func diatonic(_ step: Step, _ octave: Int) -> Int { octave * 7 + stepIndex(step) }

    /// The diatonic index sitting on the bottom line under `clef`.
    static func bottomLineIndex(_ clef: Clef) -> Int {
        let line = clef.line ?? ["G": 2, "F": 4, "C": 3][clef.sign] ?? 3
        let reference: Int
        switch clef.sign {
        case "G": reference = diatonic(.G, 4)
        case "F": reference = diatonic(.F, 3)
        case "C": reference = diatonic(.C, 4)
        default: return diatonic(.E, 4)   // percussion, TAB: read like treble
        }
        return reference + 7 * clef.octaveChange - 2 * (line - 1)
    }

    static func position(_ step: Step, _ octave: Int, clef: Clef) -> Int {
        diatonic(step, octave) - bottomLineIndex(clef)
    }

    /// y in staff-local coordinates (top line at 0) of a position.
    static func y(_ position: Int) -> Double { 4 - Double(position) / 2 }

    /// Ledger line positions needed by a notehead at `position`.
    static func ledgerPositions(_ position: Int) -> [Int] {
        if position <= -2 { return Array(stride(from: -2, through: position, by: -2)) }
        if position >= 10 { return Array(stride(from: 10, through: position, by: 2)) }
        return []
    }

    // MARK: Key signatures

    static let sharpOrder: [Step] = [.F, .C, .G, .D, .A, .E, .B]
    static let flatOrder: [Step] = [.B, .E, .A, .D, .G, .C, .F]
    private static let trebleSharps = [8, 5, 9, 6, 3, 7, 4]
    private static let trebleFlats = [4, 7, 3, 6, 2, 5, 1]

    /// Most accidentals a theoretical key signature is drawn with: 7 letters, each at most doubled.
    static let maxKeyFifths = 14

    /// The alteration a key signature gives a letter: -2...2. Beyond 7 sharps (or flats) the
    /// signature is theoretical: the letters in order get a double sharp (flat) on top of the
    /// seven single ones (G# major is F## and six sharps). Counts past 14 are clamped.
    static func keyAlter(fifths: Int, step: Step) -> Int {
        guard fifths != 0 else { return 0 }
        let n = min(abs(fifths), maxKeyFifths)
        guard let i = (fifths > 0 ? sharpOrder : flatOrder).firstIndex(of: step) else { return 0 }
        let alter = (i < min(n, 7) ? 1 : 0) + (i < n - 7 ? 1 : 0)
        return fifths > 0 ? alter : -alter
    }

    /// Number of accidentals drawn for `fifths` (at most one per letter).
    static func keyGlyphCount(_ fifths: Int) -> Int { min(abs(fifths), 7) }

    /// Positions of the first `count` sharps (or flats) of the signature, in order, for `clef`.
    /// The common clefs use the traditional patterns (the zig-zag stays within the staff and
    /// at most a step above or below it); other clefs shift the treble pattern by the clef's
    /// diatonic offset and fold each accidental back into the window.
    static func keySignaturePositions(sharps: Bool, count: Int, clef: Clef) -> [Int] {
        let line = clef.line ?? ["G": 2, "F": 4, "C": 3][clef.sign] ?? 3
        let table: [Int]?
        switch (clef.sign, line) {
        case ("G", 2): table = sharps ? trebleSharps : trebleFlats
        case ("F", 4): table = sharps ? [6, 3, 7, 4, 1, 5, 2] : [2, 5, 1, 4, 0, 3, 6]
        case ("C", 3): table = sharps ? [7, 4, 8, 5, 2, 6, 3] : [3, 6, 2, 5, 1, 4, 0]
        case ("C", 4): table = sharps ? [2, 6, 3, 7, 4, 8, 5] : [5, 8, 4, 7, 3, 6, 2]
        default: table = nil
        }
        if let table { return Array(table.prefix(min(count, 7))) }
        // Generic: the treble letter at each position, moved into [lo, lo + 8].
        let shift = diatonic(.E, 4) - bottomLineIndex(clef)
        let lo = sharps ? 1 : 0
        return (sharps ? trebleSharps : trebleFlats).prefix(min(count, 7)).map { p in
            var q = p + shift
            while q > lo + 8 { q -= 7 }
            while q < lo { q += 7 }
            return q
        }
    }
}

/// How a clef is drawn: its glyph and the staff line its origin sits on.
struct ClefShape {
    var glyph: Glyph
    /// Staff-local y of the glyph origin.
    var originY: Double

    init(_ clef: Clef) {
        let line = Double(clef.line ?? ["G": 2, "F": 4, "C": 3][clef.sign] ?? 3)
        let y = 4 - (line - 1)
        switch (clef.sign, clef.octaveChange) {
        case ("G", -1): glyph = .gClef8vb; originY = y
        case ("G", 1): glyph = .gClef8va; originY = y
        case ("G", -2): glyph = .gClef15mb; originY = y
        case ("G", 2): glyph = .gClef15ma; originY = y
        case ("G", _): glyph = .gClef; originY = y
        case ("F", -1): glyph = .fClef8vb; originY = y
        case ("F", 1): glyph = .fClef8va; originY = y
        case ("F", -2): glyph = .fClef15mb; originY = y
        case ("F", 2): glyph = .fClef15ma; originY = y
        case ("F", _): glyph = .fClef; originY = y
        case ("C", -1): glyph = .cClef8vb; originY = y
        case ("C", _): glyph = .cClef; originY = y
        case ("TAB", _): glyph = .sixStringTabClef; originY = 2
        default: glyph = .unpitchedPercussionClef1; originY = 2
        }
    }
}
