import Foundation

/// A tempo that takes effect at a position within a measure.
public struct TempoEvent: Sendable, Hashable {
    public var measureIndex: Int
    /// Quarters into the measure (`TempoDirection.soundPosition`).
    public var position: Rational
    /// Playback tempo in beats per minute, the way the web app reads it.
    public var bpm: Double
}

/// The tempo marks of a score, by measure index.
///
/// Reading follows OSMD (the web app):
/// - a `<sound tempo>` wins over a `<metronome>` mark in the same direction (MusicXML spec,
///   OSMD 2.2.0); it is rounded to a whole number;
/// - a `<metronome>` alone gives its raw `per-minute` as the tempo: the beat unit and dots
///   are ignored (`Metronome.quarterBPM` is for display only);
/// - a `<sound>` directly in a measure counts only in measure index 0;
/// - a tempo word ("Largo", `TempoWords`) with no `<sound tempo>` and no metronome mark of any kind
///   anywhere earlier in the score plays the word table's tempo (Largo 52, from OSMD's table); once a
///   sound tempo or metronome has been seen, words change nothing;
/// - a tempo applies from its position; with none the tempo is 100.
///
/// Where OSMD is plainly wrong ScoreKit differs (see `TimelineParityTests`):
/// - an invalid or zero `tempo` is ignored (OSMD resets "fast" to 100; its walk reports 0 for
///   "0", which the web's score layer then ignores too).
/// A direction's `<offset>` is ignored without `sound="yes"`; OSMD 2.2.0 agrees.
public struct TempoMap: Sendable {
    public static let defaultBPM = 100.0

    /// Events per measure index, ordered by position (document order breaks ties).
    public let events: [[TempoEvent]]

    public init(score: Score) {
        let n = score.parts.map(\.measures.count).max() ?? 0
        var events = [[TempoEvent]](repeating: [], count: n)
        // The earliest sound or metronome tempo anywhere in the score: a word is only used before it.
        var firstMarked: (Int, Rational)?
        for part in score.parts {
            for m in part.measures {
                for d in m.directions where Self.bpm(of: d, measureIndex: m.index) != nil {
                    let k = (m.index, max(.zero, d.soundPosition))
                    if firstMarked.map({ k < $0 }) ?? true { firstMarked = k }
                }
            }
        }
        for part in score.parts {
            for m in part.measures where m.index < n {
                for w in m.tempoWords where firstMarked.map({ (m.index, w.onset) < ($0.0, $0.1) }) ?? true {
                    events[m.index].append(TempoEvent(measureIndex: m.index, position: max(.zero, w.onset), bpm: w.bpm))
                }
                for d in m.directions {
                    guard let bpm = Self.bpm(of: d, measureIndex: m.index) else { continue }
                    events[m.index].append(TempoEvent(measureIndex: m.index, position: max(.zero, d.soundPosition), bpm: bpm))
                }
            }
        }
        self.events = events.map { list in
            list.enumerated().sorted { a, b in
                a.element.position != b.element.position ? a.element.position < b.element.position : a.offset < b.offset
            }.map(\.element)
        }
    }

    /// The tempo a direction sets, nil when it sets none.
    static func bpm(of d: TempoDirection, measureIndex: Int) -> Double? {
        if d.source == .standaloneSound && measureIndex != 0 { return nil }
        if let t = d.soundTempo, t.rounded() >= 1 { return t.rounded() }
        return d.metronome?.perMinute
    }
}

/// A table of Italian, German, French and English tempo words, taken from OSMD's
/// `InstantaneousTempoExpression` (so the web and ScoreKit agree on the tempos).
public enum TempoWords {
    /// Table order breaks ties between equally long matches.
    static let table: [(bpm: Double, words: [String])] = [
        (20, ["Larghissimo", "Sehr breit", "very, very slow"]),
        (30, ["Grave", "Schwer", "slow and solemn"]),
        (48, ["Lento", "Lent", "Langsam", "slowly"]),
        (52, ["Largo", "Breit", "broadly"]),
        (63, ["Larghetto", "Etwas breit", "rather broadly"]),
        (70, ["Adagio", "Langsam", "Ruhig", "slow and stately"]),
        (75, ["Adagietto", "Ziemlich ruhig", "Ziemlich langsam", "rather slow"]),
        (88, ["Andante moderato"]),
        (92, ["Andante", "Gehend", "Schreitend", "at a walking pace"]),
        (96, ["Andantino", "Maestoso"]),
        (106, ["Moderato", "M\u{E4}\u{DF}ig", "Mod\u{E9}r\u{E9}", "moderately"]),
        (112, ["Allegretto", "Animato", "fast"]),
        (118, ["Allegro moderato"]),
        (130, ["Allegro", "Rapide", "Vite", "Rasch", "Schnell", "Fr\u{F6}hlich"]),
        (140, ["Vivace", "Allegro Assai", "Lebhaft", "Lebendig", "lively and fast"]),
        (155, ["Vivacissimo", "Sehr lebhaft", "Sehr lebendig"]),
        (170, ["Allegrissimo", "very fast"]),
        (184, ["Presto", "Sehr schnell", "Geschwind"]),
        (200, ["Prestissimo", "\u{E4}u\u{DF}erst schnell"]),
    ]

    /// Words that make a phrase relative to the current tempo ("pi\u{F9} mosso", "un peu plus vite").
    static let relative: Set<String> = ["pi\u{F9}", "piu", "meno", "plus", "moins", "peu", "mehr", "weniger"]

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// The tempo for a tempo word, nil when the text has none. The phrase is matched on word
    /// boundaries ("Allegro," and "Allegro." match); the longest phrase wins ("Allegro moderato" is 118,
    /// not Allegro or Moderato), the table's order breaks ties. Relative phrases ("pi\u{F9} mosso") have none.
    public static func bpm(of text: String) -> Double? {
        let t = tokens(text)
        if t.contains(where: relative.contains) { return nil }
        var best: (len: Int, bpm: Double)?
        for (bpm, words) in table {
            for w in words {
                let p = tokens(w)
                guard !p.isEmpty, p.count <= t.count,
                      (0...(t.count - p.count)).contains(where: { Array(t[$0..<($0 + p.count)]) == p }) else { continue }
                if best == nil || p.count > best!.len { best = (p.count, bpm) }
            }
        }
        return best?.bpm
    }
}
