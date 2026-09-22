import SwiftUI
import AppKit

/// Sits over a grid cell and turns a drag into a real file drag — the same pasteboard content Finder produces, which is what
/// Premiere, Resolve and Final Cut accept on their timelines and bins. SwiftUI's `onDrag` carries one item; this carries the
/// whole selection. Clicks pass back out through `onClick` because the view has to own the mouse to tell a click from a drag.
struct ClipDragSource: NSViewRepresentable {
    /// Files to drag, in order, with the image shown for each. Empty cancels the drag (footage offline).
    let items: () -> [(url: URL, image: NSImage?)]
    let onClick: (_ clickCount: Int, _ modifiers: NSEvent.ModifierFlags) -> Void
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.items = items; view.onClick = onClick; view.menuProvider = menu
    }

    final class SourceView: NSView, NSDraggingSource {
        var items: () -> [(url: URL, image: NSImage?)] = { [] }
        var onClick: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
        var menuProvider: () -> NSMenu? = { nil }
        private var mouseDownEvent: NSEvent?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            dragging = false
            // Select on the way down, as Finder does, unless that would collapse a multi-selection about to be dragged.
            if event.clickCount == 1, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) { onClick(0, []) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let down = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 16 else { return }
            let files = items()
            guard !files.isEmpty else { return }
            dragging = true

            let origin = convert(down.locationInWindow, from: nil)
            let dragItems: [NSDraggingItem] = files.prefix(40).enumerated().map { index, file in
                let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                let image = file.image ?? NSWorkspace.shared.icon(forFile: file.url.path)
                let width: CGFloat = 132, height = width * image.size.height / max(image.size.width, 1)
                let offset = CGFloat(min(index, 4)) * 5
                item.setDraggingFrame(NSRect(x: origin.x - width / 2 + offset, y: origin.y - height / 2 - offset, width: width, height: height), contents: image)
                return item
            }
            // Beyond 40 the files still travel; they just don't each get a picture.
            let extra = files.dropFirst(40).map { NSDraggingItem(pasteboardWriter: $0.url as NSURL) }
            for item in extra { item.setDraggingFrame(NSRect(x: origin.x, y: origin.y, width: 1, height: 1), contents: nil) }
            let session = beginDraggingSession(with: dragItems + extra, event: down, source: self)
            session.draggingFormation = .stack
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownEvent = nil }
            guard !dragging else { return }
            if event.clickCount >= 2 { onClick(2, event.modifierFlags) }
            else if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) { onClick(1, event.modifierFlags) }
            else { onClick(1, []) }
        }

        override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}

/// Closure-backed menu items, so a context menu can be built where the data is.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
