import CGtk4
import Foundation
import SkrepkaIPC

/// The canned history the demo shows — one row of every kind the picker draws:
/// an image with a real preview, multi-line code, a link, a plain command, a
/// pinned note, a file with a size, and a concealed entry. Modelled on the
/// macOS `docs/images/picker.png` so the two can be compared side by side.
enum DemoClips {
    private static let linkPreview =
        "https://developer.apple.com/documentation/swiftui/glasseffectcontainer"
    private static let codePreview =
        "func rowHeight(for item: ClipSummary) -> CGFloat { item.thumbnail != nil ? imageRow…"
    private static let notePreview =
        "Retention is two dials, not one: a hard item count and an age cutoff. Pinned entries a…"

    static func all() -> [ClipDocument] {
        let now = Date()
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        return [
            doc(
                hash: "a1",
                preview: "512 × 512",
                kind: "image",
                at: ago(10),
                width: 512,
                height: 512,
                hasPreview: true),
            doc(hash: "b2", preview: linkPreview, kind: "link", at: ago(24)),
            doc(hash: "c3", preview: codePreview, kind: "text", at: ago(40), lines: 3),
            doc(
                hash: "d4",
                preview: "xcrun notarytool submit build/Skrepka.zip --wait",
                kind: "text",
                at: ago(62)),
            doc(hash: "e5", preview: "#0A84FF", kind: "text", at: ago(95)),
            doc(hash: "f6", preview: notePreview, kind: "text", at: ago(140), pinned: true, lines: 3),
            doc(hash: "g7", preview: "skrepka.store", kind: "file", at: ago(180), bytes: 2_400_000, files: 1),
            doc(hash: "h8", preview: "••••••••••••", kind: "text", at: ago(210), concealed: true),
            doc(
                hash: "i9",
                preview: "git rebase --onto master feature~3 feature",
                kind: "text",
                at: ago(320)),
        ]
    }

    private static func doc(
        hash: String,
        preview: String,
        kind: String,
        at date: Date,
        pinned: Bool = false,
        bytes: Int? = nil,
        lines: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        files: Int? = nil,
        concealed: Bool = false,
        hasPreview: Bool = false
    ) -> ClipDocument {
        ClipDocument(
            contentHash: hash,
            preview: preview,
            kind: kind,
            isPinned: pinned,
            createdAt: date,
            byteCount: bytes,
            representations: [],
            lineCount: lines,
            imageWidth: width,
            imageHeight: height,
            fileCount: files,
            isConcealed: concealed,
            hasPreview: hasPreview)
    }

    /// A blue-to-pink gradient with a couple of glass discs, drawn with Cairo
    /// and encoded as PNG — a stand-in screenshot for the image row so its
    /// thumbnail reads as a real picture next to the macOS one.
    static func previewPNG() -> Data? {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 512, 512),
            let context = cairo_create(surface)
        else { return nil }
        defer {
            cairo_destroy(context)
            cairo_surface_destroy(surface)
        }
        paint(into: context)
        let path = NSTemporaryDirectory() + "skrepka-demo-preview.png"
        guard cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func paint(into context: OpaquePointer) {
        if let gradient = cairo_pattern_create_linear(0, 0, 512, 512) {
            cairo_pattern_add_color_stop_rgb(gradient, 0, 0.04, 0.48, 1.0)
            cairo_pattern_add_color_stop_rgb(gradient, 1, 1.0, 0.42, 0.82)
            cairo_set_source(context, gradient)
            cairo_paint(context)
            cairo_pattern_destroy(gradient)
        }
        cairo_set_source_rgba(context, 1, 1, 1, 0.28)
        cairo_arc(context, 360, 150, 92, 0, 2 * Double.pi)
        cairo_fill(context)
        cairo_set_source_rgba(context, 1, 1, 1, 0.16)
        cairo_arc(context, 170, 360, 130, 0, 2 * Double.pi)
        cairo_fill(context)
    }
}
