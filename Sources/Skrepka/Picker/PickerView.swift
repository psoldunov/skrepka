import SkrepkaCore
import SwiftUI

/// The picker's root.
///
/// One unified glass panel, the way Spotlight is: a single surface with a
/// search field at the top, a hairline, the list, another hairline, and the key
/// hints. Nothing inside carries its own glass — stacking glass on glass reads
/// muddy and makes the panel look assembled rather than made.
struct PickerView: View {
    @Bindable var model: PickerModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool

    private static let cornerRadius: CGFloat = 20
    /// Rows to move for one Page Up / Page Down.
    private static let pageJump = 8

    var body: some View {
        // GeometryReader, not a flexible frame: a `LazyVStack` inside a
        // `ScrollView` reports a tiny ideal height before its rows materialise,
        // so a `maxHeight: .infinity` scroll view collapses to that ideal and
        // gets centred, leaving dead space above and below the list. Handing it
        // a definite height removes the circularity.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                SearchField(text: $model.query, resultCount: model.results.count)
                    .focused($isSearchFocused)
                    .frame(height: PickerMetrics.searchFieldHeight)

                PanelSeparator()

                Group {
                    if model.isEmpty {
                        EmptyStateView(
                            hasQuery: !model.query.isEmpty,
                            isBlocked: model.captureHealth.isBlocked
                        )
                    } else {
                        resultList
                    }
                }
                .frame(height: max(0, geometry.size.height - PickerMetrics.chromeHeight))
                .frame(maxWidth: .infinity)

                PanelSeparator()

                FooterHintsView()
                    .frame(height: PickerMetrics.footerHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelSurface)
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .onAppear { isSearchFocused = true }
        .onChange(of: model.focusToken) { _, _ in isSearchFocused = true }
        .onContinuousHover { phase in
            if case .active(let location) = phase { model.notePointer(at: location) }
        }
        .onKeyPress(phases: [.down, .repeat], action: handle(keyPress:))
    }

    /// Every shortcut in one place.
    ///
    /// Not `Button().keyboardShortcut().hidden()`: a hidden button is out of the
    /// responder chain, so those shortcuts silently never fire.
    private func handle(keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.modifiers.contains(.command) {
            return handleCommand(keyPress)
        }
        if let offset = Self.moveOffset(for: keyPress.key) {
            model.moveSelection(by: offset)
            return .handled
        }
        switch keyPress.key {
        case .escape:
            model.dismiss()
        case .home:
            model.selectFirst()
        case .end:
            model.selectLast()
        case .return:
            model.chooseSelection()
        default:
            return .ignored
        }
        return .handled
    }

    /// Rows to move for a navigation key, or nil if it is not one.
    private static func moveOffset(for key: KeyEquivalent) -> Int? {
        switch key {
        case .upArrow: -1
        case .downArrow: 1
        case .pageUp: -pageJump
        case .pageDown: pageJump
        default: nil
        }
    }

    private func handleCommand(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .return {
            model.chooseSelection(style: keyPress.modifiers.contains(.shift) ? .plainText : .rich)
            return .handled
        }
        if keyPress.characters.lowercased() == "p" {
            model.togglePinSelection()
            return .handled
        }
        // ⌘1–⌘9 paste that row outright.
        guard let digit = Int(keyPress.characters), (1...9).contains(digit) else {
            return .ignored
        }
        model.chooseRow(at: digit - 1)
        return .handled
    }

    private var resultList: some View {
        // Read once for the whole list rather than once per row.
        let selectedID = model.selection?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PickerMetrics.rowSpacing) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        ClipRowView(
                            item: item,
                            index: index,
                            isSelected: selectedID == item.id,
                            thumbnail: model.thumbnail(for: item),
                            stackImages: model.stackImages(for: item)
                        )
                        .id(item.id)
                        .onTapGesture { model.onChoose?(item, .rich) }
                        .onHover { hovering in
                            if hovering { model.hoverSelect(item) }
                        }
                        .contextMenu {
                            RowContextMenu(model: model, item: item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, PickerMetrics.listVerticalPadding)
            }
            .defaultScrollAnchor(.top)
            // The offset, not `onScrollPhaseChange`: what makes hover wrong is
            // rows moving under the pointer, and the offset says that directly
            // for every input — trackpad, momentum, a legacy wheel with no
            // touch phase at all, and our own `scrollTo` below.
            .onScrollGeometryChange(for: CGPoint.self, of: \.contentOffset) { old, new in
                guard old != new else { return }
                model.noteScrolling()
            }
            .onChange(of: model.selection?.id) { _, newValue in
                // Keyboard only: scrolling on hover drags the list around under
                // the pointer. `anchor: nil` scrolls the least amount needed to
                // bring the row into view rather than recentring on every
                // arrow press.
                guard let newValue, model.selectionSource == .keyboard else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.15)) {
                    proxy.scrollTo(newValue)
                }
            }
        }
    }

    /// Glass samples the backdrop, so with Reduce Transparency on there is
    /// nothing meaningful to sample — fall back to an opaque window background.
    ///
    /// There is no `glassEffect(isEnabled:)` overload in the macOS 26 SDK, so
    /// the switch is on the surface rather than on the modifier.
    @ViewBuilder
    private var panelSurface: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        }
    }

}

private struct RowContextMenu: View {
    let model: PickerModel
    let item: ClipSummary

    var body: some View {
        Button(item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
        Button("Paste as Plain Text") { model.onChoose?(item, .plainText) }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item) }
    }
}
