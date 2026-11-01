import SwiftUI

/// Two cards side by side. Still not a list: two system-wide modes, each one
/// press away, read better as two big targets than as rows of small ones — and
/// the pane is cheap to redo the day a third arrives.
struct UtilitiesPane: View {
    @ObservedObject var lock: KeyboardLock
    @ObservedObject var awake: KeepAwake

    var body: some View {
        HStack(spacing: 10) {
            KeyboardLockCard(lock: lock)
            KeepAwakeCard(awake: awake)
        }
    }
}

// MARK: - Card chrome

/// The rounded tile both cards stand on. Lit with the accent while its mode is
/// on, so which of the two is running reads from across the room.
private struct UtilityCard<Content: View>: View {
    var isOn = false
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(isOn ? Color.accentColor.opacity(0.16) : Theme.surface))
            .overlay(shape.strokeBorder(isOn ? Color.accentColor.opacity(0.45) : Theme.hairline, lineWidth: 1))
            .animation(Theme.contentAnimation, value: isOn)
    }
}

/// Icon, title, caption — the face of either card.
private struct UtilityFace: View {
    let symbol: String
    var dimmed = false
    let title: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(dimmed ? Color.white.opacity(0.75) : .white)
                .frame(height: 28)
                .contentTransition(.symbolEffect(.replace))

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }
}

// MARK: - Keyboard lock

private struct KeyboardLockCard: View {
    @ObservedObject var lock: KeyboardLock

    /// Read from the lock rather than kept here: one of the reasons — secure
    /// input coming up mid-wipe — is raised by a timer with no press behind it,
    /// and a copy in the view would never hear about it.
    ///
    /// An interruption wins: it describes a lock that was running a moment ago,
    /// which is newer news than why an earlier press did not start one.
    private var reason: KeyboardLock.Refusal? { lock.interruption ?? lock.refusal }
    private var wasInterrupted: Bool { lock.interruption != nil }

    var body: some View {
        Button {
            press()
        } label: {
            UtilityCard {
                UtilityFace(
                    symbol: reason == nil ? "keyboard" : "hand.raised.fill",
                    dimmed: reason != nil,
                    title: title,
                    caption: caption
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.contentAnimation, value: reason)
        // Drops the press-time reason only: the permission may well have been
        // granted in between, and the pane should not still be asking. What the
        // pane came here to show — why a running lock ended — survives, because
        // the panel is folded at the moment that is written and this return is
        // the first chance to read it.
        .onAppear { lock.clearRefusal() }
    }

    private var title: String {
        if wasInterrupted { return localized("Lock ended early") }
        switch lock.refusal {
        case nil: return localized("Lock Keyboard")
        case .noAccess: return localized("Allow in Settings")
        case .secureInput: return localized("Input is protected")
        case .tapFailed: return localized("Could not take over input")
        case .busy: return localized("Still unlocking")
        }
    }

    /// The captions were broken by hand for a card the width of the whole
    /// pane. At half of it those breaks land mid-line, so they are let go and
    /// the text wraps where it fits.
    private var caption: String {
        rawCaption.replacingOccurrences(of: "\n", with: " ")
    }

    private var rawCaption: String {
        // A lock that ended is a different message from one that never started:
        // nothing is being asked of the user, something is being reported.
        if wasInterrupted {
            return localized("An app turned on secure keyboard entry, so keys stopped\nreaching the lock. It ended instead of pretending")
        }
        switch lock.refusal {
        case nil:
            return localized(
                "Wipe the keys and the screen. Hold Esc or − for %d s to\nunlock; it also unlocks by itself after a minute",
                Int(KeyboardLock.holdToRelease)
            )
        case .noAccess:
            return localized("Cyclop needs Accessibility to swallow keys and clicks.\nSystem Settings → Privacy & Security → Accessibility")
        case .secureInput:
            return localized("An app is holding secure keyboard entry — a password field,\na password manager, a terminal. Close it and press again")
        case .tapFailed:
            return localized("The system refused the event tap. Re-granting Accessibility\nusually fixes it — the permission is tied to the app's signature")
        case .busy:
            return localized("The previous lock is still being taken down.\nPress again in a moment")
        }
    }

    private func press() {
        // A second press on an explained refusal is the way to Settings: for a
        // missing permission because that is where it is granted, and for a
        // failed tap because a rebuilt app is a new signature to TCC and the
        // stale entry has to be replaced by hand. The other two reasons pass
        // through to another attempt — that is what they are waiting for.
        if let reason, reason == .noAccess || reason == .tapFailed {
            lock.openSettings()
            return
        }

        // The system dialog comes with the explanation, not before it.
        if lock.lock() == .noAccess { lock.requestAccess() }
    }
}

// MARK: - Keep awake

/// The face is the switch; the chips under it pick how long. A chip pressed
/// while the mode is on restarts it from now with that preset, which is how a
/// session is extended — so there is nothing else to learn.
private struct KeepAwakeCard: View {
    @ObservedObject var awake: KeepAwake

    var body: some View {
        UtilityCard(isOn: awake.isActive) {
            VStack(spacing: 10) {
                Button {
                    awake.toggle()
                } label: {
                    // Ticks every second only while there is a countdown to
                    // show; otherwise the face has nothing that changes.
                    TimelineView(.periodic(from: .now, by: awake.endsAt == nil ? 3600 : 1)) { context in
                        UtilityFace(
                            symbol: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                            dimmed: awake.failed,
                            title: localized("Keep Mac Awake"),
                            caption: caption(now: context.date)
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    ForEach(KeepAwake.Duration.allCases) { preset in
                        DurationChip(
                            label: KeepAwake.label(preset),
                            isSelected: preset == awake.duration,
                            isOn: awake.isActive
                        ) {
                            awake.start(preset)
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 10)
            .padding(.horizontal, 10)
        }
        .animation(Theme.contentAnimation, value: awake.isActive)
    }

    private func caption(now: Date) -> String {
        if awake.failed {
            return localized("macOS refused to keep the Mac awake. Press again to retry")
        }
        guard awake.isActive else {
            return localized("The screen won't dim or lock while you're away")
        }
        if let left = awake.remaining(now: now) {
            return localized("Ends in %@", KeepAwake.format(left))
        }
        return localized("On until you turn it off")
    }
}

private struct DurationChip: View {
    let label: String
    let isSelected: Bool
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    private var fill: Color {
        if isSelected { return isOn ? Color.accentColor : Theme.surfaceHover }
        return hovering ? Theme.surfaceHover : Theme.surface
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected || hovering ? .white : Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverChange { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.contentAnimation, value: isSelected)
    }
}
