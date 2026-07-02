import SwiftUI

struct ComposerDropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.72),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )

            Image(systemName: "photo.badge.plus")
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                .shadow(color: Color.accentColor.opacity(0.38), radius: 12)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ComposerIconButton: View {
    let systemName: String
    let size: CGFloat
    var isSelected = false
    var isDisabled = false
    let helpText: String
    let accessibilityLabel: String
    let action: () -> Void

    private var foregroundStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(foregroundStyle)
                .composerControlHoverEffect(
                    width: size,
                    height: size,
                    isSelected: isSelected,
                    isDisabled: isDisabled,
                    hoverScale: 1.08
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct ComposerSendButton: View {
    let size: CGFloat
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .composerControlHoverEffect(
                    width: size,
                    height: size,
                    isDisabled: isDisabled,
                    hoverScale: 1.08
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help("Send message")
        .accessibilityLabel("Send message")
    }
}

enum ComposerModelSelection {
    static let swiftModel = "settings.home.modelPreset.swift"
    static let clawModel = "settings.home.modelPreset.claw"
}

struct ComposerModelOption: Identifiable {
    let title: String
    let selection: String

    var id: String { selection }
}

struct ComposerModelSelectionMenu: View {
    let selectedModelTitle: String
    let activeModelSelection: String
    let effectiveModel: String?
    let availableModels: [String]
    let quickModelOptions: [ComposerModelOption]
    let width: CGFloat
    let height: CGFloat
    let isDisabled: Bool
    let onSelect: (String) -> Void

    private var isQuickModelSelection: Bool {
        activeModelSelection == ComposerModelSelection.swiftModel
            || activeModelSelection == ComposerModelSelection.clawModel
    }

    var body: some View {
        Menu {
            ForEach(quickModelOptions) { option in
                Button {
                    onSelect(option.selection)
                } label: {
                    if activeModelSelection == option.selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }

            if !quickModelOptions.isEmpty {
                Divider()
            }

            ForEach(availableModels, id: \.self) { model in
                Button {
                    onSelect(model)
                } label: {
                    if !isQuickModelSelection, model == effectiveModel {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedModelTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(width: width, height: height, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuIndicator(.hidden)
        .disabled(isDisabled)
        .frame(height: height, alignment: .center)
        .pointingHandCursor(isDisabled: isDisabled)
        .help("Model")
        .accessibilityLabel("Model \(selectedModelTitle)")
    }
}

struct ComposerReasoningMenu: View {
    let selectedReasoningEffort: ModelReasoningEffort
    let width: CGFloat
    let height: CGFloat
    let isDisabled: Bool
    let onSelect: (ModelReasoningEffort) -> Void

    var body: some View {
        Menu {
            ForEach(ModelReasoningEffort.selectableCases) { effort in
                Button {
                    onSelect(effort)
                } label: {
                    if selectedReasoningEffort == effort {
                        Label(effort.displayName, systemImage: "checkmark")
                    } else {
                        Text(effort.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(selectedReasoningEffort.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(width: width, height: height, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuIndicator(.hidden)
        .disabled(isDisabled)
        .frame(height: height, alignment: .center)
        .pointingHandCursor(isDisabled: isDisabled)
        .help("Reasoning effort")
        .accessibilityLabel("Reasoning effort \(selectedReasoningEffort.displayName)")
    }
}

extension View {
    func composerControlHoverEffect(
        width: CGFloat,
        height: CGFloat,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        hoverScale: CGFloat = 1.03
    ) -> some View {
        modifier(
            ComposerControlHoverEffect(
                width: width,
                height: height,
                isSelected: isSelected,
                isDisabled: isDisabled,
                hoverScale: hoverScale
            )
        )
    }

    func pointingHandCursor(isDisabled: Bool = false) -> some View {
        modifier(PointingHandCursor(isDisabled: isDisabled))
    }
}

private struct ComposerControlHoverEffect: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    var isSelected = false
    var isDisabled = false
    var cornerRadius: CGFloat = 6
    var hoverScale: CGFloat = 1.03

    @State private var isHovering = false

    private var isHoverActive: Bool {
        isHovering && !isDisabled
    }

    private var isActive: Bool {
        !isDisabled && (isHovering || isSelected)
    }

    private var fillOpacity: Double {
        if isSelected {
            return isHoverActive ? 0.26 : 0.18
        }

        return isHoverActive ? 0.12 : 0
    }

    private var strokeOpacity: Double {
        isActive ? 0.22 : 0
    }

    func body(content: Content) -> some View {
        content
            .frame(width: width, height: height, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(fillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor.opacity(strokeOpacity), lineWidth: 1)
            }
            .shadow(
                color: Color.accentColor.opacity(isHoverActive ? 0.14 : 0),
                radius: isHoverActive ? 6 : 0,
                x: 0,
                y: isHoverActive ? 2 : 0
            )
            .scaleEffect(isHoverActive ? hoverScale : 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

private struct PointingHandCursor: ViewModifier {
    let isDisabled: Bool

    @State private var didPushCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                updateCursor(isInside: isInside)
            }
            .onChange(of: isDisabled) { _, isDisabled in
                if isDisabled {
                    popCursorIfNeeded()
                }
            }
            .onDisappear {
                popCursorIfNeeded()
            }
    }

    private func updateCursor(isInside: Bool) {
        #if os(macOS)
        if isInside, !isDisabled {
            guard !didPushCursor else {
                return
            }

            NSCursor.pointingHand.push()
            didPushCursor = true
        } else {
            popCursorIfNeeded()
        }
        #endif
    }

    private func popCursorIfNeeded() {
        #if os(macOS)
        guard didPushCursor else {
            return
        }

        NSCursor.pop()
        didPushCursor = false
        #endif
    }
}
