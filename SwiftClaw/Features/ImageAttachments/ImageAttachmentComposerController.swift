#if os(macOS)
import AppKit
import Observation

@MainActor
@Observable
final class ImageAttachmentComposerController {
    var attachments: [ImageAttachmentRecord] = []
    var errorMessage: String?
    var isDropTargeted = false
    var previewSelection: ImageAttachmentPreviewSelection?

    @ObservationIgnored private let store: ImageAttachmentStore
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importGeneration = 0

    init(store: ImageAttachmentStore? = nil) {
        self.store = store ?? .shared
    }

    func selectPreview(at index: Int) {
        previewSelection = ImageAttachmentPreviewSelection(
            attachments: attachments,
            initialIndex: index
        )
    }

    func setDropTargeted(_ isTargeted: Bool, isEnabled: Bool) {
        isDropTargeted = isTargeted && isEnabled
    }

    @discardableResult
    func importDroppedItems(_ items: [ImageImportTransfer], isEnabled: Bool) -> Bool {
        let sources = items.map(\.source)

        guard isEnabled else {
            Self.removeTemporaryFiles(from: sources)
            isDropTargeted = false
            return false
        }

        isDropTargeted = false
        guard !sources.isEmpty else {
            errorMessage = ImageAttachmentError.noReadableImage.localizedDescription
            return false
        }

        startImport(.sources(sources))
        return true
    }

    @discardableResult
    func pasteImagesFromClipboard(isEnabled: Bool) -> Bool {
        guard isEnabled else {
            return false
        }

        let sources = ImageImportPipeline.pasteboardSources()
        guard !sources.isEmpty else {
            return false
        }

        startImport(.sources(sources))
        return true
    }

    func chooseImageAttachments(isEnabled: Bool) {
        guard isEnabled else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageImportPipeline.openPanelContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else {
            return
        }

        startImport(.fileURLs(panel.urls))
    }

    func removeAttachment(_ attachment: ImageAttachmentRecord) {
        attachments.removeAll { $0.id == attachment.id }
        store.deleteDraftAttachments([attachment])

        if previewSelection?.attachments.contains(where: { $0.id == attachment.id }) == true {
            previewSelection = nil
        }
    }

    func clearDraftAttachments() {
        cancelImport()
        store.deleteDraftAttachments(attachments)
        attachments = []
        errorMessage = nil
        previewSelection = nil
        isDropTargeted = false
    }

    func releaseSubmittedAttachments() {
        cancelImport()
        attachments = []
        errorMessage = nil
        previewSelection = nil
        isDropTargeted = false
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importGeneration += 1
    }

    private func startImport(_ request: ImageAttachmentImportRequest) {
        cancelImport()
        errorMessage = nil

        importGeneration += 1
        let generation = importGeneration

        importTask = Task { @MainActor [weak self, request] in
            defer {
                request.removeTemporaryFiles()
            }

            guard let self else {
                return
            }

            defer {
                if self.importGeneration == generation {
                    self.importTask = nil
                }
            }

            do {
                let images = try await self.images(for: request)
                try Task.checkCancellation()

                guard self.importGeneration == generation else {
                    return
                }

                let newAttachments = try self.store.importImages(
                    images,
                    existingAttachments: self.attachments
                )
                self.attachments.append(contentsOf: newAttachments)
                self.errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.importGeneration == generation else {
                    return
                }

                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func images(for request: ImageAttachmentImportRequest) async throws -> [NSImage] {
        switch request {
        case .sources(let sources):
            try await ImageImportPipeline.images(fromSources: sources)
        case .fileURLs(let urls):
            try await ImageImportPipeline.images(fromFileURLs: urls)
        }
    }

    private static func removeTemporaryFiles(from sources: [ImageImportSource]) {
        for source in sources {
            source.removeTemporaryFiles()
        }
    }
}

private enum ImageAttachmentImportRequest: Sendable {
    case sources([ImageImportSource])
    case fileURLs([URL])

    func removeTemporaryFiles() {
        guard case .sources(let sources) = self else {
            return
        }

        for source in sources {
            source.removeTemporaryFiles()
        }
    }
}
#endif
