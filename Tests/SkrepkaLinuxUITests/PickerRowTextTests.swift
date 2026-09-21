import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// The subtitle assembly mirrors the macOS `ClipRowView`: type · image size ·
/// byte size · line count · age, dropping the parts that do not apply.
struct PickerRowTextTests {
    /// A fixed age so the assembly can be asserted exactly.
    private func age(_ from: Date, _ to: Date) -> String { "10 seconds ago" }

    private func document(
        kind: String,
        preview: String = "x",
        bytes: Int? = nil,
        lines: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        files: Int? = nil,
        concealed: Bool = false
    ) -> ClipDocument {
        ClipDocument(
            contentHash: "h",
            preview: preview,
            kind: kind,
            isPinned: false,
            createdAt: Date(),
            byteCount: bytes,
            representations: [],
            lineCount: lines,
            imageWidth: width,
            imageHeight: height,
            fileCount: files,
            isConcealed: concealed,
            hasPreview: false)
    }

    @Test func multiLineText() {
        let text = PickerRowTextBuilder.make(
            document(kind: "text", preview: "hello", lines: 3), now: Date(), relativeAge: age)
        #expect(text.title == "hello")
        #expect(text.subtitle == "Text · 3 lines · 10 seconds ago")
    }

    @Test func imageShowsDimensions() {
        let text = PickerRowTextBuilder.make(
            document(kind: "image", width: 1402, height: 578), now: Date(), relativeAge: age)
        #expect(text.subtitle == "Image · 1402 × 578 · 10 seconds ago")
    }

    @Test func fileCountsAndSizes() {
        let text = PickerRowTextBuilder.make(
            document(kind: "file", bytes: 2_400_000, files: 3), now: Date(), relativeAge: age)
        #expect(text.subtitle == "3 Files · 2.4 MB · 10 seconds ago")
    }

    @Test func concealedHidesEverythingButType() {
        let text = PickerRowTextBuilder.make(
            document(kind: "text", bytes: 999, lines: 4, concealed: true), now: Date(), relativeAge: age)
        #expect(text.subtitle == "Text · 10 seconds ago")
    }

    @Test func unknownKindStillLabels() {
        let text = PickerRowTextBuilder.make(
            document(kind: "selection"), now: Date(), relativeAge: age)
        #expect(text.subtitle == "Selection · 10 seconds ago")
    }

    private func fileDocument(status: String) -> ClipDocument {
        ClipDocument(
            contentHash: "h",
            preview: "shot.png",
            kind: "file",
            isPinned: false,
            createdAt: Date(),
            byteCount: nil,
            representations: [],
            fileCount: 1,
            filesStatus: status
        )
    }

    @Test func fileRowWhoseContentsStayedBehindSaysSo() {
        let row = fileDocument(status: ClipDocument.FilesStatusName.notSynced)
        let text = PickerRowTextBuilder.make(row, now: Date(), relativeAge: age)
        #expect(text.subtitle == "File · contents not synced · 10 seconds ago")
    }

    /// The Mac picker's words while the files are still on their way.
    @Test func fileRowWhoseContentsAreOnTheirWaySaysSo() {
        let row = fileDocument(status: ClipDocument.FilesStatusName.pending)
        let text = PickerRowTextBuilder.make(row, now: Date(), relativeAge: age)
        #expect(text.subtitle == "File · contents not synced yet · 10 seconds ago")
    }

    @Test func syncedFileRowSaysNothingExtra() {
        let row = fileDocument(status: ClipDocument.FilesStatusName.synced)
        let text = PickerRowTextBuilder.make(row, now: Date(), relativeAge: age)
        #expect(text.subtitle == "File · 10 seconds ago")
    }
}
