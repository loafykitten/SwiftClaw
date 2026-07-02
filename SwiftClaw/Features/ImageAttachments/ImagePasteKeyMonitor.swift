#if os(macOS)
import AppKit
import SwiftUI

struct ImagePasteKeyMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var onPasteImage: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onPasteImage: onPasteImage)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPasteImage = onPasteImage
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onPasteImage: () -> Bool

        private var monitor: Any?

        init(isEnabled: Bool, onPasteImage: @escaping () -> Bool) {
            self.isEnabled = isEnabled
            self.onPasteImage = onPasteImage
        }

        func install() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                      event.charactersIgnoringModifiers?.lowercased() == "v" else {
                    return event
                }

                return self.onPasteImage() ? nil : event
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
#endif
