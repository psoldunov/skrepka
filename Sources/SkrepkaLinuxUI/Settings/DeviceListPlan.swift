/// How the device list turns the rows it shows into the rows it should show,
/// touching as few of them as it can.
///
/// A rebuilt row loses keyboard focus — GTK takes focus from any widget it
/// removes — and the control that matters most is the one the person just
/// used: a live-clipboard switch they flipped, a row they tabbed to. So a
/// device that stays in the list as the same kind of row keeps its widgets and
/// is updated in place, and only a device that arrives, leaves or changes kind
/// — paired, or merely in sight — is inserted or removed. Rows that stay but
/// change places, which a rename can cause, are rebuilt with everything else:
/// a list box moves a row only by removing it.
struct DeviceListPlan: Equatable {
    /// One row, as far as keeping it goes: its device, and whether it is the
    /// paired kind — Unpair and a switch — or the nearby kind, with Pair….
    struct Key: Hashable {
        let id: String
        let isPaired: Bool
    }

    /// A row to put in, at its index in the list as it should end up.
    struct Insertion: Equatable {
        let index: Int
        let key: Key
    }

    /// Rows to take out, in the order they are shown.
    let removals: [Key]
    /// Rows to put in, by increasing index. Inserting each at its index, after
    /// the removals, leaves the list in the wanted order.
    let insertions: [Insertion]

    /// The plan from `shown` to `wanted`, each in display order.
    static func between(shown: [Key], wanted: [Key]) -> DeviceListPlan {
        let wantedKeys = Set(wanted)
        let staying = shown.filter(wantedKeys.contains)
        let stayingKeys = Set(staying)
        guard staying == wanted.filter(stayingKeys.contains) else {
            return DeviceListPlan(removals: shown, insertions: insertions(of: wanted) { _ in true })
        }
        return DeviceListPlan(
            removals: shown.filter { !wantedKeys.contains($0) },
            insertions: insertions(of: wanted) { !stayingKeys.contains($0) }
        )
    }

    private static func insertions(of wanted: [Key], where included: (Key) -> Bool) -> [Insertion] {
        wanted.enumerated()
            .filter { included($0.element) }
            .map { Insertion(index: $0.offset, key: $0.element) }
    }
}
