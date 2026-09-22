import CGtk4
import Foundation
import SkrepkaCore
import SkrepkaIPC

/// The picker, assembled: the window, daemon link and model.
/// This is the whole surface the app shell drives — build it hidden, prefetch,
/// and open it on the hotkey. Everything the daemon says arrives on the
/// concurrency pool and is applied here on GTK's loop thread through a
/// ``MainLoopInbox``, so no widget is ever touched off that thread.
public final class PickerController {
    /// Opens Settings; the picker closes first. Wired by the app shell.
    public var onOpenSettings: (() -> Void)?
    var paster: (any PasteHandling)?

    private let window: PaletteWindow
    private let link: PickerLink
    private let inbox: MainLoopInbox<PickerEvent>
    private var watch: MainLoopWatch<PickerEvent>?
    private let thumbnails = ThumbnailCache()

    private var model = PickerModel()
    /// The full history from the latest `history` reply, so opening the picker
    /// paints the whole list from cache before any search runs.
    private var historyRows: [ClipDocument] = []
    /// The rows currently on screen, by hash, for the context menu's pin state.
    private var documents: [String: ClipDocument] = [:]
    private var requestedPreviews: Set<String> = []
    private var appearance = AppearancePreference.unknown
    private var isDark = true
    /// Whether the pointer has moved since the picker opened. Hover selects only
    /// once it has, so a pointer that the surface merely mapped under does not
    /// pull the selection off the top row.
    private var hoverArmed = false
    /// Counts openings, so a reply to an entry chosen in an earlier one is told apart.
    private var opening = 0
    private var chosenOpening: Int?
    /// Retains the demo's one-shot menu timer for its lifetime.
    private var menuTimer: LoopTimer?

    /// - Parameter connect: opens a fresh daemon proxy — `SkrepkaBus.proxy(on:)`
    ///   in the app, a fake in the demo and tests.
    public init(connect: @escaping @Sendable () async throws -> any PickerDaemon) throws {
        window = try PaletteWindow()
        let inbox = try MainLoopInbox<PickerEvent>()
        self.inbox = inbox
        link = PickerLink(connect: connect, report: { inbox.post($0) })
        watch = try MainLoopWatch(inbox: inbox) { [weak self] event in self?.handle(event) }
        wire()
        restyle()
    }

    private func wire() {
        window.onCommand = { [weak self] command in self?.handle(command) }
        window.panel.searchBar.onQueryChanged = { [weak self] query in self?.query(query) }
        window.panel.list.onActivate = { [weak self] hash in self?.choose(hash, style: .rich) }
        window.panel.list.onHover = { [weak self] hash in self?.hover(hash) }
        window.panel.list.onPointerMoved = { [weak self] in self?.hoverArmed = true }
        window.panel.list.onPin = { [weak self] hash in self?.pin(hash) }
        window.panel.list.onCopyPlain = { [weak self] hash in self?.choose(hash, style: .plain) }
        window.panel.list.onDelete = { [weak self] hash in self?.delete(hash) }
        window.panel.footer.onOpenSettings = { [weak self] in
            self?.hide()
            self?.onOpenSettings?()
        }
    }

    // MARK: - Lifecycle

    /// Builds nothing new — the window is already hidden and built — and starts
    /// the link prefetching and watching. `.medium` because a task spawned from
    /// GTK's thread is otherwise given a priority libdispatch then refuses.
    public func start() {
        let link = link
        Task(priority: .medium) { await link.start() }
    }

    public func show() {
        opening += 1
        link.refreshSettings()
        hoverArmed = false
        model = PickerModel(rows: historyRows).reset()
        window.panel.footer.showError(nil)
        window.panel.searchBar.text = ""
        render(rebuild: true)
        window.present()
    }

    /// Opens the context menu on the selected row — the app shell can bind it to a Menu key.
    public func openMenuForSelection() { window.panel.list.openMenuForSelection() }

    /// Opens the context menu after a short delay, once the surface has mapped —
    /// the demo uses it to screenshot the menu, which a right-click cannot be
    /// synthesised to trigger under the headless harness.
    public func openMenuForSelection(afterSeconds seconds: UInt32) {
        menuTimer = LoopTimer(seconds: seconds) { [weak self] in
            self?.window.panel.list.openMenuForSelection()
            self?.menuTimer?.cancel()
        }
    }

    public func hide() { window.close() }

    public func toggle() {
        if window.isVisible {
            hide()
        } else {
            show()
        }
    }

    public var isVisible: Bool { window.isVisible }

    public func apply(_ appearance: AppearancePreference) {
        self.appearance = appearance
        restyle()
    }

    private func restyle() {
        isDark = Self.resolveDark(appearance)
        PickerStyle.apply(appearance, isDark: isDark)
        window.panel.apply(isDark: isDark)
    }

    private static func resolveDark(_ appearance: AppearancePreference) -> Bool {
        switch appearance.colorScheme {
        case .dark: true
        case .light: false
        case .noPreference: skrepka_prefers_dark() != 0
        }
    }

    // MARK: - Intent

    private func query(_ text: String) {
        model = model.withQuery(text)
        window.panel.footer.showError(nil)
        link.search(text)
    }

