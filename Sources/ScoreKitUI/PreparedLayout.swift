#if canImport(SwiftUI)
import CoreGraphics
import Foundation
import ScoreKit
import SwiftUI

/// How items that belong to a chord or rest as a whole (stems, shared ledger lines, flags)
/// are coloured.
public enum GroupColorPolicy: Sendable, Hashable {
    /// The first marked member's colour (ascending staff position), else the ink.
    case firstMarkedMember
    /// Always the ink.
    case ink
}

/// A `ScoreLayout` plus what the renderer derives from it once: each item's horizontal extent
/// (for culling) and the shared-head lookup. Immutable; identity is the cache key, so views
/// compare layouts by `===`.
public final class PreparedLayout: Sendable {
    public let layout: ScoreLayout

    struct Entry: Sendable {
        var item: LayoutItem
        var minX: Double
        var maxX: Double
    }

    let systems: [[Entry]]
    /// A note that owns a shared head to the notes that share it.
    let headSharers: [NoteID: [NoteID]]
    /// Per system: the notes whose marks can colour its items (see `ScoreCanvas`).
    let systemNoteIDs: [Set<NoteID>]

    public init(layout: ScoreLayout) {
        self.layout = layout
        systems = layout.systems.map { sys in
            sys.items.map { item in
                let b = item.bounds
                // Padded: glyph boxes and estimated text widths are approximate.
                return Entry(item: item, minX: b.isNull ? -.infinity : b.minX - 2, maxX: b.isNull ? .infinity : b.maxX + 2)
            }
        }
        var sharers: [NoteID: [NoteID]] = [:]
        for (second, first) in layout.sharedHeads { sharers[first, default: []].append(second) }
        headSharers = sharers
        // The notes whose marks can colour each system's items: owners, group members, and
        // notes sharing an owner's head.
        systemNoteIDs = systems.map { entries in
            var ids = Set<NoteID>()
            func add(_ n: NoteID) { ids.insert(n); sharers[n]?.forEach { ids.insert($0) } }
            for e in entries {
                if let n = e.item.noteID { add(n) }
                if e.item.noteID == nil, let g = e.item.groupID { (layout.groups[g] ?? [g]).forEach(add) }
            }
            return ids
        }
    }

    public var size: CGSize { layout.size }

    // MARK: Regions

    /// Vertical ink margin around a lone system (line mode), in staff spaces.
    static let inkPad = 3.0

    /// The part of the layout a page-mode row covers: the full width, from half way to the
    /// system above to half way to the system below (so rows never overlap, and ink that
    /// overflows the frame is still drawn).
    public func pageRow(_ index: Int) -> CGRect {
        let systems = layout.systems
        guard systems.indices.contains(index) else { return .zero }
        let f = systems[index].frame
        let top = index == 0 ? 0 : (systems[index - 1].frame.maxY + f.minY) / 2
        let bottom = index + 1 < systems.count ? (f.maxY + systems[index + 1].frame.minY) / 2 : max(layout.size.height, f.maxY)
        return CGRect(x: 0, y: top, width: layout.size.width, height: max(0, bottom - top))
    }

    /// The full extent of a lone system, with a vertical ink margin (line mode).
    public func lineRegion(_ index: Int = 0) -> CGRect {
        guard layout.systems.indices.contains(index) else { return .zero }
        let f = layout.systems[index].frame
        return CGRect(x: 0, y: f.minY - Self.inkPad, width: layout.size.width, height: f.height + 2 * Self.inkPad)
    }

    // MARK: Colouring

    /// The colour of an item under the documented policy (see `LayoutItem`).
    func color(of item: LayoutItem, ink: Color, marks: [NoteID: Color], policy: GroupColorPolicy) -> Color {
        if marks.isEmpty { return ink }
        switch item {
        case .text, .beam: return ink
        default: break
        }
        if let n = item.noteID {
            // A shared head belongs to the first note but shows either note's mark; its
            // accidental, dots and fingering are the first note's alone.
            if case .glyph(let cp, _, _, _, _) = item, (0xE0A0...0xE1FF).contains(cp) {
                return marks[n] ?? sharedMark(n, marks) ?? ink
            }
            return marks[n] ?? ink
        }
        if let g = item.groupID, policy == .firstMarkedMember {
            for m in layout.groups[g] ?? [g] {
                if let c = marks[m] ?? sharedMark(m, marks) { return c }
            }
        }
        return ink
    }

    private func sharedMark(_ n: NoteID, _ marks: [NoteID: Color]) -> Color? {
        if let others = headSharers[n] {
            for o in others { if let c = marks[o] { return c } }
        }
        return nil
    }
}

#endif
