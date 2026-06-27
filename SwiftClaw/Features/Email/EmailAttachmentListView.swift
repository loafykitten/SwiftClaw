import SwiftUI
import QuickLook

/// Attachment list with QuickLook preview. Extracted from `EmailView.swift`
/// along the attachments concern boundary.
struct EmailAttachmentList: View {
    let attachments: [EmailAttachment]
    let emailID: UUID

    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Attachments")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(attachments) { attachment in
                Button {
                    previewURL = resolveURL(for: attachment)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: AttachmentIconSystemName.value(for: attachment.mimeType))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.filename)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(AttachmentFormatter.sizeString(attachment.sizeBytes))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if attachment.filePath.isEmpty {
                            Text("unavailable")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(attachment.filePath.isEmpty)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func resolveURL(for attachment: EmailAttachment) -> URL? {
        guard !attachment.filePath.isEmpty else { return nil }
        return EmailAttachmentStore.shared.absoluteURL(
            forEmailID: emailID,
            filename: attachment.filename
        )
    }
}

private enum AttachmentIconSystemName {
    /// Picks a SF Symbol for an attachment based on its declared MIME type.
    /// Anything unrecognised falls back to the generic paperclip.
    static func value(for mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return "photo" }
        if lower.hasPrefix("video/") { return "film" }
        if lower.hasPrefix("audio/") { return "music.note" }
        if lower.contains("pdf") { return "doc.text.fill" }
        if lower.contains("zip") || lower.contains("compressed") { return "archivebox" }
        if lower.contains("spreadsheet") || lower.contains("excel") { return "tablecells" }
        if lower.contains("presentation") || lower.contains("powerpoint") { return "rectangle.on.rectangle" }
        if lower.contains("word") || lower.contains("document") { return "doc.text" }
        if lower.contains("json") || lower.contains("xml") || lower.contains("text") { return "doc.plaintext" }
        return "paperclip"
    }
}

private enum AttachmentFormatter {
    static func sizeString(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
