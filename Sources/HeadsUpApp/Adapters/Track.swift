import Observation

/// Calls `apply` with `read()` now, and again each time something `read` reads changes.
/// For pushing store state into AppKit objects that SwiftUI doesn't drive.
@MainActor
func track<Value>(_ read: @escaping @MainActor () -> Value, apply: @escaping @MainActor (Value) -> Void) {
    let value = withObservationTracking {
        read()
    } onChange: {
        // onChange runs before the change is stored: read again on the next main-queue turn.
        Task { @MainActor in track(read, apply: apply) }
    }
    apply(value)
}
