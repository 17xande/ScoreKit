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
/// - a `<metronome>` mark wins over `<sound tempo>` in the same direction, and
///   its raw `per-minute` is the tempo: the beat unit and dots are ignored;
/// - a `<sound tempo>` is rounded to a whole number;
/// - a `<sound>` directly in a measure counts only in measure index 0;
/// - a tempo applies from its position; with none the tempo is 100.
///
/// Where OSMD is plainly wrong ScoreKit differs (see `TimelineParityTests`):
/// - an invalid or zero `tempo` is ignored (OSMD resets to 100, or 60 for "0");
/// - a direction's `<offset>` moves the tempo only with `sound="yes"`, and a
///   `<sound><offset>` always does (MusicXML spec). OSMD instead shifts a measure-start
///   tempo by any direction offset and loses a mid-measure one altogether.
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
        if let pm = d.metronome?.perMinute { return pm }
        if let t = d.soundTempo {
            let r = t.rounded()
            return r >= 1 ? r : nil
        }
        return nil
    }
}
