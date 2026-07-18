import SwiftUI
#if os(iOS)
import UIKit
#endif

struct EmailQuickActionSwipe<Content: View>: View {
    let action: ReviewActionToken
    var isEnabled = true
    var usesNativeSwipeActionsOnIOS = true
    let onPerform: (ReviewActionToken) -> Void
    @ViewBuilder let content: () -> Content

    @State private var horizontalOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?

    private let actionWidth: CGFloat = 100
    private let axisLockBias: CGFloat = 1.15

    private var triggerDistance: CGFloat {
        actionWidth + 18
    }

    private var maxDragDistance: CGFloat {
        max(actionWidth, triggerDistance)
    }

    private var revealProgress: Double {
        min(Double(abs(horizontalOffset) / triggerDistance), 1)
    }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        if usesNativeSwipeActionsOnIOS {
            nativeSwipeContent
        } else {
            swipeContent
                .background {
                    EmailQuickActionPanInstaller(
                        isEnabled: isEnabled,
                        axisLockBias: axisLockBias,
                        triggerDistance: triggerDistance,
                        maxDragDistance: maxDragDistance,
                        horizontalOffset: $horizontalOffset,
                        onPerform: { onPerform(action) }
                    )
                }
        }
        #else
        swipeContent
            .simultaneousGesture(dragGesture)
        #endif
    }

    private var swipeContent: some View {
        ZStack {
            swipeBackground
            content()
                .offset(x: isEnabled ? horizontalOffset : 0)
        }
        .clipShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: horizontalOffset)
    }

    #if os(iOS)
    @ViewBuilder
    private var nativeSwipeContent: some View {
        if isEnabled {
            content()
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: action.role) {
                        onPerform(action)
                    } label: {
                        Label(action.displayName, systemImage: action.swipeSystemImage)
                    }
                    .tint(action.swipeColor)
                }
        } else {
            content()
        }
    }
    #endif

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isEnabled else { return }

                if dragAxis == nil {
                    let horizontalMovement = abs(value.translation.width)
                    let verticalMovement = abs(value.translation.height)
                    if horizontalMovement > verticalMovement * axisLockBias {
                        dragAxis = .horizontal
                    } else if verticalMovement > horizontalMovement * axisLockBias {
                        dragAxis = .vertical
                    } else {
                        horizontalOffset = 0
                        return
                    }
                }

                guard dragAxis == .horizontal else {
                    horizontalOffset = 0
                    return
                }

                horizontalOffset = max(-maxDragDistance, min(0, value.translation.width))
            }
            .onEnded { value in
                guard isEnabled else {
                    dragAxis = nil
                    horizontalOffset = 0
                    return
                }
                let shouldPerform = dragAxis == .horizontal
                    && value.translation.width <= -triggerDistance
                horizontalOffset = 0
                dragAxis = nil
                guard shouldPerform else { return }
                onPerform(action)
            }
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
}

#if os(iOS)
private struct EmailQuickActionPanInstaller: UIViewRepresentable {
    let isEnabled: Bool
    let axisLockBias: CGFloat
    let triggerDistance: CGFloat
    let maxDragDistance: CGFloat
    @Binding var horizontalOffset: CGFloat
    let onPerform: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: view)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: EmailQuickActionPanInstaller
        private weak var installedView: UIView?
        private var recognizer: UIPanGestureRecognizer?

        init(parent: EmailQuickActionPanInstaller) {
            self.parent = parent
        }

        func installIfNeeded(from markerView: UIView) {
            guard let targetView = markerView.superview else { return }
            guard installedView !== targetView else { return }

            uninstall()

            let recognizer = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePan(_:))
            )
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            targetView.addGestureRecognizer(recognizer)

            self.installedView = targetView
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer, let installedView {
                installedView.removeGestureRecognizer(recognizer)
            }
            installedView = nil
            recognizer = nil
        }

        @objc
        func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.isEnabled else {
                parent.horizontalOffset = 0
                return
            }

            switch recognizer.state {
            case .began, .changed:
                let translation = recognizer.translation(in: recognizer.view)
                parent.horizontalOffset = max(-parent.maxDragDistance, min(0, translation.x))
            case .ended:
                let translation = recognizer.translation(in: recognizer.view)
                let shouldPerform = translation.x <= -parent.triggerDistance
                parent.horizontalOffset = 0
                if shouldPerform {
                    parent.onPerform()
                }
            case .cancelled, .failed:
                parent.horizontalOffset = 0
            default:
                break
            }
        }

        nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard parent.isEnabled,
                    let pan = gestureRecognizer as? UIPanGestureRecognizer
                else {
                    return false
                }

                let velocity = pan.velocity(in: gestureRecognizer.view)
                let horizontalMovement = abs(velocity.x)
                let verticalMovement = abs(velocity.y)
                return velocity.x < 0
                    && horizontalMovement > verticalMovement * parent.axisLockBias
            }
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

private enum DragAxis {
    case horizontal
    case vertical
}

extension ReviewActionToken {
    /// `.approve`/`.reject` never reach this swipe control (email review
    /// cards use `.review`/`.flag`/`.reply`/`.delete`/`.archive` only — note
    /// proposal cards render their own Approve/Reject buttons instead of a
    /// swipe action), but the switch must stay exhaustive.
    var swipeSystemImage: String {
        switch self {
        case .review: "envelope.open"
        case .flag: "flag.fill"
        case .reply: "arrowshape.turn.up.left.fill"
        case .delete: "trash.fill"
        case .archive: "archivebox.fill"
        case .approve: "checkmark.circle.fill"
        case .reject: "xmark.circle.fill"
        case .edit: "pencil.circle.fill"
        case .undo: "arrow.uturn.backward.circle.fill"
        }
    }

    var swipeColor: Color {
        switch self {
        case .review: .blue
        case .flag: .orange
        case .reply: .green
        case .delete: .red
        case .archive: .gray
        case .approve: .green
        case .reject: .red
        case .edit: .blue
        case .undo: .gray
        }
    }
}
