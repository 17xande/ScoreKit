#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// Press, hold (about 0.5 s within 8 pt), then drag over the score: a `UILongPressGestureRecognizer` on
/// the window, limited to this view's frame, so it runs alongside the score's scroll view, taps and
/// pinch. A quick tap, an ordinary drag and a pinch never reach it (the recogniser fails when the
/// finger moves before the hold). Once it begins, the scroll view's pan is off, the content point
/// under the finger is reported (`toContent` turns a point in this view and, in a scroll view, in its
/// content into content points), and near an edge the content scrolls. A second finger cancels.
struct SelectCatcher: UIViewRepresentable {
    /// Page mode: the content is a `UIScrollView` found above the touch, scrolled for the vertical auto-scroll.
    var usesScrollView: Bool
    /// Line mode: scrolls the content sideways by this many points (positive: towards the end).
    var scrollX: ((Double) -> Void)?
    /// A point in this view and, when `usesScrollView`, in the scroll view's content, to content points.
    var toContent: (CGPoint, CGPoint?) -> CGPoint
    var onBegin: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onEnd: () -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> SelectCatcherView {
        let v = SelectCatcherView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: SelectCatcherView, context: Context) { v.config = self }
}

final class SelectCatcherView: UIView, UIGestureRecognizerDelegate {
    var config: SelectCatcher?

    private lazy var press: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        g.minimumPressDuration = 0.5
        g.allowableMovement = 8
        g.delegate = self
        return g
    }()
    private weak var host: UIWindow?
    private weak var scroll: UIScrollView?
    private var timer: Timer?
    private var active = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if host !== window {
            host?.removeGestureRecognizer(press)
            window?.addGestureRecognizer(press)
            host = window
        }
    }

    // MARK: Delegate

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if active { cancel(); return false } // a second finger
        let inside = window != nil && bounds.contains(touch.location(in: self))
        if inside, g.state == .possible {
            var v = touch.view
            while let view = v, !(view is UIScrollView) { v = view.superview }
            scroll = v as? UIScrollView
        }
        return inside
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Action

    private func content() -> CGPoint? {
        guard let config else { return nil }
        let inScroll = config.usesScrollView ? scroll.map { press.location(in: $0) } : nil
        return config.toContent(press.location(in: self), inScroll)
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            guard let p = content() else { return }
            active = true
            scroll?.panGestureRecognizer.isEnabled = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            config?.onBegin(p)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        case .changed:
            guard active else { return }
            if g.numberOfTouches > 1 { cancel(); return }
            if let p = content() { config?.onMove(p) }
        case .ended:
            guard active else { return }
            finish()
            config?.onEnd()
        case .cancelled, .failed:
            if active { cancel() }
        default: break
        }
    }

    /// Scrolls when the finger is near an edge of this view, then reports the point under it.
    private func tick() {
        guard active, let config else { return }
        let p = press.location(in: self)
        let edge = 48.0
        func speed(_ pos: Double, _ length: Double) -> Double {
            pos < edge ? -ceil((edge - pos) / 4) : pos > length - edge ? ceil((pos - (length - edge)) / 4) : 0
        }
        let dy = speed(p.y, bounds.height), dx = speed(p.x, bounds.width)
        if dy != 0, config.usesScrollView, let sv = scroll {
            let maxY = max(0, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
            let y = min(max(-sv.adjustedContentInset.top, sv.contentOffset.y + dy), maxY)
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: y), animated: false)
        }
        if dx != 0 { config.scrollX?(dx) }
        if dx != 0 || dy != 0, let c = content() { config.onMove(c) }
    }

    private func finish() {
        active = false
        timer?.invalidate()
        timer = nil
        scroll?.panGestureRecognizer.isEnabled = true
    }

    private func cancel() {
        guard active else { return }
        finish()
        press.isEnabled = false // ends the recogniser's current touch
        press.isEnabled = true
        config?.onCancel()
    }
}
#endif
