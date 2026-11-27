import SwiftUI
import Combine

/// Drop-in replacement for `@State`.
///
/// On the macOS 27 SDK `@State` is a compiler macro whose plugin ships only with full Xcode,
/// so a Command Line Tools build can't expand it. This wrapper stores the value in a
/// `@StateObject`, which gives the same per-view lifetime and change tracking.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}
