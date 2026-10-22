import SwiftUI
import DesignSystem

/// Circular frosted-glass icon button used for controls drawn over video.
struct GlassButton: View {
    let systemName: String
    var size: CGFloat = 32
    var activeColor: Color?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(activeColor ?? .white)
                .frame(width: size, height: size)
                .background(Circle().fill((activeColor ?? .black).opacity(activeColor == nil ? 0.3 : 0.25)))
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