    private func handle(_ command: PickerCommand) {
        let (next, effect) = model.handling(command)
        if next != model {
            model = next
            render(rebuild: false)
        }
        guard let effect else { return }
        switch effect {
        case .choose(let hash, let style): choose(hash, style: style)
        case .setPinned(let hash, let pinned): link.setPinned(hash: hash, pinned: pinned)
        case .delete(let hash): delete(hash)
        case .dismiss: hide()
        }
    }

    private func hover(_ hash: String) {
        guard hoverArmed else { return }
        let next = model.selecting(hash: hash)
        guard next != model else { return }
        model = next
        render(rebuild: false)
    }

    private func choose(_ hash: String, style: CopyStyle) {
        chosenOpening = opening
        window.panel.footer.showError(nil)
        link.refreshSettings()
        link.copy(hash: hash, style: style)
    }

    /// Toggles a row's pin from the context menu, reading its current state.
    private func pin(_ hash: String) {
        guard let document = documents[hash] else { return }
        link.setPinned(hash: hash, pinned: !document.isPinned)
    }

    /// Deletes a row — from the menu or Alt+Backspace. The list updates at once
    /// with the selection moved to the neighbour; the daemon confirms.
    private func delete(_ hash: String) {
        window.panel.footer.showError(nil)
        model = model.removing(hash: hash)
        render(rebuild: true)
        link.delete(hash: hash)
    }
}

// MARK: - Applying daemon events, and rendering

// An extension for length alone: the class body is the controller's state and
// the intent it sends, this is what comes back and how it is drawn. Same file,
// so the private state stays private.
extension PickerController {
    private func handle(_ event: PickerEvent) {
        switch event {
        case .history, .results, .preview, .transfers: applyList(event)
        case .settings, .copied, .failed, .unreachable: applyOutcome(event)
        }
    }

    /// What the daemon said about the rows: which there are, their pictures,
    /// and how far each arriving one has got.
    private func applyList(_ event: PickerEvent) {
        switch event {
        case .history(let rows):
            historyRows = rows
            if !isVisible || model.query.isEmpty { apply(rows: rows) }
        case .results(let query, let rows):
            guard query == window.panel.searchBar.text else { return }
            apply(rows: rows)
        case .preview(let hash, let document):
            store(preview: document, for: hash)
        case .transfers(let fractions):
            window.panel.list.showTransfers(fractions)
        case .settings, .copied, .failed, .unreachable:
            break
        }
    }

    /// What became of something the user asked for.
    private func applyOutcome(_ event: PickerEvent) {
        switch event {
        case .settings(let automatically):
            window.panel.footer.showPasteAutomatically(automatically)
            paster?.setAutomaticPasteEnabled(automatically)
        case .copied(let automatically):
            // A reply to a dismissed or replaced opening leaves the entry copied, and nothing else.
            guard
                PickerPasteAction.shouldComplete(
                    isVisible: isVisible, chosenOpening: chosenOpening, currentOpening: opening)
            else { return }
            PickerPasteAction.complete(
                isAutomatic: automatically,
                paster: paster,
                afterModifiersReleased: window.afterModifiersReleased,
                hide: hide)
        case .failed(let message):
            window.panel.footer.showError(message)
        case .unreachable(let headline, let detail):
            window.panel.showEmpty(.unreachable(headline: headline, detail: detail))
        case .history, .results, .preview, .transfers:
            break
        }
    }

    private func apply(rows: [ClipDocument]) {
        // Skip identical rows. A search reply and a `HistoryChanged`-driven
        // re-prefetch often carry the same list; re-rendering it would rebuild
        // the widgets and re-commit the layer surface for nothing, and a layer
        // surface that re-configures under a keystroke can drop it.
        guard rows != model.rows else { return }
        model = model.withRows(rows)
        render(rebuild: true)
    }

    private func store(preview document: PreviewDocument, for hash: String) {
        guard let bytes = document.bytes else { return }
        guard thumbnails.store(hash: hash, data: bytes) != nil else { return }
        render(rebuild: true)
    }

    // MARK: - Rendering

    private func render(rebuild: Bool) {
        let rows = model.rows
        documents = Dictionary(rows.map { ($0.contentHash, $0) }, uniquingKeysWith: { first, _ in first })
        if rows.isEmpty {
            window.panel.showEmpty(model.query.isEmpty ? .noHistory : .noMatches)
        } else {
            window.panel.showList()
            if rebuild {
                window.panel.list.setRows(rows, text: rowText, texture: texture)
                requestPreviews(rows)
            }
            window.panel.list.select(index: model.selectedIndex)
        }
        window.panel.searchBar.showResults(count: rows.count, hasQuery: !model.query.isEmpty)
        window.resize(for: rows)
    }

    private func rowText(_ document: ClipDocument) -> PickerRowText {
        PickerRowTextBuilder.make(document, now: Date())
    }

    private func texture(_ document: ClipDocument) -> OpaquePointer? {
        thumbnails.texture(for: document.contentHash)
    }

    /// Asks for the pictures of the first rows that have one and are not cached,
    /// once each — the macOS list prefetches the first twenty for the same
    /// reason, so scrolling does not stutter fetching them one at a time.
    private func requestPreviews(_ rows: [ClipDocument]) {
        for document in rows.prefix(20) where document.hasPreview && !document.isConcealed {
            let hash = document.contentHash
            guard !thumbnails.contains(hash), !requestedPreviews.contains(hash) else { continue }
            requestedPreviews.insert(hash)
            link.preview(hash: hash)
        }
    }
}
