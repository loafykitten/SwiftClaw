import AppKit
import SwiftUI

struct ImagePreviewKeyMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onPrevious: onPrevious,
            onNext: onNext,
            onClose: onClose
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.onClose = onClose
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onPrevious: () -> Void
        var onNext: () -> Void
        var onClose: () -> Void

        private var monitor: Any?

        init(
            isEnabled: Bool,
            onPrevious: @escaping () -> Void,
            onNext: @escaping () -> Void,
            onClose: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onPrevious = onPrevious
            self.onNext = onNext
            self.onClose = onClose
        }

        func install() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled, !event.hasCommandControlOrOptionModifier else {
                    return event
                }

                switch event.keyCode {
                case 123:
                    self.onPrevious()
                    return nil
                case 124:
                    self.onNext()
                    return nil
                case 53:
                    self.onClose()
                    return nil
                default:
                    return event
                }
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }

            monitor = nil
        }

        deinit {
            remove()
        }
    }
}

private extension NSEvent {
    var hasCommandControlOrOptionModifier: Bool {
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.option)
    }
}
