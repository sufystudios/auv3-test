import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// A host's own keyboard, under the plugin in --play: two octaves, C3 to C5, playing
/// the plugin by MIDI as a DAW's keyboard does. Many plugins have no keys of their
/// own, and effects never do. Multi-touch on iOS; the mouse on the Mac (drag for a
/// glissando).
final class KeyboardView: PlatformView {
    static let lowest = 48, highest = 72  // C3...C5
    /// A key went down (true) or up (false). Main thread.
    var onNote: ((_ note: UInt8, _ down: Bool) -> Void)?
    private var held: Set<Int> = []

    private static func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(note % 12) }
    private var whiteNotes: [Int] { (Self.lowest...Self.highest).filter { !Self.isBlack($0) } }

    /// Each key's rectangle, in this view's coordinates with y down from the top edge
    /// of the keys (flipped on the Mac when drawing and hit-testing).
    private func layout() -> (white: [(Int, CGRect)], black: [(Int, CGRect)]) {
        let whites = whiteNotes
        let width = bounds.width / CGFloat(whites.count), height = bounds.height
        var white: [(Int, CGRect)] = [], black: [(Int, CGRect)] = []
        for (i, note) in whites.enumerated() {
            white.append((note, CGRect(x: CGFloat(i) * width, y: 0, width: width, height: height)))
            if note < Self.highest, Self.isBlack(note + 1) {
                black.append((note + 1, CGRect(x: CGFloat(i + 1) * width - width * 0.3, y: 0, width: width * 0.6, height: height * 0.6)))
            }
        }
        return (white, black)
    }

    private func note(at point: CGPoint) -> Int? {
        let (white, black) = layout()
        return black.first { $0.1.contains(point) }?.0 ?? white.first { $0.1.contains(point) }?.0
    }

    private func draw(in context: CGContext) {
        let (white, black) = layout()
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(bounds)
        for (note, rect) in white {
            context.setFillColor(held.contains(note) ? CGColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 1) : CGColor(gray: 0.95, alpha: 1))
            context.fill(rect.insetBy(dx: 1, dy: 1))
        }
        for (note, rect) in black {
            context.setFillColor(held.contains(note) ? CGColor(red: 0.3, green: 0.6, blue: 0.35, alpha: 1) : CGColor(gray: 0.1, alpha: 1))
            context.fill(rect)
        }
    }

    private func press(_ note: Int?) {
        guard let note, !held.contains(note) else { return }
        held.insert(note)
        onNote?(UInt8(note), true)
        redraw()
    }

    private func release(_ note: Int?) {
        guard let note, held.contains(note) else { return }
        held.remove(note)
        onNote?(UInt8(note), false)
        redraw()
    }

    func releaseAll() {
        for note in held { onNote?(UInt8(note), false) }
        held.removeAll()
        redraw()
    }

    #if os(macOS)
    override var isFlipped: Bool { true }
    private var mouseNote: Int?
    private func redraw() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        draw(in: context)
    }
    override func mouseDown(with event: NSEvent) {
        mouseNote = note(at: convert(event.locationInWindow, from: nil))
        press(mouseNote)
    }
    override func mouseDragged(with event: NSEvent) {
        let now = note(at: convert(event.locationInWindow, from: nil))
        guard now != mouseNote else { return }
        release(mouseNote)
        mouseNote = now
        press(now)
    }
    override func mouseUp(with event: NSEvent) {
        release(mouseNote)
        mouseNote = nil
    }
    #else
    private var touchNotes: [ObjectIdentifier: Int] = [:]
    private func redraw() { setNeedsDisplay() }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("not from a storyboard") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        draw(in: context)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let n = note(at: touch.location(in: self))
            touchNotes[ObjectIdentifier(touch)] = n
            press(n)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let n = note(at: touch.location(in: self))
            guard n != touchNotes[id] else { continue }
            if let old = touchNotes[id], !touchNotes.contains(where: { $0.key != id && $0.value == old }) { release(old) }
            touchNotes[id] = n
            press(n)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let old = touchNotes.removeValue(forKey: id), !touchNotes.values.contains(old) { release(old) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
    #endif
}
