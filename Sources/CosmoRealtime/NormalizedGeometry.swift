import Foundation

/// A normalized point in `[0,1]`, **top-left origin** (y increases downward) —
/// the same convention as ``NormalizedBox`` and the on-device Vision tools.
public struct NormalizedPoint: Sendable, Equatable {
    /// Horizontal position, `0` at the left edge and `1` at the right.
    public var x: Double
    /// Vertical position, `0` at the top edge and `1` at the bottom.
    public var y: Double

    /// A point at the given normalized coordinates.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
