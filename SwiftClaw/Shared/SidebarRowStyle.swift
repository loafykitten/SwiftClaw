import SwiftUI

private struct SidebarRowStateModifier: ViewModifier {
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                isEmphasized ? Color.accentColor.opacity(0.07) : Color.clear
            )
            .contentShape(Rectangle())
    }
}

extension View {
    func sidebarRowState(isEmphasized: Bool = false) -> some View {
        modifier(SidebarRowStateModifier(isEmphasized: isEmphasized))
    }
}
