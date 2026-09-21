/// A fixed-capacity least-recently-used map.
///
/// The picker keeps decoded thumbnail textures here, one per content hash, and
/// evicts the coldest when it fills — a history of thousands must not pin
/// thousands of pictures in memory. Kept generic and free of GTK so the
/// eviction order can be tested with plain values; ``ThumbnailCache`` stores
/// `GdkTexture` pointers in one and unrefs whatever ``insert(_:_:)`` replaces
/// or evicts.
///
/// "Used" means inserted or taken: both move a key to the most-recent end, so
/// a texture drawn every time the list refreshes is the last to be dropped.
struct LRUCache<Value> {
    let capacity: Int
    private var storage: [String: Value] = [:]
    /// Keys least-recently-used first, most-recently-used last.
    private var order: [String] = []

    /// - Parameter capacity: clamped to at least one, since a cache that holds
    ///   nothing is a bug rather than a configuration.
    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    /// The keys, least-recently-used first — for tests and nothing else.
    var keysByAge: [String] { order }

    func contains(_ key: String) -> Bool { storage[key] != nil }

    /// The value for `key`, marking it most-recently-used.
    mutating func take(_ key: String) -> Value? {
        guard let value = storage[key] else { return nil }
        promote(key)
        return value
    }

    /// Stores `value` for `key` and returns values no longer held by the cache:
    /// the replaced value, then any eviction. The array is empty when none were
    /// displaced.
    mutating func insert(_ key: String, _ value: Value) -> [Value] {
        var displaced = storage[key].map { [$0] } ?? []
        storage[key] = value
        promote(key)
        guard storage.count > capacity, let coldest = order.first else { return displaced }
        order.removeFirst()
        if let evicted = storage.removeValue(forKey: coldest) { displaced.append(evicted) }
        return displaced
    }

    private mutating func promote(_ key: String) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}
