// The safety net for the projection. SwiftData only: `SQLiteHistoryStore`
// computes its list on demand and has nothing to drift from.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    /// That `items` still says what the database says.
    ///
    /// The list is maintained by delta — every mutation writes what it changed
    /// instead of refetching every row — so the regression this design can have is
    /// that the two quietly disagree, and the user is the one who notices. Each
    /// case here turns on ``HistoryStore/verifiesProjection``, which makes the
    /// store re-derive the whole list from the store after every publish and
    /// record the first mismatch in ``HistoryStore/projectionDrift``, then drives
    /// one mutation path and asserts there was none.
    ///
    /// ``theCheckItselfCatchesADivergence`` is the case that keeps the rest
    /// honest: a check that cannot fail asserts nothing.
    @Suite("History store projection")
    @MainActor
    struct HistoryStoreProjectionTests {
        private static func makeStore(
            retention: RetentionPolicy = .unlimited
        ) throws -> HistoryStore {
            let store = try HistoryStore(location: nil, retention: retention)
            store.localDeviceID = EngineFixtures.localDevice
            store.verifiesProjection = true
            return store
        }

        private static func item(_ text: String, at offset: TimeInterval) -> ClipItem {
            EngineFixtures.item(text, at: EngineFixtures.at(offset))
        }

        /// Both lists, so a failure says which entry moved rather than "not nil".
        private static func report(_ drift: ProjectionDrift?) -> String {
            guard let drift else { return "no drift" }
            return """
                projected \(drift.projected.map(\.text)) \
                but the store says \(drift.rebuilt.map(\.text))
                """
        }

        // MARK: - Capture

        @Test("Capturing entries leaves the projection matching the store")
        func capture() async throws {
            let store = try Self.makeStore()
            for (index, text) in ["first", "second", "third"].enumerated() {
                await store.capture(Self.item(text, at: TimeInterval(index)))
            }

            #expect(store.items.map(\.text) == ["third", "second", "first"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("Entries captured in the same instant keep the order the store gives them")
        func captureWithTiedTimestamps() async throws {
            let store = try Self.makeStore()
            for text in ["first", "second", "third"] {
                await store.capture(Self.item(text, at: 1))
            }

            // The tie-break `orderingIsTheSameOnEveryRead` pins, reproduced by a
            // delta rather than by re-reading the store.
            #expect(store.items.map(\.text) == ["first", "second", "third"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("A repeat copy collapses onto the entry it duplicates")
        func repeatCopy() async throws {
            let store = try Self.makeStore()
            await store.capture(Self.item("same", at: 1))
            await store.capture(Self.item("other", at: 2))
            await store.capture(Self.item("same", at: 3))

            #expect(store.items.map(\.text) == ["same", "other"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("A repeat copy that backfills a thumbnail republishes the row")
        func thumbnailBackfill() async throws {
            let store = try Self.makeStore()
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "shot.png", directoryHint: .notDirectory)

            let file = ClipItem(kind: .file, text: "shot.png", payload: Fixtures.fileURLPayload(url))
            await store.capture(file)
            #expect(store.items.first?.hasThumbnail == false)

            try Fixtures.png(width: 64, height: 48).write(to: url)
            await store.capture(file)

            // `hasThumbnail` is part of the projection, so a backfill that the
            // list did not notice is exactly the drift this suite looks for.
            #expect(store.items.first?.hasThumbnail == true)
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        // MARK: - Mutation

        @Test("Pinning and unpinning leave the projection matching the store")
        func togglePin() async throws {
            let store = try Self.makeStore()
            for text in ["first", "second", "third"] {
                await store.capture(Self.item(text, at: 1))
            }
            let middle = try #require(store.items.first { $0.text == "second" })

            store.togglePin(middle.id)
            #expect(store.items.map(\.text) == ["second", "first", "third"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")

            store.togglePin(middle.id)
            #expect(store.items.map(\.text) == ["first", "second", "third"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("Deleting leaves the projection matching the store")
        func delete() async throws {
            let store = try Self.makeStore()
            for (index, text) in ["first", "second"].enumerated() {
                await store.capture(Self.item(text, at: TimeInterval(index)))
            }
            let doomed = try #require(store.items.last)

            store.delete(doomed.id)
            #expect(store.items.map(\.text) == ["second"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("Clearing leaves the projection matching the store", arguments: [true, false])
        func clear(keepingPinned: Bool) async throws {
            let store = try Self.makeStore()
            await store.capture(Self.item("kept", at: 1))
            await store.capture(Self.item("swept", at: 2))
            store.togglePin(try #require(store.items.first { $0.text == "kept" }).id)

            store.clear(keepingPinned: keepingPinned)
            #expect(store.items.map(\.text) == (keepingPinned ? ["kept"] : []))
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("Eviction leaves the projection matching the store")
        func retention() async throws {
            let store = try Self.makeStore(retention: RetentionPolicy(maximumItems: 2, maximumAge: nil))
            for (index, text) in ["first", "second", "third"].enumerated() {
                await store.capture(Self.item(text, at: TimeInterval(index)))
            }

            #expect(store.items.map(\.text) == ["third", "second"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")

            // And again through the setting, which is the other way in.
            store.retention = RetentionPolicy(maximumItems: 1, maximumAge: nil)
            #expect(store.items.map(\.text) == ["third"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        // MARK: - Sync

        @Test("A merge plan leaves the projection matching the store")
        func applyRemote() async throws {
            let store = try Self.makeStore()
            await store.capture(Self.item("local", at: 1))
            let local = EngineFixtures.contentHash("local")

            try store.applyRemote([
                .insert(EngineFixtures.meta("learned", at: EngineFixtures.at(5))),
                .insert(EngineFixtures.meta("doomed", at: EngineFixtures.at(6))),
                .bumpCreatedAt(contentHash: local, to: EngineFixtures.at(9)),
                .applyPin(
                    contentHash: EngineFixtures.contentHash("learned"),
                    register: LWWRegister(
                        value: true,
                        timestamp: EngineFixtures.at(7),
                        deviceID: EngineFixtures.peerDevice
                    )
                ),
                .deleteLocally(contentHash: EngineFixtures.contentHash("doomed")),
                .recordTombstone(
                    Tombstone(
                        contentHash: EngineFixtures.contentHash("doomed"),
                        deletedAt: EngineFixtures.at(8),
                        deviceID: EngineFixtures.peerDevice
                    )
                ),
            ])

            #expect(store.items.map(\.text) == ["learned", "local"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("A plan longer than one chunk leaves the projection matching the store")
        func applyRemoteAcrossChunks() async throws {
            let store = try Self.makeStore()
            let actions: [MergeAction] = (0..<250).map { index in
                .insert(EngineFixtures.meta("remote \(index)", at: EngineFixtures.at(TimeInterval(index))))
            }

            try store.applyRemote(actions)

            #expect(store.items.count == 250)
            #expect(store.items.first?.text == "remote 249")
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        @Test("Learning one item from a peer leaves the projection matching the store")
        func captureFromPeer() async throws {
            let store = try Self.makeStore()
            await store.capture(Self.item("local", at: 1))

            try store.capture(
                EngineFixtures.meta("learned", at: EngineFixtures.at(2)),
                payloads: [EngineFixtures.plainTextKey: Data("learned".utf8)]
            )

            #expect(store.items.map(\.text) == ["learned", "local"])
            #expect(store.projectionDrift == nil, "\(Self.report(store.projectionDrift))")
        }

        // MARK: - The check itself

        @Test("The check catches a projection that stopped matching the store")
        func theCheckItselfCatchesADivergence() async throws {
            let store = try Self.makeStore()
            await store.capture(Self.item("present", at: 1))
            #expect(store.projectionDrift == nil)

            // What a mishandled delta looks like from the outside: a row the store
            // holds and the list does not.
            store.projection = .empty
            store.project()

            let drift = try #require(store.projectionDrift)
            #expect(drift.projected.isEmpty)
            #expect(drift.rebuilt.map(\.text) == ["present"])
        }

        @Test("Publishing is what the picker observes")
        func publishingNotifiesObservers() async throws {
            let store = try Self.makeStore()
            // The same shape `PickerModel.observeStore()` uses: `items` is a view
            // of the projection, so this fires only if Observation tracks it
            // through the stored property behind it.
            await confirmation("the store republished its list") { republished in
                withObservationTracking {
                    _ = store.items
                } onChange: {
                    republished()
                }

                await store.capture(Self.item("copied", at: 1))
            }
        }
    }

#endif
