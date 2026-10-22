import SwiftUI

// MARK: - Live Badge

public struct LiveBadge: View {
    @State private var isPulsing = false

    public init() {}

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(Color.Ring.live)
                .frame(width: 7, height: 7)
                .opacity(isPulsing ? 0.5 : 1.0)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial.opacity(0.6))
        .background(Color.black.opacity(0.35))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: RingAnimation.pulseDuration).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

#if DEBUG
#Preview("Live Badge") {
    LiveBadge()
        .padding()
        .background(Color.black)
}
#endif
