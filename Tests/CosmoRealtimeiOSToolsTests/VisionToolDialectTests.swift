import Foundation
import Testing

@testable import CosmoRealtime
@testable import CosmoRealtimeiOSTools

@Suite("vision tool schema dialect")
struct VisionToolDialectTests {
    @Test("every registered tool's schema is legal in the backend dialect")
    func registrySchemasAreDialectLegal() {
        // A schema key outside the backend allowlist makes the declaration get
        // dropped — the model never sees the tool. Pin every registered tool.
        for tool in VisionToolRegistry.all {
            let violation = ClientToolSchemaDialect.firstViolation(inSchemaJSON: tool.parametersJSON)
            #expect(violation == nil, "\(tool.name): \(violation ?? "")")
        }
    }
}
