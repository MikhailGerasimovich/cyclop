import AppKit
import UniformTypeIdentifiers

/// A document converted to Markdown: a `.md` file in the app's own folder.
struct MarkdownDocument: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Turns files and links into Markdown with Microsoft's markitdown.
///
/// markitdown is Python, and with every format switched on it is a few hundred
/// megabytes of it — pandas, onnxruntime, pdfminer, the speech recogniser. None
/// of that goes into a 3.7 MB bundle. It lives in an environment of its own in
/// the support folder, installed once by `install.sh` — from the terminal or
/// by the button in the pane, which runs the copy that ships in the bundle.
///
/// Each conversion is one run of `bridge.py` in that environment, and nothing
/// stays running between them: a converter that is not converting costs
/// nothing, which is the rule every other tab lives by too.
///
/// Results are plain files, newest first. The folder is the list — there is no
/// index beside it to drift out of step — and a card dragged out of the pane is
/// the file itself.
@MainActor
final class MarkdownStore: ObservableObject {
    enum Setup: Equatable {
        case missing
        case installing
        case ready
        case failed(String)
    }

    /// What was handed in: a file from a drop, or a link typed into the field.
    enum Source: Equatable {
        case file(URL)
        case link(String)

        var displayName: String {
            switch self {
            case .file(let url): return url.lastPathComponent
            case .link(let link): return link
            }
        }
    }

    @Published private(set) var setup: Setup = .missing
    @Published private(set) var documents: [MarkdownDocument] = []
    /// The source being converted right now, and the ones waiting behind it.
    /// One at a time: every run is a Python process a few hundred megabytes
    /// large, and ten dropped files are ten of them side by side otherwise.
    @Published private(set) var current: Source?
    @Published private(set) var queue: [Source] = []
    /// Why the last conversion did not produce a file. Cleared by the next one.
    @Published private(set) var failure: String?
    @Published var link = ""

    private var worker: Task<Void, Never>?
    private var installer: Task<Void, Never>?

    static let folder = Support.directory("Markdown")
    private static let environment = Support.folder.appendingPathComponent("MarkItDown", isDirectory: true)
    private static let python = environment.appendingPathComponent("venv/bin/python")
    /// Written by `install.sh` as its very last step, so an install that died
    /// halfway does not pass for a working one.
    private static let marker = environment.appendingPathComponent("venv/.cyclop-installed")
    private static let scripts = Bundle.main.resourceURL?.appendingPathComponent("markitdown", isDirectory: true)

    init() {
        refreshSetup()
    }

    // MARK: - Setup

    func refreshSetup() {
        guard setup != .installing else { return }
        setup = FileManager.default.fileExists(atPath: Self.marker.path) ? .ready : .missing
    }

    var canInstall: Bool { Self.script("install.sh") != nil }

    func install() {
        guard setup != .installing, let script = Self.script("install.sh") else { return }
        setup = .installing
        installer = Task {
            let result = await ChildProcess.run(
                URL(fileURLWithPath: "/bin/bash"),
                [script.path],
                environment: Self.childEnvironment
            )
            installer = nil
            if result.status == 0, FileManager.default.fileExists(atPath: Self.marker.path) {
                setup = .ready
            } else if !result.cancelled {
                setup = .failed(Self.lastLines(of: result.errors) ?? localized("Installation failed"))
            } else {
                setup = .missing
            }
        }
    }

    // MARK: - Documents

