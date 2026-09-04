import ClippyCore
import Foundation
import Observation

/// State the picker view reads and the intent it sends back.
///
/// Holds no AppKit and makes no decisions about pasteboards or windows — the
/// coordinator owns those. This is the seam that keeps the view declarative.
@MainActor
@Observable
final class PickerModel {
    /// What the user has typed into the search field.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectedIndex = 0
            selectionSource = .keyboard
            refreshResults()
        }
    }

    /// Entries matching ``query``, best first.
    ///
    /// Stored rather than computed: the view reads it once per row, and a
    /// computed property re-ran the whole ranked filter every time — hundreds
    /// of scans of hundreds of entries inside one frame, on every keystroke.
    private(set) var results: [ClipSummary] = []

    /// Index into ``results``. Clamped on every read of ``selection``.
    private(set) var selectedIndex = 0

    /// What moved the selection last.
    ///
    /// The list only scrolls to reveal a keyboard selection. Scrolling for a
    /// hover means the list slides around under the pointer as it crosses rows,
    /// which reads as the view fighting the user.
    private(set) var selectionSource: SelectionSource = .keyboard

    /// Bumped every time the search field should take focus.
    ///
    /// `onAppear` is not enough: the hosting view is built and laid out before
    /// the panel is ordered front and made key, so focus set there does not
    /// stick and no keystroke ever reaches SwiftUI.
    private(set) var focusToken = 0

    private var hasPointerMoved = false
    private var firstPointerLocation: CGPoint?
    private static let pointerMovementThreshold: CGFloat = 4

    private let store: HistoryStore
    private let matcher = Matcher()

    /// Sends a chosen entry back to the coordinator.
    var onChoose: ((ClipSummary, PasteStyle) -> Void)?
    var onDismiss: (() -> Void)?
    /// Fires when the result set changes shape, so the panel can resize.
    var onResultsChange: (() -> Void)?

    /// Height the panel needs for the current results.
    var desiredPanelHeight: CGFloat { PickerMetrics.panelHeight(for: results) }

    init(store: HistoryStore) {
        self.store = store
        refreshResults()
        observeStore()
    }

    var isEmpty: Bool { results.isEmpty }

    var selection: ClipSummary? {
        let results = results
        guard !results.isEmpty else { return nil }
        return results[min(selectedIndex, results.count - 1)]
    }

    /// Called once the panel is key, to put the caret in the search field.
    func requestSearchFocus() {
        focusToken += 1
    }

    /// Called when the panel opens, so a stale query never greets the user.
    func reset() {
        query = ""
        selectedIndex = 0
        selectionSource = .keyboard
        hasPointerMoved = false
        firstPointerLocation = nil
        // Unconditional: `query` was already empty on a second open, so its
        // `didSet` does not fire, and the panel is sized from `results`.
        refreshResults()
    }

    // MARK: - Results

    private func refreshResults() {
        results = matcher.filter(store.items, query: query)
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
        onResultsChange?()
    }

    /// Keeps ``results`` in step with the store.
    ///
    /// The view no longer reads `store.items` itself, so nothing else would
    /// notice a capture that lands while the panel is open. `withObservationTracking`
    /// fires exactly once per change and then stops observing, which is why the
    /// handler re-arms it; the hop to the next main-actor turn is because the
    /// callback runs *before* the new value is in place.
    private func observeStore() {
        withObservationTracking {
            _ = store.items
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshResults()
                self?.observeStore()
            }
        }
    }

    // MARK: - Keyboard navigation

    func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectionSource = .keyboard
        selectedIndex = (selectedIndex + offset).clamped(to: 0...(count - 1))
    }

    func selectFirst() {
        selectionSource = .keyboard
        selectedIndex = 0
    }

    func selectLast() {
        selectionSource = .keyboard
        selectedIndex = max(0, results.count - 1)
    }

    /// Hover selection, ignored until the pointer actually moves.
    ///
    /// The panel opens under wherever the cursor happens to be, and without
    /// this the row beneath it is selected instantly — so Return pastes
    /// something the user never chose.
    func hoverSelect(_ item: ClipSummary) {
        guard hasPointerMoved else { return }
        guard let index = results.firstIndex(of: item) else { return }
        selectionSource = .pointer
        selectedIndex = index
    }

    /// Called as the pointer moves over the panel.
    ///
    /// `onContinuousHover` reports `.active` as soon as the cursor is inside,
    /// which happens on open without the user moving anything — so hover only
    /// counts once the position has actually changed.
    func notePointer(at location: CGPoint) {
        guard let origin = firstPointerLocation else {
            firstPointerLocation = location
            return
        }
        guard !hasPointerMoved else { return }
        let distance = hypot(location.x - origin.x, location.y - origin.y)
        hasPointerMoved = distance > Self.pointerMovementThreshold
    }

    /// Called while the list is scrolling, from any cause.
    ///
    /// A scroll slides rows under a stationary pointer, and every row that
    /// passes beneath it reports a hover — so the selection races down the list
    /// while the user is only trying to look at it. Distrusting hover again is
    /// the same state the panel opens in: the pointer has to travel under its
    /// own power before it may select anything.
    func noteScrolling() {
        hasPointerMoved = false
        firstPointerLocation = nil
    }

    /// ⌘1–9 chooses that row outright.
    func chooseRow(at index: Int, style: PasteStyle = .rich) {
        let results = results
        guard results.indices.contains(index) else { return }
        onChoose?(results[index], style)
    }

    func chooseSelection(style: PasteStyle = .rich) {
        guard let selection else { return }
        onChoose?(selection, style)
    }

    // MARK: - Row actions

    /// Store mutations refresh here rather than waiting for ``observeStore``,
    /// which lands a turn later — the caller reads ``results`` on the next line.
    func togglePin(_ item: ClipSummary) {
        store.togglePin(item.id)
        refreshResults()
    }

    func togglePinSelection() {
        guard let selection else { return }
        togglePin(selection)
    }

    func delete(_ item: ClipSummary) {
        let previousIndex = selectedIndex
        store.delete(item.id)
        refreshResults()
        // Keep the selection where the deleted row was, so a run of deletes
        // walks down the list rather than snapping back to the top.
        selectedIndex = previousIndex.clamped(to: 0...max(0, results.count - 1))
    }

    func dismiss() {
        onDismiss?()
    }
}

/// What last moved the selection.
enum SelectionSource {
    case keyboard
    case pointer
}

/// Whether a chosen entry pastes with its formatting or as plain text.
enum PasteStyle: Sendable {
    case rich
    case plainText
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
