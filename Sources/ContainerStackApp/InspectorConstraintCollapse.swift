import AppKit
import SwiftUI

/// With the default collapse behavior, a window at its minimum width shifts the sidebar left while the inspector opens.
struct InspectorConstraintCollapse: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            var view = superview
            while let current = view {
                if let controller = (current as? NSSplitView)?.delegate as? NSSplitViewController {
                    for item in controller.splitViewItems where item.behavior == .inspector {
                        item.collapseBehavior = .useConstraints
                    }
                }
                view = current.superview
            }
        }
    }
}
