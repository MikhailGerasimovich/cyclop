import SwiftUI
import ServiceManagement

/// What used to live in the status bar menu, minus the two items that belong
/// there: opening the panel and hiding its contents are both things people
/// reach for in a hurry, often without wanting to open the panel at all — the
/// rest is configuration, read rarely, and reads better as a tab like any
/// other than as a menu that grows a new row per feature.
struct SettingsPane: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    let screenshots: ScreenshotFolderWatcher
    @ObservedObject var llm: LLMSettings
    @ObservedObject var tokens: TokenLedger
    @ObservedObject private var config = ConfigStore.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var menuBarIconVisible = AppDelegate.isMenuBarIconVisible
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var allDisplays = NotchGeometry.showsOnAllDisplays
    @State private var fullSizeNotch = NotchGeometry.drawsFullSizeNotch
    @State private var watchScreenshotFolder = false
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                    // Off means the same thing a ⌘-drag off the bar does —
                    // both go through `AppDelegate.isMenuBarIconVisible`, so
                    // whichever one somebody used, this switch shows it (#5).
                    toggleRow(
                        symbol: "eye.fill",
                        title: localized("Show Menu Bar Icon"),
                        isOn: menuBarIconVisibleBinding
                    )
                }

                // The rail is for what gets a glance between other things.
                // A tab used once a month is not banned from it, but it lives
                // there only as long as whoever never uses it can take it off —
                // and off means quiet too: its background stops with the icon.
                section(localized("Show in Panel")) {
                    ForEach(NotchViewModel.Tab.leftRail + NotchViewModel.Tab.rightRail) { tab in
                        if tab.canHide {
                            toggleRow(symbol: tab.symbol, title: tab.title, isOn: visibilityBinding(tab))
                        }
                    }
                }

                aiSection

                section(localized("Displays")) {
                    toggleRow(
                        symbol: "display.2",
                        title: localized("Show on All Displays"),
                        isOn: allDisplaysBinding
                    )
                    toggleRow(
                        symbol: "rectangle.topthird.inset.filled",
                        title: localized("Full-Height Notch Without a Cutout"),
                        isOn: fullSizeNotchBinding
                    )
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    toggleRow(
                        symbol: "eye",
                        title: localized("Watch Screenshots Folder"),
                        isOn: watchScreenshotFolderBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        ScreenshotVault.reveal()
                    }
                    actionRow(
                        symbol: "trash",
                        title: clearTitle,
                        disabled: screenshotUsage.files == 0
                    ) {
                        ScreenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
                    }
                }

                section(localized("Snippets")) {
                    actionRow(symbol: "doc.text", title: localized("Show Snippets File")) {
                        vm.snippets.reveal()
                    }
                }

                // What lives in this file is documented in #67: everything
                // above that makes sense on another Mac, in one place instead
                // of five.
                section(localized("Configuration")) {
                    if config.fileBroken { configBrokenNotice }
                    actionRow(symbol: "gearshape", title: localized("Show Config File")) {
                        ConfigStore.reveal()
                    }
                }

                // The one door left once the menu bar icon is gone (#5): a
                // status item is not required to hide it any more, so quitting
                // must not require one either. Last on purpose — leaving is
                // not something to meet on the way to a switch.
                section(localized("Cyclop")) {
                    actionRow(symbol: "power", title: localized("Quit Cyclop")) {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            // Also flipped by a ⌘-drag off the bar, not only by the switch
            // below it — re-read for the same reason as the rest of this block.
            menuBarIconVisible = AppDelegate.isMenuBarIconVisible
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            allDisplays = NotchGeometry.showsOnAllDisplays
            fullSizeNotch = NotchGeometry.drawsFullSizeNotch
            watchScreenshotFolder = screenshots.isEnabled
            refreshUsage()
            // The one place the key is shown, so the one place it is fetched
            // from the Keychain without a conversion asking for it.
            llm.loadKey()
        }
    }

    // MARK: - AI

    /// The Markdown converter's language model. The switch is first and wins
    /// over everything under it: a key that has been typed in turns nothing
    /// on by itself.
    private var aiSection: some View {
        section(localized("AI")) {
            toggleRow(symbol: "sparkles", title: localized("Process with AI"), isOn: $llm.enabled)

            row(symbol: "server.rack", title: localized("Provider")) {
                Menu {
                    ForEach(LLMProvider.allCases) { provider in
                        Button(provider.title) { llm.provider = provider }
                    }
                } label: {
                    Text(llm.provider.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                Spacer(minLength: 0)
            }

            row(symbol: "link", title: localized("API Address")) {
                field(TextField(llm.provider.defaultBaseURL.isEmpty ? "https://…/v1" : llm.provider.defaultBaseURL, text: $llm.baseURL))
            }

            row(symbol: "key.fill", title: localized("API Key")) {
                field(SecureField(llm.provider.needsKey ? localized("Required") : localized("Not needed"), text: $llm.apiKey))
            }

            row(symbol: "cpu", title: localized("Model")) {
                field(TextField(localized("Model name"), text: $llm.model))
                modelPicker
            }

            if let problem = llm.problem {
                noteRow(symbol: "exclamationmark.triangle.fill", tint: Color.yellow.opacity(0.85), text: problem)
            } else if let error = llm.modelsError {
                noteRow(symbol: "exclamationmark.triangle.fill", tint: Color.yellow.opacity(0.85), text: error)
            }

            usageRow

            noteRow(
                symbol: "info.circle",
                tint: Theme.tertiary,
                text: llm.provider.isLocal
                    ? localized("Describes pictures and reads text in images inside PDF, Word, PowerPoint and Excel. The model runs on this Mac: nothing is sent anywhere")
                    : localized("Describes pictures and reads text in images inside PDF, Word, PowerPoint and Excel. Every picture is one paid request; the pictures are sent to the provider")
            )
        }
    }

    /// The provider's own list, fetched on demand: the clouds change their
    /// line-ups faster than a list written here would be kept up to date, and
    /// a local server has whatever was pulled onto it.
    @ViewBuilder
    private var modelPicker: some View {
        if llm.isLoadingModels {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18)
        } else if llm.models.isEmpty {
            Button { llm.loadModels() } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Load the provider's models"))
        } else {
            Menu {
                ForEach(llm.models, id: \.self) { model in
                    Button(model) { llm.model = model }
                }
                Divider()
                Button(localized("Reload List")) { llm.loadModels() }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(localized("Choose a model"))
        }
    }

    private var usageRow: some View {
        let locale = Locale(identifier: appLanguage)
        let total = tokens.total
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(localized("Tokens used: %@", total.total.formatted(.number.locale(locale))))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Text(localized(
                    "Input %@ · output %@ · requests %d · since %@",
                    total.input.formatted(.number.locale(locale)),
                    total.output.formatted(.number.locale(locale)),
                    total.requests,
                    tokens.since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                ))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 8)
            Button(localized("Reset")) { tokens.resetTotal() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .disabled(total.requests == 0)
                .opacity(total.requests == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
    }

    private func row<Content: View>(
        symbol: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 92, alignment: .leading)
            content()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// The same look as the name field in Snippets: a field is told apart
    /// from a label by the surface under it, the caret shows only once in.
    private func field<Field: View>(_ field: Field) -> some View {
        field
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .tint(Theme.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surface)
            )
    }

    private func noteRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var menuBarIconVisibleBinding: Binding<Bool> {
        Binding(
            get: { menuBarIconVisible },
            set: { wants in
                menuBarIconVisible = wants
                AppDelegate.isMenuBarIconVisible = wants
            }
        )
    }

    private func visibilityBinding(_ tab: NotchViewModel.Tab) -> Binding<Bool> {
        Binding(
            get: { vm.isVisible(tab) },
            set: { wants in vm.setVisible(tab, wants) }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                NotchViewModel.saveClipboardImagesEnabled = wants
            }
        )
    }

    /// Turning this off folds the panel back to one screen — the notched one
    /// if this Mac has a notch, the main display otherwise. The panels are
    /// rebuilt on the spot, so the switch is its own confirmation.
    private var allDisplaysBinding: Binding<Bool> {
        Binding(
            get: { allDisplays },
            set: { wants in
                allDisplays = wants
                NotchGeometry.showsOnAllDisplays = wants
            }
        )
    }

    /// Where a display has no cutout, the notch is drawn as a thin strip along
    /// the top edge; this brings back the old one, the height of the menu bar.
    /// Panels rebuild on the spot, so the switch is its own confirmation.
    private var fullSizeNotchBinding: Binding<Bool> {
        Binding(
            get: { fullSizeNotch },
            set: { wants in
                fullSizeNotch = wants
                NotchGeometry.drawsFullSizeNotch = wants
            }
        )
    }

    /// Turning off is instant. Turning on goes through the Open panel first —
    /// `requestAccess` is itself the consent, so the switch only follows what
    /// actually happened once the panel closes, not the click that opened it.
    private var watchScreenshotFolderBinding: Binding<Bool> {
        Binding(
            get: { watchScreenshotFolder },
            set: { wants in
                if wants {
                    screenshots.requestAccess { granted in watchScreenshotFolder = granted }
                } else {
                    screenshots.disable()
                    watchScreenshotFolder = false
                }
            }
        )
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(NotchToggleStyle())
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// The refusal to write over a broken file (#7) is only honest if it is
    /// said out loud — same reasoning as `SnippetsPane.brokenNotice`.
    private var configBrokenNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.85))
            Text(localized("config.json is broken — click to open; nothing is overwritten"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { ConfigStore.reveal() }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func actionRow(
        symbol: String,
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
