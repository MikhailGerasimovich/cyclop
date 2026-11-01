import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac from going idle: the display does not dim, sleep or lock, and
/// the system does not sleep on its own — for a set time or until switched off.
///
/// Built on IOKit power assertions, the same mechanism a video player or
/// `caffeinate -d` uses. They are honoured by the system as long as this
/// process holds them and are dropped by the kernel the moment it dies, so a
/// crash cannot leave the Mac stuck awake. What they do not cover is closing
/// the lid: that sleeps the Mac no matter who asks otherwise, and overriding it
/// takes `pmset` and an administrator password, which is not worth asking for.
///
/// The screen lock this is about is the one that follows the screen saver or
/// the display going off, when "Require password" is set. Holding the display
/// up keeps both from starting, so the lock never gets its cue. Locking by hand
/// — ⌃⌘Q, the lid, the menu — still works, as it should.
@MainActor
final class KeepAwake: ObservableObject {
    /// The presets on offer. Few on purpose: this is reached for in the middle
    /// of something, and a slider would be a decision where a tap should do.
    enum Duration: Int, CaseIterable, Identifiable, Sendable {
        case quarterHour = 15
        case hour = 60
        case threeHours = 180
        /// Until switched off.
        case indefinite = 0

        var id: Int { rawValue }

        var interval: TimeInterval? {
            rawValue > 0 ? TimeInterval(rawValue) * 60 : nil
        }

        static let fallback: Duration = .hour
    }

    @Published private(set) var isActive = false
    /// When the session ends by itself; nil while active means "until switched
    /// off", and nil while inactive means nothing.
    @Published private(set) var endsAt: Date?
    /// The last preset picked — what the plain switch starts next time.
    @Published private(set) var duration: Duration
    /// The system refused the assertion on the last attempt. Rare enough that
    /// it is reported rather than retried: retrying would just fail again.
    @Published private(set) var failed = false

    private let power: any PowerAssertions
    private let remember: (Duration) -> Void
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(
        power: any PowerAssertions = IOKitPowerAssertions(),
        duration: Duration = .fallback,
        remember: @escaping (Duration) -> Void = { _ in }
    ) {
        self.power = power
        self.duration = duration
        self.remember = remember

        // A `Timer` counts in machine time, which stands still while the Mac
        // sleeps — and it still can, by lid or by hand. Without this, an hour
        // that began before a night with the lid closed would run on for most
        // of the next morning.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfDue() }
        }
    }

    // MARK: - Switching

    /// The main switch: off if on, otherwise the last preset again.
    func toggle() {
        if isActive { stop() } else { start(duration) }
    }

    /// Starts, or restarts from now, with the given preset. Picking one while a
    /// session runs is how it is extended or shortened — no separate control.
    func start(_ pick: Duration, now: Date = Date()) {
        duration = pick
        remember(pick)

        guard power.hold(reason: "Cyclop: Keep Mac Awake") else {
            stop()
            failed = true
            return
        }
        failed = false
        isActive = true
        endsAt = pick.interval.map { now.addingTimeInterval($0) }
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        power.release()
        isActive = false
        endsAt = nil
    }

    /// Ends the session if its time has come. Called by the timer and on wake;
    /// public so the check can be driven with a chosen clock.
    func expireIfDue(now: Date = Date()) {
        guard isActive, let endsAt, endsAt <= now else { return }
        stop()
    }

    /// Time left, never negative; nil for a session without an end.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard isActive, let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(now))
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let endsAt else { return }
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfDue() }
        }
        // A minute's precision is what the pane shows; a few seconds of slack
        // lets the system fold this wake-up into one it was doing anyway.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Formatting

    /// "42 min", "1 hr 5 min", "30 sec" — in the app's language, not the
    /// system's, like every other formatted value in the panel. Rounded up, so
    /// the last minute reads "1 min" rather than "0 min".
    static func format(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: appLanguage)
        formatter.calendar = calendar
        if interval < 60 {
            formatter.allowedUnits = [.second]
            return formatter.string(from: max(1, interval.rounded(.up))) ?? ""
        }
        formatter.allowedUnits = [.hour, .minute]
        return formatter.string(from: (interval / 60).rounded(.up) * 60) ?? ""
    }

    /// The label on a preset chip.
    static func label(_ duration: Duration) -> String {
        guard let interval = duration.interval else { return "∞" }
        return format(interval)
    }
}

// MARK: - Power assertions

/// What actually holds the Mac up. A protocol only so the session logic can be
/// tested without touching the real power state.
protocol PowerAssertions: AnyObject {
    /// Takes the hold if it is not already held. False when the system refused;
    /// nothing is held then.
    func hold(reason: String) -> Bool
    /// Lets go. Safe to call when nothing is held.
    func release()
}

/// Two assertions rather than one. The display one is what keeps the screen
/// from dimming and locking; the system one keeps the Mac running underneath,
/// which matters on its own for a download or a build left to finish.
final class IOKitPowerAssertions: PowerAssertions {
    /// Spelled out: the `kIOPMAssertionType…` names are `CFSTR` macros, which
    /// do not make it into Swift.
    private static let types = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"]

    private var held: [IOPMAssertionID] = []

    func hold(reason: String) -> Bool {
        guard held.isEmpty else { return true }
        var taken: [IOPMAssertionID] = []
        for type in Self.types {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                // All or nothing: a display kept on over a system allowed to
                // sleep is not the mode the switch promised.
                taken.forEach { IOPMAssertionRelease($0) }
                NSLog("Cyclop: power assertion \(type) refused: \(result)")
                return false
            }
            taken.append(id)
        }
        held = taken
        return true
    }

    func release() {
        held.forEach { IOPMAssertionRelease($0) }
        held = []
    }

    deinit { release() }
}
