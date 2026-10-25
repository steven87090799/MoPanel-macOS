/// A UI-owned cache, without timers or publishers. While an interaction is in
/// progress it reuses the last prepared value. Once idle, the caller's current
/// key prepares only the newest value; intermediate readings remain in the
/// collector rather than creating a queue of drawing work.
public final class DeferredRenderCache<Key: Equatable, Value> {
    private var key: Key?
    private var cached: Value?
    public private(set) var buildCount = 0
    public init() {}

    public func value(for key: Key, canUpdate: Bool, build: () -> Value) -> Value {
        if let cached, !canUpdate || self.key == key { return cached }
        let value = build()
        self.key = key
        cached = value
        buildCount += 1
        return value
    }
}
