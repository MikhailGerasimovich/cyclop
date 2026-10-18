import SwiftUI

/// Documents and links in, Markdown out.
///
/// A link goes into the field at the top; a document is dropped onto the
/// panel while this tab is on screen. Each result is a card that drags out as
/// the `.md` file itself, with a button that copies the text.
struct MarkdownPane: View {
    @ObservedObject var markdown: MarkdownStore
    var isTargeted: Bool
    /// Whether the panel holds the keyboard, so the link field can follow it.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if markdown.setup == .ready {
                linkField
                status
                results
            } else {
                setupCard
            }
        }
        .padding(.top, 2)
        .animation(Theme.contentAnimation, value: markdown.current)
        .animation(Theme.contentAnimation, value: markdown.failure)
        .animation(Theme.contentAnimation, value: markdown.setup)
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    // MARK: - Link

    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField(localized("Paste a link: a page, a YouTube video…"), text: $markdown.link)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($focused)
                .onSubmit { markdown.convertLink() }
                .onKeyPress(.escape) {
                    markdown.link = ""
                    return .handled
                }
            Button { markdown.convertLink() } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(markdown.link.isEmpty ? Theme.tertiary : .white)
            }
            .buttonStyle(.plain)
            .disabled(markdown.link.isEmpty)
            .help(localized("Convert to Markdown"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        if let current = markdown.current {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(localized("Converting %@…", current.displayName))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.secondary)
                if !markdown.queue.isEmpty {
                    Text("+\(markdown.queue.count)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 4)
                dismissButton(help: localized("Cancel")) { markdown.cancel() }
            }
            .font(.system(size: 10))
            .padding(.horizontal, 4)
            .transition(.opacity)
        } else if let failure = markdown.failure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange.opacity(0.85))
                Text(failure)
                    .lineLimit(2)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                dismissButton(help: localized("Hide")) { markdown.dismissFailure() }
            }
            .font(.system(size: 10))
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }

    private func dismissButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if markdown.documents.isEmpty {
            dropHint
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(markdown.documents) { document in
                        MarkdownRow(document: document, markdown: markdown)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The list stays where it is under a drag; the outline says the
            // whole of it is a place to let go.
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isTargeted ? 0.6 : 0),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .allowsHitTesting(false)
            )
            .animation(Theme.contentAnimation, value: isTargeted)
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.white.opacity(0.6) : Theme.hairline,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isTargeted ? Theme.surface : .clear)
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(isTargeted ? .white : Theme.tertiary)
                    Text(localized("Drop a document here"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isTargeted ? .white : Theme.secondary)
                    Text(localized("PDF, Word, Excel, PowerPoint, EPUB, HTML, CSV, JSON, ZIP,\nimages with text, audio with speech"))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Theme.contentAnimation, value: isTargeted)
    }

    // MARK: - Setup

    private var setupCard: some View {
        VStack(spacing: 7) {
            switch markdown.setup {
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text(localized("Installing markitdown…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(localized("A minute or two: a few hundred megabytes of Python packages"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text(localized("Installation failed"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                installButton(localized("Retry"))
            case .missing, .ready:
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white)
                Text(localized("Install the Markdown converter"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(markdown.canInstall
                     ? localized("markitdown runs on this Mac, in its own Python environment\nin Application Support. Needs uv or Python 3.10 or newer")
                     : localized("Run Tools/markitdown/install.sh from the repository"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                if markdown.canInstall { installButton(localized("Install")) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func installButton(_ title: String) -> some View {
        Button(title) { markdown.install() }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(Capsule().fill(Theme.surfaceHover))
            .padding(.top, 2)
    }
}

/// One converted file. The whole row is a drag handle for the file; the
/// buttons sit above that handle, otherwise it would swallow their clicks.
private struct MarkdownRow: View {
    let document: MarkdownDocument
    @ObservedObject var markdown: MarkdownStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(document.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 56)
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            ShelfDragSource(
                urls: { [document.url] },
                onClick: { _ in },
                onDoubleClick: { markdown.open(document) }
            )
        )
        .overlay(alignment: .trailing) {
            HStack(spacing: 12) {
                CopyButton { markdown.copy(document) }
                Button { markdown.remove(document) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help(localized("Delete"))
            }
            .padding(.trailing, 11)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Copy") { markdown.copy(document) }
            Button("Open") { markdown.open(document) }
            Button("Show in Finder") { markdown.reveal(document) }
            Divider()
            Button("Delete") { markdown.remove(document) }
        }
    }

    private var meta: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file)
        let style = Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: appLanguage))
        return "\(size) · \(document.date.formatted(style))"
    }
}
