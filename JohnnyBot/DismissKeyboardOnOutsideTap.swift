#if os(iOS)
import SwiftUI
import UIKit

struct DismissKeyboardOnOutsideTap: UIGestureRecognizerRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var editor: UIResponder?

        private func focusedEditor(in view: UIView) -> UIResponder? {
            if view.isFirstResponder,
               view is UITextField || (view as? UITextView)?.isEditable == true { return view }
            for child in view.subviews {
                if let editor = focusedEditor(in: child) { return editor }
            }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let candidate = view {
                if candidate is UITextField || (candidate as? UITextView)?.isEditable == true {
                    return false
                }
                view = candidate.superview
            }
            editor = touch.window.flatMap { focusedEditor(in: $0) }
            return editor != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer()
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        return tap
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        // A long press may have already transferred focus to a read-only selection.
        if let editor = context.coordinator.editor, editor.isFirstResponder {
            editor.resignFirstResponder()
        }
    }
}
#endif
