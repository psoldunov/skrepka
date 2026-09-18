/// A new model, and the actions it asks to be sent because of the event.
public struct SyncTransition: Sendable, Hashable {
    public let model: SyncModel
    /// Each goes through ``SyncModel/sending(_:)`` before the daemon sees it,
    /// exactly like an action the user took.
    public let effects: [SyncAction]

    public init(model: SyncModel, effects: [SyncAction] = []) {
        self.model = model
        self.effects = effects
    }
}
