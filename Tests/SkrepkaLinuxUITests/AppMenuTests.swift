import Testing

@testable import SkrepkaLinuxUI

/// The tray menu: the macOS menu's items, in its order, and which does what.
@Suite("App: tray menu")
struct AppMenuTests {
    private func labels(_ menu: TrayMenu) -> [String] {
        menu.items.filter { $0.visible && !$0.separator }.map(\.label)
    }

    @Test("a healthy menu is the macOS one, without a problem row")
    func healthyMenu() {
        #expect(
            labels(AppMenu.menu(problem: nil))
                == ["Open Skrepka", "Clear History…", "Settings…", "Quit Skrepka"])
    }

    @Test("a problem heads the menu, with its own separator")
    func problemRow() {
        let menu = AppMenu.menu(problem: "Skrepka's background service isn't running")
        #expect(labels(menu).first == "Skrepka's background service isn't running")
        #expect(menu.items[1].separator && menu.items[1].visible)
    }

    /// Hidden rather than removed, so the menu keeps its shape — and its IDs —
    /// whether or not something is wrong.
    @Test("the problem row is always there, only hidden")
    func problemRowKeepsItsPlace() {
        let healthy = AppMenu.menu(problem: nil)
        let troubled = AppMenu.menu(problem: "x")
        #expect(healthy.items.map(\.id) == troubled.items.map(\.id))
        #expect(!healthy.items[0].visible && !healthy.items[1].visible)
    }

    @Test("every item's ID leads back to its action", arguments: AppMenu.Action.allCases)
    func idsRoundTrip(action: AppMenu.Action) {
        #expect(AppMenu.action(for: TrayMenu.ItemID(rawValue: action.rawValue)) == action)
    }

    @Test("separators and the root are not actions")
    func separatorsAreNotActions() {
        let menu = AppMenu.menu(problem: nil)
        for item in menu.items where item.separator {
            #expect(AppMenu.action(for: item.id) == nil)
        }
        #expect(AppMenu.action(for: TrayMenu.ItemID(rawValue: 0)) == nil)
    }

    @Test("IDs are unique")
    func uniqueIDs() {
        let ids = AppMenu.menu(problem: "x").items.map(\.id.rawValue)
        #expect(Set(ids).count == ids.count)
    }
}
