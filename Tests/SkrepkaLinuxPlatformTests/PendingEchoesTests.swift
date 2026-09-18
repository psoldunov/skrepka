import Testing

@testable import SkrepkaLinuxPlatform

/// Which report of Skrepka's own write is published, when writes and reports
/// interleave in ways a live session only hits by chance.
@Suite("Pending echoes")
struct PendingEchoesTests {
    private static let text = ["text/plain;charset=utf-8", "text/plain"]
    private static let image = ["image/png"]

    @Test("A copy's report is published")
    func aCopyIsPublished() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.text)
        let first = echoes.takeReport()
        #expect(first)
    }

    @Test("A handoff's report is not published")
    func aHandoffIsNot() {
        var echoes = PendingEchoes()
        echoes.took(.handoff, offering: Self.text)
        let first = echoes.takeReport()
        #expect(!first)
    }

    /// Judged by the current write, both reports were published with the
    /// copy's bytes: one copy, two captures, two pushes.
    @Test("A copy made just after a handoff is published once, on its own report")
    func aCopyAfterAHandoffIsPublishedOnce() {
        var echoes = PendingEchoes()
        echoes.took(.handoff, offering: Self.text)
        echoes.took(.copy, offering: Self.text)
        let handoffReport = echoes.takeReport()
        let copyReport = echoes.takeReport()
        #expect(!handoffReport)
        #expect(copyReport)
    }

    /// The clipboard holds the peer's content by the time either report
    /// arrives; recording the copy would push older content over it.
    @Test("A copy overtaken by a handoff is never published")
    func aCopyOvertakenByAHandoffIsNot() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.text)
        echoes.took(.handoff, offering: Self.text)
        let copyReport = echoes.takeReport()
        let handoffReport = echoes.takeReport()
        #expect(!copyReport)
        #expect(!handoffReport)
    }

    @Test("Two copies in a row publish the second once")
    func twoCopiesPublishTheSecondOnce() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.text)
        echoes.took(.copy, offering: Self.text)
        let first = echoes.takeReport()
        let second = echoes.takeReport()
        #expect(!first)
        #expect(second)
    }

    @Test("A report with nothing pending is not published")
    func aStrayReportIsNot() {
        var echoes = PendingEchoes()
        let stray = echoes.takeReport()
        #expect(!stray)
    }

    @Test("Once ownership is gone, no report is recognised or published")
    func removeAllForgetsEveryWrite() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.text)
        echoes.removeAll()
        #expect(!echoes.isReport(offering: Self.text))
        let late = echoes.takeReport()
        #expect(!late)
    }

    /// Wayland recognises a report by its targets, and the report that comes
    /// next belongs to the oldest write, not the newest.
    @Test("A report is matched against the oldest pending write")
    func reportsMatchTheOldestWrite() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.image)
        echoes.took(.copy, offering: Self.text)
        #expect(echoes.isReport(offering: Self.image))
        #expect(!echoes.isReport(offering: Self.text))

        _ = echoes.takeReport()
        #expect(echoes.isReport(offering: Self.text))
    }

    /// A Wayland compositor clears the selection when Skrepka destroys the
    /// source a write replaces, and only then reports the write. Published, that
    /// clear was a change the clipboard never settled on.
    @Test("The clear ahead of a replacing write's report is absorbed, once")
    func theReplacementClearIsAbsorbedOnce() {
        var echoes = PendingEchoes()
        echoes.took(.handoff, offering: Self.text, afterClearing: true)
        let replacement = echoes.takeClear()
        let second = echoes.takeClear()
        #expect(replacement)
        #expect(!second)
        #expect(echoes.isReport(offering: Self.text))
        let report = echoes.takeReport()
        #expect(!report)
    }

    @Test("A clear is real when no write replaced a source of Skrepka's")
    func aClearWithNothingReplacedIsReal() {
        var echoes = PendingEchoes()
        let idle = echoes.takeClear()
        echoes.took(.copy, offering: Self.text)
        let pending = echoes.takeClear()
        #expect(!idle)
        #expect(!pending)
    }

    /// A compositor that reports the write without the clear must not leave
    /// the expectation behind to swallow a real clear later.
    @Test("A clear expected but never sent is forgotten with its write's report")
    func anUnsentClearDiesWithItsReport() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.text, afterClearing: true)
        let report = echoes.takeReport()
        let later = echoes.takeClear()
        #expect(report)
        #expect(!later)
    }

    /// In a burst, each replacing write's clear lands after the previous
    /// write's report, so it is judged by the write it precedes.
    @Test("Each write in a burst absorbs the clear ahead of its own report")
    func aBurstAbsorbsOneClearPerReplacement() {
        var echoes = PendingEchoes()
        echoes.took(.copy, offering: Self.text)
        echoes.took(.handoff, offering: Self.text, afterClearing: true)
        let copyReport = echoes.takeReport()
        let clear = echoes.takeClear()
        let handoffReport = echoes.takeReport()
        #expect(!copyReport)
        #expect(clear)
        #expect(!handoffReport)
    }

    /// A report that never came must not grow the queue for good. Past the
    /// ceiling the oldest go, and the newest write still publishes.
    @Test("The queue is bounded, and the newest copy survives the bound")
    func theQueueIsBounded() {
        var echoes = PendingEchoes()
        for _ in 0..<(PendingEchoes.capacity + 4) {
            echoes.took(.copy, offering: Self.text)
        }
        let published = (0..<PendingEchoes.capacity).filter { _ in echoes.takeReport() }
        #expect(published.count == 1)
        let beyond = echoes.takeReport()
        #expect(!beyond)
    }
}
