import Foundation
import Testing
@testable import Cyclop

/// Тесты на `ChildProcess` — то, через что вкладка «Markdown» зовёт питон.
///
/// Обе поломки, от которых он защищён, не видны на маленьких документах:
/// вывод больше буфера канала (64 КБ) вешает ребёнка, если его читают только
/// после выхода, а отменённая конвертация оставляет процесс работать на
/// никого. Поэтому здесь вместо питона — системные утилиты, а размеры и
/// времена выбраны так, чтобы обе поломки проявились наверняка.
struct ChildProcessTests {

    @Test func readsOutputLargerThanThePipe() async {
        // Мегабайт на stdout и немного на stderr — в одном запуске.
        let result = await ChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "head -c 1048576 /dev/zero; echo oops >&2"],
            environment: [:]
        )
        #expect(result.status == 0)
        #expect(result.output.count == 1_048_576)
        #expect(String(decoding: result.errors, as: UTF8.self) == "oops\n")
        #expect(!result.cancelled)
    }

    @Test func cancellingTerminatesTheProcess() async {
        let started = Date()
        let task = Task {
            await ChildProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:])
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func reportsAMissingExecutable() async {
        let result = await ChildProcess.run(
            URL(fileURLWithPath: "/nonexistent/python"), [], environment: [:]
        )
        #expect(result.status == -1)
        #expect(!result.errors.isEmpty)
    }
}
