import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.quoteAccentHue) private var quoteAccentHue = QuoteAccent.defaultQuoteHue
    @AppStorage(SettingsKeys.quoteAccentLightness) private var quoteAccentLightness = QuoteAccent.defaultQuoteLightness

    var body: some View {
        Form {
            Section("Theme") {
                ThemePicker(selection: $theme)
            }

            Section("Quote Accent") {
                QuoteAccentEditor(
                    hue: $quoteAccentHue,
                    lightness: $quoteAccentLightness,
                    defaultHue: QuoteAccent.defaultQuoteHue,
                    defaultLightness: QuoteAccent.defaultQuoteLightness,
                    accessibilityName: "Quote accent"
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Theme picker

private struct ThemePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 20) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOption(
                    theme: theme,
                    isSelected: selection == theme.rawValue
                ) {
                    selection = theme.rawValue
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

private struct ThemeOption: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ThemeThumbnail(theme: theme)
                    .frame(width: 84, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(
                                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.25)),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }

                Text(theme.rawValue)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.rawValue) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ThemeThumbnail: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .system:
            ZStack {
                MiniDesktop(scheme: .light)
                MiniDesktop(scheme: .dark)
                    .clipShape(DiagonalHalf())
            }
        case .light:
            MiniDesktop(scheme: .light)
        case .dark:
            MiniDesktop(scheme: .dark)
        }
    }
}

/// Clips to the bottom-right diagonal half, used for the System (auto) thumbnail.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A miniature desktop with a window, mimicking System Settings appearance tiles.
private struct MiniDesktop: View {
    let scheme: ColorScheme

    private var wallpaper: LinearGradient {
        switch scheme {
        case .dark:
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.14, blue: 0.42), Color(red: 0.05, green: 0.07, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            LinearGradient(
                colors: [Color(red: 0.62, green: 0.78, blue: 0.96), Color(red: 0.34, green: 0.56, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var windowColor: Color {
        scheme == .dark ? Color(white: 0.16) : .white
    }

    private var barColor: Color {
        scheme == .dark ? Color(white: 0.24) : Color(white: 0.93)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            wallpaper

            VStack(spacing: 0) {
                HStack(spacing: 2.5) {
                    Circle().fill(.red).frame(width: 4, height: 4)
                    Circle().fill(.yellow).frame(width: 4, height: 4)
                    Circle().fill(.green).frame(width: 4, height: 4)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(height: 10)
                .background(barColor)

                windowColor
            }
            .frame(width: 52, height: 34)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
            .padding(.leading, 10)
        }
    }
}

// MARK: - Accent color

private struct QuoteAccentEditor: View {
    @Binding var hue: Double
    @Binding var lightness: Double

    let defaultHue: Double
    let defaultLightness: Double
    var accessibilityName = "Quote accent"

    private var isDefault: Bool {
        abs(hue - defaultHue) < 0.001
            && abs(lightness - defaultLightness) < 0.001
    }

    private var hueGradient: Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
            QuoteAccent.color(hue: $0, lightness: lightness)
        })
    }

    private var lightnessGradient: Gradient {
        Gradient(colors: [
            QuoteAccent.color(hue: hue, lightness: QuoteAccent.lightnessRange.lowerBound),
            QuoteAccent.color(hue: hue, lightness: QuoteAccent.lightnessRange.upperBound),
        ])
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(QuoteAccent.color(hue: hue, lightness: lightness))
                .frame(width: 36, height: 36)
                .overlay {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }

            VStack(spacing: 10) {
                GradientSlider(
                    value: $hue,
                    range: 0...1,
                    gradient: hueGradient,
                    knobColor: QuoteAccent.color(hue: hue, lightness: lightness),
                    label: "Hue",
                    accessibilityName: accessibilityName
                )
                GradientSlider(
                    value: $lightness,
                    range: QuoteAccent.lightnessRange,
                    gradient: lightnessGradient,
                    knobColor: QuoteAccent.color(hue: hue, lightness: lightness),
                    label: "Lightness",
                    accessibilityName: accessibilityName
                )
            }

            Button("Reset") {
                hue = defaultHue
                lightness = defaultLightness
            }
            .disabled(isDefault)
        }
        .padding(.vertical, 6)
    }
}

private struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: Gradient
    let knobColor: Color
    let label: String
    let accessibilityName: String

    private let knobSize: CGFloat = 26
    private let trackHeight: CGFloat = 18

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                    .overlay {
                        Circle()
                            .stroke(knobColor, lineWidth: 3.5)
                    }
                    .offset(x: max(0, min(width - knobSize, width * fraction - knobSize / 2)))
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        let fraction = min(max(drag.location.x / width, 0), 1)
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: knobSize)
        .accessibilityElement()
        .accessibilityLabel("\(accessibilityName) \(label.lowercased())")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}
