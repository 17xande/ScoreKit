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
        for part in score.parts {
            for m in part.measures where m.index < n {
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
