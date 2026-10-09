#if canImport(SwiftUI)
import Foundation
import ScoreKit

/// Where the cursor sits, independent of any layout: a measure and the quarters into it (a
/// timeline entry's `measureIndex` and `position`). `ScoreView` resolves it with its own
/// layout, which the caller never sees and which reflows with width, zoom and mode.
public struct ScoreCursor: Sendable, Hashable {
    public var measureIndex: Int
    public var position: Rational

    public init(measureIndex: Int, position: Rational) {
        self.measureIndex = measureIndex; self.position = position
    }

    public init(entry: TimelineEntry) {
        self.init(measureIndex: entry.measureIndex, position: entry.position)
    }
}

/// One frame of a glide, in layout-independent terms: `fraction` (0...1) of the way from the
/// timeline entry `from` to the next entry `to` (nil for the last entry, which glides toward
/// the end of its shortest note). See `ScoreLayout.glideSpot`.
public struct CursorFrame: Sendable {
    public var from: TimelineEntry
    public var to: TimelineEntry?
    public var fraction: Double

    public init(from: TimelineEntry, to: TimelineEntry?, fraction: Double) {
        self.from = from; self.to = to; self.fraction = fraction
    }
}

/// A glide from one entry to the next that starts at `start` and lasts `duration` seconds,
/// timed by the display clock. The caller starts one per step (an audio-clock-derived `start`
/// keeps it in sync); `ScoreView` computes the fraction on every display frame itself.
public struct CursorGlide: Sendable {
    public var from: TimelineEntry
    public var to: TimelineEntry?
    public var start: Date
    public var duration: TimeInterval

    public init(from: TimelineEntry, to: TimelineEntry?, start: Date, duration: TimeInterval) {
        self.from = from; self.to = to; self.start = start; self.duration = duration
    }

    public func frame(at date: Date) -> CursorFrame {
        let f = duration > 0 ? date.timeIntervalSince(start) / duration : 1
        return CursorFrame(from: from, to: to, fraction: min(max(f, 0), 1))
    }
}

/// What drives the cursor.
///
/// Threading and pausing: spots are resolved on the main actor, inside a `TimelineView`. Only
/// `.glide` and `.live` tick (every display frame); `.hidden` and `.at` do not tick at all, so
/// the view is idle while playback is paused or stopped: switch the source to `.at` (or
/// `.hidden`) when a glide has finished or playback stops. A `.live` closure is called on the
/// main actor once per frame per visible row: keep it cheap and allocation-free, and have it
/// read state that is safe to read there (for example a snapshot of the audio clock).
/// Return nil to hide the cursor.
public enum CursorSource: Sendable {
    case hidden
    case at(ScoreCursor)
    case glide(CursorGlide)
    case live(@Sendable (Date) -> CursorFrame?)

    /// True when the cursor needs a frame clock.
    public var isAnimated: Bool {
        switch self {
        case .hidden, .at: false
        case .glide, .live: true
        }
    }

    /// The spot in `layout` at `date` (nil for `.hidden`, or a measure that was not laid out).
    public func spot(in layout: ScoreLayout, at date: Date) -> CursorSpot? {
        switch self {
        case .hidden: return nil
        case .at(let c): return layout.cursorSpot(measureIndex: c.measureIndex, position: c.position)
        case .glide(let g):
            let f = g.frame(at: date)
            return layout.glideSpot(from: f.from, to: f.to, fraction: f.fraction)
        case .live(let produce):
            guard let f = produce(date) else { return nil }
            return layout.glideSpot(from: f.from, to: f.to, fraction: f.fraction)
        }
    }
}
#endif
