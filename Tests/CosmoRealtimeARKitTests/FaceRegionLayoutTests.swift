import Foundation
import Testing
import simd

@testable import CosmoRealtimeARKit

@Suite struct FaceRegionLayoutTests {
    // Eyes at y = 0, left on the -x side, right on +x, a little toward the camera.
    private static let leftEye = SIMD3<Float>(-0.032, 0, 0.06)
    private static let rightEye = SIMD3<Float>(0.032, 0, 0.06)

    @Test("forehead sits above the eyes and the cheeks below")
    func verticalPlacement() throws {
        let regions = FaceRegionLayout.regionVertices(leftEye: Self.leftEye, rightEye: Self.rightEye)
        #expect(try Self.meanY(regions[FaceRegionLayout.forehead]) > 0)    // above eye level
        #expect(try Self.meanY(regions[FaceRegionLayout.leftCheek]) < 0)   // below eye level
        #expect(try Self.meanY(regions[FaceRegionLayout.rightCheek]) < 0)
    }

    @Test("each cheek follows its own eye's side")
    func horizontalPlacement() throws {
        let regions = FaceRegionLayout.regionVertices(leftEye: Self.leftEye, rightEye: Self.rightEye)
        let leftCheekX = try Self.meanX(regions[FaceRegionLayout.leftCheek])
        let rightCheekX = try Self.meanX(regions[FaceRegionLayout.rightCheek])
        #expect(leftCheekX < 0)
        #expect(rightCheekX > 0)
        #expect(leftCheekX < rightCheekX)
    }

    @Test("each region is a four-corner quad")
    func quadShape() throws {
        let regions = FaceRegionLayout.regionVertices(leftEye: Self.leftEye, rightEye: Self.rightEye)
        for key in [FaceRegionLayout.forehead, FaceRegionLayout.leftCheek, FaceRegionLayout.rightCheek] {
            #expect(try #require(regions[key]).count == 4)
        }
    }

    private static func meanY(_ points: [SIMD3<Float>]?) throws -> Float {
        let points = try #require(points)
        return points.map(\.y).reduce(0, +) / Float(points.count)
    }

    private static func meanX(_ points: [SIMD3<Float>]?) throws -> Float {
        let points = try #require(points)
        return points.map(\.x).reduce(0, +) / Float(points.count)
    }
}
