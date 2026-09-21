import Foundation
import SkrepkaCore
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// The model is the whole keyboard contract as a value: selection by hash so a
/// refresh keeps the entry, and one effect per acting key.
struct PickerModelTests {
    private func rows(_ hashes: [String]) -> [ClipDocument] {
        hashes.map {
            ClipDocument(
                contentHash: $0,
                preview: $0,
                kind: "text",
                isPinned: $0 == "b",
                createdAt: Date(),
                byteCount: nil,
                representations: [])
        }
    }

    private func model(_ hashes: [String]) -> PickerModel {
        PickerModel(rows: rows(hashes)).reset()
    }

    @Test func resetSelectsFirst() {
        let model = model(["a", "b", "c"])
        #expect(model.selectedIndex == 0)
        #expect(model.selection?.contentHash == "a")
        #expect(model.query.isEmpty)
    }

    @Test func moveSelectionClamps() {
        let start = model(["a", "b", "c"])
        let (down, _) = start.handling(.moveSelection(by: 1))
        #expect(down.selectedIndex == 1)
        let (past, _) = down.handling(.moveSelection(by: 9))
        #expect(past.selectedIndex == 2)
        let (up, _) = past.handling(.moveSelection(by: -9))
        #expect(up.selectedIndex == 0)
    }

    @Test func chooseYieldsSelectedHash() {
        let (_, effect) = model(["a", "b", "c"]).handling(.moveSelection(by: 1)).model
            .handling(.choose(.plainText))
        #expect(effect == .choose(hash: "b", style: .plain))
    }

    @Test func chooseRowByIndex() {
        let (_, effect) = model(["a", "b", "c"]).handling(.chooseRow(index: 2))
        #expect(effect == .choose(hash: "c", style: .rich))
    }

    @Test func togglePinFlipsCurrentState() {
        // "b" is pinned in the fixture, "a" is not.
        let (_, pinA) = model(["a", "b"]).handling(.togglePin)
        #expect(pinA == .setPinned(hash: "a", pinned: true))
        let (_, unpinB) = model(["a", "b"]).handling(.moveSelection(by: 1)).model.handling(.togglePin)
        #expect(unpinB == .setPinned(hash: "b", pinned: false))
    }

    @Test func dismissIsAnEffect() {
        let (_, effect) = model(["a"]).handling(.dismiss)
        #expect(effect == .dismiss)
    }

    @Test func aSearchResultKeepsASelectionThatReturnChooses() {
        // A history selection is replaced by a fresh set of search results that
        // no longer contains it; the model must still have a selection (the top
        // result), so Return chooses something rather than nothing.
        let history = model(["a", "b", "c"])
        let results = history.withRows(rows(["x", "y"]))
        #expect(results.selection?.contentHash == "x")
        let (_, effect) = results.handling(.choose(.rich))
        #expect(effect == .choose(hash: "x", style: .rich))
    }

    @Test func refreshKeepsSelectionByHash() {
        let selectedB = model(["a", "b", "c"]).handling(.moveSelection(by: 1)).model
        let refreshed = selectedB.withRows(rows(["x", "b", "y"]))
        #expect(refreshed.selection?.contentHash == "b")
    }

    @Test func refreshDropsToFirstWhenGone() {
        let selectedB = model(["a", "b", "c"]).handling(.moveSelection(by: 1)).model
        let refreshed = selectedB.withRows(rows(["x", "y"]))
        #expect(refreshed.selection?.contentHash == "x")
    }

    @Test func deleteSelectionYieldsDeleteEffect() {
        let (_, effect) = model(["a", "b", "c"]).handling(.moveSelection(by: 1)).model
            .handling(.deleteSelection)
        #expect(effect == .delete(hash: "b"))
    }

    @Test func removingKeepsTheNeighbourThatSlidesUp() {
        let selectedB = model(["a", "b", "c"]).handling(.moveSelection(by: 1)).model
        let after = selectedB.removing(hash: "b")
        #expect(after.rows.map(\.contentHash) == ["a", "c"])
        #expect(after.selection?.contentHash == "c")
    }

    @Test func removingTheLastRowFallsBackOne() {
        let selectedC = model(["a", "b", "c"]).handling(.selectLast).model
        #expect(selectedC.removing(hash: "c").selection?.contentHash == "b")
    }

    @Test func removingTheOnlyRowEmpties() {
        let after = model(["a"]).removing(hash: "a")
        #expect(after.isEmpty)
        #expect(after.selection == nil)
    }

    @Test func typeChangesNothing() {
        let start = model(["a", "b"]).handling(.moveSelection(by: 1)).model
        let (after, effect) = start.handling(.type)
        #expect(after == start)
        #expect(effect == nil)
    }
}
