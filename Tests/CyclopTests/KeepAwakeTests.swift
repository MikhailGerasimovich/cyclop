import Foundation
import Testing
@testable import Cyclop

/// Тесты на `KeepAwake` — режим, который не даёт Mac уснуть и экрану
/// заблокироваться.
///
/// Настоящие IOKit-утверждения здесь не берутся: тест, который правда держит
/// Mac бодрым, менял бы энергосостояние машины, на которой его запустили.
/// Вместо них — счётчик, и проверяется ровно то, что обещает сервис: держит,
/// пока включён, отпускает при любом выходе из режима и честно сообщает,
/// когда система отказала.
@MainActor
struct KeepAwakeTests {

    private final class FakePower: PowerAssertions {
        var isHeld = false
        var refuses = false
        var holds = 0

        func hold(reason: String) -> Bool {
            guard !refuses else { return false }
            if !isHeld { holds += 1 }
            isHeld = true
            return true
        }

        func release() { isHeld = false }
    }

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aPresetHoldsUntilItsTimeRunsOut() {
        let power = FakePower()
        let awake = KeepAwake(power: power)

        awake.start(.quarterHour, now: Self.start)
        #expect(awake.isActive)
        #expect(power.isHeld)
        #expect(awake.endsAt == Self.start.addingTimeInterval(15 * 60))
        let left = awake.remaining(now: Self.start.addingTimeInterval(60)) ?? -1
        #expect(abs(left - 14 * 60) < 0.001)

        awake.expireIfDue(now: Self.start.addingTimeInterval(14 * 60))
        #expect(awake.isActive)

        awake.expireIfDue(now: Self.start.addingTimeInterval(15 * 60))
        #expect(!awake.isActive)
        #expect(!power.isHeld)
        #expect(awake.endsAt == nil)
    }

    @Test func indefiniteNeverExpires() {
        let power = FakePower()
        let awake = KeepAwake(power: power)

        awake.start(.indefinite, now: Self.start)
        awake.expireIfDue(now: Self.start.addingTimeInterval(7 * 24 * 3600))

        #expect(awake.isActive)
        #expect(awake.endsAt == nil)
        #expect(awake.remaining() == nil)
    }

    @Test func toggleRestartsTheLastPreset() {
        let power = FakePower()
        let awake = KeepAwake(power: power, duration: .hour)

        awake.toggle()
        #expect(awake.isActive)
        #expect(awake.duration == .hour)

        awake.toggle()
        #expect(!awake.isActive)
        #expect(!power.isHeld)

        awake.start(.threeHours)
        awake.stop()
        awake.toggle()
        #expect(awake.duration == .threeHours)
        #expect(awake.isActive)
    }

    @Test func pickingAnotherPresetRestartsFromNowWithOneHold() {
        let power = FakePower()
        let awake = KeepAwake(power: power)

        awake.start(.quarterHour, now: Self.start)
        let later = Self.start.addingTimeInterval(10 * 60)
        awake.start(.hour, now: later)

        #expect(awake.endsAt == later.addingTimeInterval(60 * 60))
        #expect(power.holds == 1)
    }

    @Test func thePickIsRemembered() {
        var saved: [KeepAwake.Duration] = []
        let awake = KeepAwake(power: FakePower(), remember: { saved.append($0) })

        awake.start(.threeHours)
        awake.start(.indefinite)

        #expect(saved == [.threeHours, .indefinite])
    }

    @Test func aRefusalIsReportedAndNothingIsHeld() {
        let power = FakePower()
        power.refuses = true
        let awake = KeepAwake(power: power)

        awake.start(.hour)
        #expect(!awake.isActive)
        #expect(awake.failed)

        power.refuses = false
        awake.toggle()
        #expect(awake.isActive)
        #expect(!awake.failed)
    }

    @Test func remainingTimeRoundsUp() {
        #expect(KeepAwake.format(59 * 60 + 1) == KeepAwake.format(60 * 60))
        #expect(KeepAwake.format(0.2) == KeepAwake.format(1))
        #expect(KeepAwake.label(.indefinite) == localized("Until I turn it off"))
    }
}
