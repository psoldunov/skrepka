import CGtk4
import Testing

@Suite("GTK main-loop shutdown")
struct GtkMainLoopTests {
    @Test("A quit queued before run survives loop startup")
    func quitBeforeRun() throws {
        // A private context makes this independent of GTK/display state and
        // other tests. This is the publish-before-run gap in GtkSession.
        let context = try #require(g_main_context_new())
        defer { g_main_context_unref(context) }
        let loop = try #require(g_main_loop_new(context, 0))
        defer { g_main_loop_unref(loop) }

        // Bound a regression instead of hanging the suite: a direct quit
        // before run is lost, so only this watchdog could then stop the loop.
        let watchdog = try #require(g_timeout_source_new(1000))
        defer {
            g_source_destroy(watchdog)
            g_source_unref(watchdog)
        }
        g_source_set_callback(
            watchdog,
            { data in
                g_main_loop_quit(OpaquePointer(data))
                return 0
            },
            UnsafeMutableRawPointer(loop),
            nil
        )
        g_source_attach(watchdog, context)

        skrepka_schedule_main_loop_quit(loop)
        g_main_loop_run(loop)

        #expect(g_source_is_destroyed(watchdog) == 0, "Queued quit must beat the watchdog")
    }
}
