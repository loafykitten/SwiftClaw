import SwiftUI

/// The launch splash shown over the app while it boots. A warm, cat-themed
/// welcome: the mascot springs in over a soft gradient glow, then the wordmark
/// fades up beneath.
///
/// Purely decorative — it never blocks interaction, and the caller fades it
/// out once the minimum display window has elapsed.
struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mascotIn = false
    @State private var wordmarkIn = false

    var body: some View {
        ZStack {
            SplashBackground(colorScheme: colorScheme)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    // Soft glow anchoring the mascot to the center.
                    Circle()
                        .fill(Self.glow(for: colorScheme))
                        .frame(width: 260, height: 260)
                        .blur(radius: 40)
                        .opacity(mascotIn ? 1 : 0)

                    Image("HomeMascot")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 168, height: 168)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                        .scaleEffect(mascotIn ? 1 : 0.72)
                        .opacity(mascotIn ? 1 : 0)
                }
                .frame(height: 260)
                .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("SwiftClaw")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.wordmarkColor(for: colorScheme))

                    Text("Your AI companion")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .opacity(wordmarkIn ? 1 : 0)
                .offset(y: wordmarkIn ? 0 : 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("SwiftClaw, your AI companion")
            }
            .padding(40)
        }
        .onAppear(perform: animateIn)
    }

    private func animateIn() {
        guard !reduceMotion else {
            mascotIn = true
            wordmarkIn = true
            return
        }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) {
            mascotIn = true
        }
        withAnimation(.easeOut(duration: 0.45).delay(0.32)) {
            wordmarkIn = true
        }
    }

    // MARK: - Palette

    private static func glow(for scheme: ColorScheme) -> RadialGradient {
        let tint = scheme == .dark
            ? Color(red: 0.98, green: 0.60, blue: 0.32)
            : Color(red: 1.0, green: 0.78, blue: 0.52)
        return RadialGradient(
            colors: [tint.opacity(scheme == .dark ? 0.45 : 0.55), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 130
        )
    }

    private static func wordmarkColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.90, blue: 0.82)
            : Color(red: 0.36, green: 0.20, blue: 0.12)
    }
}

/// The warm, adaptive backdrop — cream by day, deep cocoa by night.
private struct SplashBackground: View {
    let colorScheme: ColorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.16, green: 0.12, blue: 0.10), Color(red: 0.09, green: 0.07, blue: 0.07)]
                : [Color(red: 1.0, green: 0.97, blue: 0.92), Color(red: 1.0, green: 0.90, blue: 0.80)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview("Light") {
    SplashView()
        .preferredColorScheme(.light)
        .frame(width: 520, height: 600)
}

#Preview("Dark") {
    SplashView()
        .preferredColorScheme(.dark)
        .frame(width: 520, height: 600)
}
