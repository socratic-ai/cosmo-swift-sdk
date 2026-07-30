import Foundation

public struct Diagnostics: Sendable {
    public var droppedInputBlocks: Int = 0
    public var underrunBlocks: Int = 0
    public var routeChanges: Int = 0
    public var lastError: String?

    public init() {}
}
