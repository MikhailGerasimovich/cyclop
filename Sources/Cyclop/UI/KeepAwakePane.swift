import SwiftUI

/// The switch on the left, how long on the right. The switch is the large
/// target because it is the one pressed every time; the presets are only
/// touched to change the answer from last time — and picking one while the
/// mode is on restarts it from now, which is how a session is extended.
struct KeepAwakePane: View {
    @ObservedObject var awake: KeepAwake

    var body: some View {
        HStack(spacing: 10) {
            switchCard
            presets
                .frame(width: 150)
        }
        .animation(Theme.contentAnimation, value: awake.isActive)
    }

    // MARK: - Switch

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private var switchCard: some View {
        Button {
            awake.toggle()
        } label: {
            // Ticks every second only while there is a countdown to show;
            // otherwise nothing on the face changes.
            TimelineView(.periodic(from: .now, by: awake.endsAt == nil ? 3600 : 1)) { context in
                VStack(spacing: 6) {
                    Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(awake.failed ? Color.white.opacity(0.75) : .white)
                        .frame(height: 30)
                        .contentTransition(.symbolEffect(.replace))

                    Text(localized("Keep Mac Awake"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)

                    Text(caption(now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(awake.isActive ? Theme.secondary : Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(awake.isActive ? Color.accentColor.opacity(0.16) : Theme.surface))
            .overlay(shape.strokeBorder(awake.isActive ? Color.accentColor.opacity(0.45) : Theme.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
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

    // MARK: - Presets

    private var presets: some View {
        VStack(spacing: 6) {
            ForEach(KeepAwake.Duration.allCases) { preset in
                PresetRow(
                    label: KeepAwake.label(preset),
                    isSelected: preset == awake.duration,
                    isOn: awake.isActive
                ) {
                    awake.start(preset)
                }
            }
        }
    }
}

private struct PresetRow: View {
    let label: String
    let isSelected: Bool
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    /// The last pick is always marked, so the switch says what it will do
    /// before it is pressed; it turns accent once it is actually running.
    private var fill: Color {
        if isSelected { return isOn ? Color.accentColor : Theme.surfaceHover }
        return hovering ? Theme.surfaceHover : Theme.surface
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected || hovering ? .white : Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(fill))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(Theme.contentAnimation, value: isSelected)
    }
}
