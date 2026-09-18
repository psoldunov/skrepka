import Testing

@testable import SkrepkaLinuxUI

/// Which device rows are kept, and which are put in or taken out.
///
/// Every row this touches loses keyboard focus when GTK removes it, so the
/// property worth holding is how little it touches.
@Suite("Settings: keeping device rows")
struct DeviceListPlanTests {
    typealias Key = DeviceListPlan.Key
    typealias Insertion = DeviceListPlan.Insertion

    static let mac = Key(id: "mac", isPaired: true)
    static let deck = Key(id: "deck", isPaired: false)
    static let laptop = Key(id: "laptop", isPaired: false)

    @Test("the same rows in the same order are all kept")
    func unchanged() {
        let plan = DeviceListPlan.between(shown: [Self.mac, Self.deck], wanted: [Self.mac, Self.deck])
        #expect(plan.removals.isEmpty)
        #expect(plan.insertions.isEmpty)
    }

    @Test("a device that arrives is put in where it belongs, and nothing else moves")
    func arrival() {
        let plan = DeviceListPlan.between(
            shown: [Self.mac, Self.laptop], wanted: [Self.mac, Self.deck, Self.laptop])
        #expect(plan.removals.isEmpty)
        #expect(plan.insertions == [Insertion(index: 1, key: Self.deck)])
    }

    @Test("a device that leaves is taken out, and nothing else moves")
    func departure() {
        let plan = DeviceListPlan.between(
            shown: [Self.mac, Self.deck, Self.laptop], wanted: [Self.mac, Self.laptop])
        #expect(plan.removals == [Self.deck])
        #expect(plan.insertions.isEmpty)
    }

    /// Pair… and Unpair are different rows — one has a switch — so pairing a
    /// device replaces its row, in the same place.
    @Test("a device that becomes paired gets the paired kind of row, in its place")
    func kindChange() {
        let paired = Key(id: "deck", isPaired: true)
        let plan = DeviceListPlan.between(shown: [Self.mac, Self.deck], wanted: [Self.mac, paired])
        #expect(plan.removals == [Self.deck])
        #expect(plan.insertions == [Insertion(index: 1, key: paired)])
    }

    @Test("rows that stay but change places are all put back, in the new order")
    func reorder() {
        let plan = DeviceListPlan.between(shown: [Self.deck, Self.laptop], wanted: [Self.laptop, Self.deck])
        #expect(plan.removals == [Self.deck, Self.laptop])
        #expect(
            plan.insertions == [Insertion(index: 0, key: Self.laptop), Insertion(index: 1, key: Self.deck)])
    }

    @Test("the first list is every row, inserted in order")
    func fromNothing() {
        let plan = DeviceListPlan.between(shown: [], wanted: [Self.mac, Self.deck])
        #expect(plan.removals.isEmpty)
        #expect(plan.insertions == [Insertion(index: 0, key: Self.mac), Insertion(index: 1, key: Self.deck)])
    }
}