    /// Re-read on the way into the tab: the folder is the user's to tidy in
    /// Finder, and a card for a file that is gone would drag out nothing.
    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        documents = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return MarkdownDocument(
                    url: url,
                    date: values?.contentModificationDate ?? .distantPast,
                    size: values?.fileSize ?? 0
                )
            }
            .sorted { $0.date > $1.date }
        refreshSetup()
    }

    /// The text itself rather than the file: what gets pasted next is almost
    /// always a chat or an editor, and both want the Markdown, not a path.
    func copy(_ document: MarkdownDocument) {
        guard let text = try? String(contentsOf: document.url, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func open(_ document: MarkdownDocument) {
        NSWorkspace.shared.open(document.url)
    }

    func reveal(_ document: MarkdownDocument) {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    /// To the Trash, like the screenshots: the user's own hand, kept reversible.
    func remove(_ document: MarkdownDocument) {
        try? FileManager.default.trashItem(at: document.url, resultingItemURL: nil)
        documents.removeAll { $0.id == document.id }
    }

    // MARK: - Converting

    /// The field's contents. Anything without a scheme is taken for a web
    /// address typed the short way — "youtu.be/…" is how people paste them.
    func convertLink() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let address = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            failure = localized("This is not a link")
            return
        }
        link = ""
        enqueue([.link(address)])
    }

    /// Whether the files were taken. Refused before the converter is
    /// installed: the pane shows the install card then, with nowhere to say
    /// what happened to a drop, so the file bounces back instead.
    @discardableResult
    func convert(files: [URL]) -> Bool {
        // A dropped folder has nothing for markitdown to read; zip archives
        // are files and are welcome.
        let files = files.filter { !$0.hasDirectoryPath }
        guard setup == .ready, !files.isEmpty else { return false }
        enqueue(files.map(Source.file))
        return true
    }

    /// Stops the run in progress and forgets what was waiting.
    func cancel() {
        queue.removeAll()
        worker?.cancel()
    }

    func dismissFailure() { failure = nil }

    /// Everything that runs, stopped: the tab leaving the rail, or the app
    /// quitting. A Python process left behind would outlive both.
    func stop() {
        cancel()
        installer?.cancel()
    }

    private func enqueue(_ sources: [Source]) {
        guard !sources.isEmpty else { return }
        failure = nil
        queue.append(contentsOf: sources)
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let source = queue.removeFirst()
            current = source
            do {
                let document = try await run(source)
                documents.insert(document, at: 0)
            } catch is CancellationError {
                break
            } catch {
                failure = "\(source.displayName): \(error.localizedDescription)"
            }
        }
        current = nil
        worker = nil
        // A cancel can land between two files, after the loop has already
        // decided to take the next one; whatever is left is not wanted.
        queue.removeAll()
    }

    private func run(_ source: Source) async throws -> MarkdownDocument {
        guard setup == .ready, let bridge = Self.script("bridge.py") else {
            throw Failure(localized("The converter is not installed"))
        }

        let argument: String
        switch source {
        case .file(let url): argument = url.path
        case .link(let link): argument = link
        }

        let result = await ChildProcess.run(
            Self.python,
            ["-I", bridge.path, "--language", Self.speechLanguage, argument],
            environment: Self.childEnvironment
        )
        if result.cancelled { throw CancellationError() }

        let reply = try? JSONDecoder().decode(Reply.self, from: result.output)
        if let error = reply?.error { throw Failure(error) }
        guard result.status == 0, var markdown = reply?.markdown else {
            throw Failure(Self.lastLines(of: result.errors) ?? localized("The converter stopped unexpectedly"))
        }

        // markitdown reads the text inside a document, not the text in a
        // picture of one: without a model to ask it gives a photo's metadata
        // and a scanned PDF's nothing. Vision reads both, offline.
        if case .file(let url) = source {
            markdown = await TextRecognizer.supplement(markdown, for: url)
        }
        try Task.checkCancellation()

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(localized("No text found")) }

        let url = Self.destination(for: Self.baseName(title: reply?.title, source: source))
        do {
            try (trimmed + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Failure(error.localizedDescription)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return MarkdownDocument(url: url, date: Date(), size: size)
    }

    // MARK: - Helpers

    private struct Reply: Decodable {
        let title: String?
        let markdown: String?
        let error: String?
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func script(_ name: String) -> URL? {
        guard let url = scripts?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// An app started from the Finder gets `/usr/bin:/bin:/usr/sbin:/sbin`,
    /// and markitdown looks for exiftool and ffmpeg along PATH — both usually
    /// installed by Homebrew, neither on that list.
    private static var childEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extra + [path]).joined(separator: ":")
        return environment
    }

    /// For audio transcription: the language of the person who dropped the
    /// recording is the best guess there is at the language spoken in it.
    private static var speechLanguage: String {
        Locale.preferredLanguages.first ?? "en-US"
    }

    /// The document's own title when it has one — a web page and a video always
    /// do — otherwise the file's name, otherwise the address.
    private static func baseName(title: String?, source: Source) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sanitized(title)
        }
        switch source {
        case .file(let url):
            return sanitized(url.deletingPathExtension().lastPathComponent)
        case .link(let link):
            let url = URL(string: link)
            let host = url?.host ?? link
            let path = url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            return sanitized(path.isEmpty ? host : "\(host) \(path)")
        }
    }

    private static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\n\r\t")
        let cleaned = name.components(separatedBy: forbidden)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let short = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? localized("Document") : short
    }

    private static func destination(for base: String) -> URL {
        var url = folder.appendingPathComponent("\(base).md")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).md")
            attempt += 1
        }
        return url
    }

    /// The tail of a script's stderr, which is where its reason for stopping is.
    private static func lastLines(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(2).joined(separator: "\n")
    }
}

/// One run of a child process, awaited without holding a thread hostage on
/// the main actor.
///
/// Both pipes are drained while the process runs, not after: a pipe holds
/// 64 KB, a converted book is megabytes, and a child that fills its pipe
/// waits for a reader that is itself waiting for the child to exit.
enum ChildProcess {
    struct Result: Sendable {
        let status: Int32
        let output: Data
        let errors: Data
        let cancelled: Bool
    }

    /// `Process` is not Sendable, and the cancellation handler runs on
    /// whatever thread cancelled the task. `terminate` is safe from any of
    /// them; nothing else is touched from outside.
    private final class Handle: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var _cancelled = false

        var cancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelled
        }

        func cancel() {
            lock.lock()
            _cancelled = true
            lock.unlock()
            if process.isRunning { process.terminate() }
        }
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async -> Result {
        let handle = Handle()
        let process = handle.process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(
                        status: -1,
                        output: Data(),
                        errors: Data(error.localizedDescription.utf8),
                        cancelled: false
                    ))
                    return
                }
                // Cancelled before the process existed: the handler found
                // nothing to terminate, so it is done here instead.
                if handle.cancelled { process.terminate() }
                // Each pipe read on its own queue until end of file, which
                // comes when the child exits and the write ends close.
                DispatchQueue.global(qos: .userInitiated).async {
                    let group = DispatchGroup()
                    nonisolated(unsafe) var errorData = Data()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errorData = errors.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outputData = output.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    continuation.resume(returning: Result(
                        status: process.terminationStatus,
                        output: outputData,
                        errors: errorData,
                        cancelled: handle.cancelled
                    ))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}
