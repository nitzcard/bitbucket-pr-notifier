import SwiftUI

extension View {
    /// Native-menu-style hover: accent background with white text. Child views
    /// using `.secondary` styles follow along automatically.
    func menuItemHover(selected: Bool = false) -> some View {
        modifier(MenuItemHover(selected: selected))
    }

    /// Subtle rounded highlight for small icon buttons.
    func iconHover() -> some View {
        modifier(IconHover())
    }
}

private struct MenuItemHover: ViewModifier {
    var selected: Bool
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(hovering ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var background: Color {
        if hovering { return .accentColor }
        return selected ? Color.accentColor.opacity(0.2) : .clear
    }
}

private struct IconHover: ViewModifier {
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(hovering ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
