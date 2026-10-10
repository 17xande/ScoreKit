
import Foundation
import Testing
@testable import ScoreKit

private let frames = [
    MeasureFrame(index: 0, minX: 0, maxX: 10, minY: 0, maxY: 10),
    MeasureFrame(index: 1, minX: 10, maxX: 20, minY: 0, maxY: 10),
    MeasureFrame(index: 2, minX: 0, maxX: 10, minY: 30, maxY: 40),
]

@Test("measure selection: a point inside a frame is that measure; strays snap to the nearest system, then frame")
func selectionPointToMeasure() {
    #expect(MeasureSelection.measure(at: CGPoint(x: 15, y: 5), in: frames) == 1)
    #expect(MeasureSelection.measure(at: CGPoint(x: 50, y: 5), in: frames) == 1)
    #expect(MeasureSelection.measure(at: CGPoint(x: -9, y: 2), in: frames) == 0)
    #expect(MeasureSelection.measure(at: CGPoint(x: 15, y: 28), in: frames) == 2)
    #expect(MeasureSelection.measure(at: CGPoint(x: 5, y: 14), in: frames) == 0)
    #expect(MeasureSelection.measure(at: .zero, in: []) == nil)
}

@Test("measure selection: span orders either way; outside is empty for the whole piece")
func selectionSpanAndOutside() {
    #expect(MeasureSelection.span(5, 2) == 2...5)
    #expect(MeasureSelection.span(3, 3) == 3...3)
    #expect(MeasureSelection.outside(count: 6, from: nil, to: nil).isEmpty)
    #expect(MeasureSelection.outside(count: 6, from: 1, to: 6).isEmpty)
    #expect(MeasureSelection.outside(count: 6, from: 2, to: 4) == [0, 4, 5])
    #expect(MeasureSelection.outside(count: 6, from: nil, to: 3) == [3, 4, 5])
    #expect(MeasureSelection.outside(count: 6, from: 4, to: nil) == [0, 1, 2])
}

@Test("measure frames: one per laid-out measure, in layout order, spanning the staves")
func selectionFramesFromLayout() throws {
    let score = try Score.load(data: fixture("minuet-in-g.musicxml"))
    let l = Engraver.layout(score, options: LayoutOptions(width: .singleLine))
    let f = l.measureFrames
    #expect(f.count == score.parts[0].measures.count)
    #expect(f.map(\.index) == Array(0..<f.count))
    #expect(f.allSatisfy { $0.maxX > $0.minX && $0.maxY - $0.minY > 8 })
    let mid = f[3]
    #expect(MeasureSelection.measure(at: CGPoint(x: (mid.minX + mid.maxX) / 2, y: (mid.minY + mid.maxY) / 2), in: f) == 3)
}
