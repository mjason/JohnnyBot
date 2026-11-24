import SwiftUI

extension View {
    func workspaceTabHighlight(selected: Bool, hovered: Bool) -> some View {
        background {
            if selected {
                Capsule().fill(.quaternary)
            } else if hovered {
                Capsule().fill(.quinary)
            }
        }
    }
}
