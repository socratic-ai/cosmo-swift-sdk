import Foundation
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct VisionToolTests {
    /// Raw values are the wire-protocol tool names the backend ships in
    /// `tool-invocation` events; a rename is a wire break, so pin them.
    @Test("wire names are stable")
    func wireNames() {
        #expect(FaceLandmarksTool.name == "detect_face_landmarks")
    }

    @Test("every registered tool has a backend-legal name")
    func legalNames() {
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from
        // client_declared.py — a declaration with an illegal name is rejected.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        for tool in VisionToolRegistry.all {
            #expect(tool.name.wholeMatch(of: pattern) != nil)
        }
    }

    @Test("registered tool names are unique")
    func uniqueNames() {
        let names = VisionToolRegistry.all.map { $0.name }
        #expect(Set(names).count == names.count)
    }

    @Test("every registered tool vends a declaration matching its identity")
    func declarationsMatchIdentity() throws {
        for tool in VisionToolRegistry.all {
            let declared = tool.declaredTool()
            #expect(declared.name == tool.name)
            #expect(declared.description == tool.toolDescription)
            // The advertised args schema must be a wire-legal object.
            let schema = try JSONSerialization.jsonObject(
                with: Data(declared.parametersJSON.utf8)
            ) as? [String: Any]
            #expect(schema?["type"] as? String == "object")
        }
    }

    @Test("declaredTools advertises exactly the supported tools")
    func declaredToolsAreSupportedOnly() {
        let advertised = Set(VisionToolRegistry.declaredTools().map { $0.name })
        let supported = Set(VisionToolRegistry.all.filter { $0.isSupported }.map { $0.name })
        #expect(advertised == supported)
    }
}
