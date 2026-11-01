import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]
    private var keepAwakeItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
        observeKeepAwake()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
    }

    /// Reopen is the one gesture left once the icon is hidden: launching
    /// Cyclop.app again from Finder or Spotlight while it is already running.
    /// `LSUIElement` gives it no Dock icon and no window to raise, but this
    /// delegate method still fires — it is how the icon comes back (#5).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        return true
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eye.fill",
            accessibilityDescription: "Cyclop"
        )
        item.button?.image?.isTemplate = true
        // Lets the icon be ⌘-dragged off the bar, the way any status item can
        // be; `autosaveName` is what makes AppKit remember that across
        // relaunches on its own, the same mechanism the explicit switch in
        // Settings uses through `AppDelegate.isMenuBarIconVisible` below (#5).
        item.behavior = .removalAllowed
        item.autosaveName = "CyclopMenuBarIcon"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Cyclop \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // Sits next to the panel switch rather than in the Settings tab: it
        // changes what the panel shows, and it is the one people look for in a
        // hurry, with the camera already running.
        //
        // A submenu rather than a plain switch, because the tabs hold different
        // things and not everyone wants all of them covered. "All" comes first
        // and is what most people will ever touch; the sections below it are
        // for the case where that is too much.
        let privacy = NSMenuItem(title: localized("Hide Contents"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let all = NSMenuItem(title: localized("All"), action: #selector(togglePrivacyAll), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        privacyAllItem = all
        submenu.addItem(.separator())

        for section in PrivacyMode.Section.allCases {
            let item = NSMenuItem(
                title: section.title,
                action: #selector(togglePrivacySection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = section.rawValue
            submenu.addItem(item)
            privacySectionItems[section] = item
        }

        privacy.submenu = submenu
        menu.addItem(privacy)
        privacyItem = privacy

        // The other switch people want without opening anything: it is
        // usually flipped on the way out to a call or a coffee, with the
        // pointer already up in the menu bar.
        let awake = NSMenuItem(
            title: localized("Keep Mac Awake"),
            action: #selector(toggleKeepAwake),
            keyEquivalent: ""
        )
        awake.target = self
        menu.addItem(awake)
        keepAwakeItem = awake

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        controller?.toggle()
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPrivacyItems()
        refreshKeepAwakeItem()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePrivacyAll(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy else { return }
        // Anything short of everything means "turn the rest on too"; only a
        // full house turns them all off. One press, and no state where the
        // item says All while half the sections are open.
        privacy.setCoveringAll(!privacy.coversAll)
        refreshPrivacyItems()
    }

    @objc private func togglePrivacySection(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy,
              let raw = sender.representedObject as? String,
              let section = PrivacyMode.Section(rawValue: raw) else { return }
        privacy.setCovering(section, !privacy.covers(section))
        refreshPrivacyItems()
    }

    @objc private func toggleKeepAwake() {
        controller?.keepAwake?.toggle()
    }

    /// A tick while on, and how long is left under the title — the same two
    /// facts the card in Utilities shows.
    private func refreshKeepAwakeItem() {
        guard let item = keepAwakeItem else { return }
        let available = controller?.isKeepAwakeAvailable ?? false
        item.isHidden = !available
        guard available, let awake = controller?.keepAwake else { return }
        item.state = awake.isActive ? .on : .off
        if !awake.isActive {
            item.subtitle = nil
        } else if let left = awake.remaining() {
            item.subtitle = localized("Ends in %@", KeepAwake.format(left))
        } else {
            item.subtitle = localized("On until you turn it off")
        }
    }

    /// The icon changes to a cup while the Mac is held awake. A mode that
    /// overrides the energy settings should not be running unnoticed — the
    /// panel is folded most of the time, and the menu bar is always there.
    private func observeKeepAwake() {
        guard let awake = controller?.keepAwake else { return }
        awake.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.updateStatusIcon(keepingAwake: active) }
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(keepingAwake: Bool) {
        let image = NSImage(
            systemSymbolName: keepingAwake ? "cup.and.saucer.fill" : "eye.fill",
            accessibilityDescription: keepingAwake ? localized("Cyclop — Keep Mac Awake is on") : "Cyclop"
        )
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// The parent item carries the summary: a tick when every section is
    /// covered, a dash when some are. Without it the state is a submenu away,
    /// and this is the one switch worth reading at a glance.
    private func refreshPrivacyItems() {
        guard let privacy = controller?.privacy else { return }
        privacyItem?.state = privacy.coversAll ? .on : (privacy.coversAny ? .mixed : .off)
        privacyAllItem?.state = privacy.coversAll ? .on : .off
        for (section, item) in privacySectionItems {
            item.state = privacy.covers(section) ? .on : .off
        }
    }
}

extension AppDelegate {
    /// Whether the status item shows at all. Reachable from the Settings tab
    /// (#5) the same way `NotchGeometry.showsOnAllDisplays` reaches its own
    /// piece of state — through the one `AppDelegate` the app has, rather than
    /// threading a reference through the view hierarchy for a single switch.
    ///
    /// Nothing to migrate to `config.json` (#67): AppKit already persists this
    /// through `autosaveName`, which is also what a ⌘-drag off the bar updates
    /// — the two paths to the same off state agree because they are the same
    /// state.
    @MainActor
    static var isMenuBarIconVisible: Bool {
        get { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible ?? true }
        set { (NSApp.delegate as? AppDelegate)?.statusItem?.isVisible = newValue }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

