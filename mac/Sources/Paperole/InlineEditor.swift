import AppKit
import SwiftUI

/// A text editor inside a card that grows from `minLines` to `maxLines` (UX.md §8). Return adds a line, ⌘↩ submits,
/// Esc cancels, and focus leaving it calls `onFocusLost`. While an input method has marked text, ⌘↩ and Esc go to the
/// input method. An editor opened for one edit (`autoFocus`) takes focus once it is shown; the follow-up field
/// (`autoFocus` false) takes it only while `wantsFocus` (R, Return), or from a click, never from a selection. Each
/// editor keeps its own typing undo, so ⌘Z there never reaches another card's text; text the app puts in it (Discard)
/// clears that undo.
struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 13)
    var minLines = 3
    var maxLines = 12
    var autoFocus = true
    var wantsFocus = false
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onFocus: (() -> Void)? = nil
    var onFocusLost: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = EditorTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = font
        tv.textColor = .textColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.string = text
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? EditorTextView else { return }
        if tv.string != text, !tv.hasMarkedText() {
            // text the app put there (Discard): the typing undo is of the old text, and ⌘Z on it raised NSRangeException
            tv.string = text
            context.coordinator.undo.removeAllActions()
        }
        if wantsFocus, tv.window != nil, tv.window?.firstResponder !== tv { tv.takeFocus(tries: 10) }
    }

    /// Measured on a layout of its own (`Coordinator.measure`): resizing the shown text's container while SwiftUI
    /// measured made the editor's scroll view lay out again, which asked SwiftUI to measure again, at another width
    /// when the card's stacks tried several, without end (seen when the panel came back after Focus, POLISH §4.3).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView sv: NSScrollView, context: Context) -> CGSize? {
        guard let tv = sv.documentView as? NSTextView, let tc = tv.textContainer else { return nil }
        let width = proposal.width ?? 300
        let (line, used) = context.coordinator.measure(tv.string, font: font, padding: tc.lineFragmentPadding,
                                                       width: max(width - 2 * tv.textContainerInset.width, 10))
        let h = min(max(used, line * CGFloat(minLines)), line * CGFloat(maxLines)) + 2 * tv.textContainerInset.height
        return CGSize(width: width, height: ceil(h))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextEditor
        let undo = UndoManager()
        init(_ p: InlineTextEditor) { parent = p }

        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer()
        /// The heights measured for the text and font laid out, by width (SwiftUI asks the same widths again).
        private var measured: (text: String, font: NSFont, padding: CGFloat, heights: [CGFloat: (CGFloat, CGFloat)])?

        /// The text's line height and the height it takes at `width`, laid out apart from the shown text view.
        func measure(_ text: String, font: NSFont, padding: CGFloat, width: CGFloat) -> (line: CGFloat, used: CGFloat) {
            if let m = measured, m.text == text, m.font == font, m.padding == padding, let h = m.heights[width] { return h }
            if layout.textContainers.isEmpty {
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
            }
            if measured?.text != text || measured?.font != font {
                storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                measured = (text, font, padding, [:])
            }
            if measured?.padding != padding { measured = (text, font, padding, [:]) }
            container.lineFragmentPadding = padding
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let h = (layout.defaultLineHeight(for: font), layout.usedRect(for: container).height)
            measured?.heights[width] = h
            return h
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    final class EditorTextView: NSTextView {
        weak var coordinator: Coordinator?
        private var closing = false
        private var focused = false  // an `autoFocus` editor takes focus once per appearance

        override func keyDown(with event: NSEvent) {
            guard !hasMarkedText(), let c = coordinator else { return super.keyDown(with: event) }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if (event.keyCode == 36 || event.keyCode == 76) && mods == .command {
                return c.parent.onSubmit()
            }
            if event.keyCode == 53 && mods.isEmpty {
                return c.parent.onCancel()
            }
            super.keyDown(with: event)
        }

        override func cancelOperation(_ sender: Any?) {
            if hasMarkedText() { return super.cancelOperation(sender) }
            coordinator?.parent.onCancel()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // The list may keep this view and show it again for the next edit: it takes focus again then.
            closing = newWindow == nil
            if closing { focused = false }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, wanted { takeFocus(tries: 10) }
        }

        private var wanted: Bool {
            guard let p = coordinator?.parent else { return false }
            return p.autoFocus && !focused || p.wantsFocus
        }

        /// Takes focus with the caret at the end. The view can leave the window and come back while the list rebuilds
        /// the row, so focus counts only once the window has accepted it.
        func takeFocus(tries: Int) {
            guard !closing, tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, !self.closing, self.wanted else { return }
                if let w = self.window, w.firstResponder === self || w.makeFirstResponder(self) && w.firstResponder === self {
                    self.focused = true
                    self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
                } else {
                    self.takeFocus(tries: tries - 1)
                }
            }
        }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok, let c = coordinator, let f = c.parent.onFocus { DispatchQueue.main.async { f() } }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok && !closing, let c = coordinator {
                DispatchQueue.main.async { c.parent.onFocusLost() }
            }
            return ok
        }
    }
}
