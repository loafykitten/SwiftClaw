import SwiftUI

struct EmailQuickActionSwipe<Content: View>: View {
    let action: ReviewActionToken
    var isEnabled = true
    let onPerform: (ReviewActionToken) -> Void
    @ViewBuilder let content: () -> Content

    @State private var horizontalOffset: CGFloat = 0

    private let actionWidth: CGFloat = 100

    private var triggerDistance: CGFloat {
        actionWidth + 18
    }

    private var maxDragDistance: CGFloat {
        max(actionWidth, triggerDistance)
    }

    private var revealProgress: Double {
        min(Double(abs(horizontalOffset) / triggerDistance), 1)
    }

    var body: some View {
        ZStack {
            swipeBackground
            content()
                .offset(x: isEnabled ? horizontalOffset : 0)
                .gesture(dragGesture)
        }
        .clipShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: horizontalOffset)
    }

    private var swipeBackground: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: action.swipeSystemImage)
                    .font(.headline)
                Text(action.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(action.swipeColor.opacity(0.25 + 0.65 * revealProgress))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isEnabled && revealProgress > 0 ? 1 : 0)
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isEnabled else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                horizontalOffset = max(-maxDragDistance, min(0, value.translation.width))
            }
            .onEnded { value in
                guard isEnabled else { return }
                let shouldPerform = value.translation.width <= -triggerDistance
                horizontalOffset = 0
                guard shouldPerform else { return }
                onPerform(action)
            }
    }
}

extension ReviewActionToken {
    var swipeSystemImage: String {
        switch self {
        case .review: "envelope.open"
        case .flag: "flag.fill"
        case .reply: "arrowshape.turn.up.left.fill"
        case .delete: "trash.fill"
        case .archive: "archivebox.fill"
        }
    }

    var swipeColor: Color {
        switch self {
        case .review: .blue
        case .flag: .orange
        case .reply: .green
        case .delete: .red
        case .archive: .gray
        }
    }
}
