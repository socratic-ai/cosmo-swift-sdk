import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

import CosmoRealtimeARKit

@Suite struct ARFrameStillBridgeTests {

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        return buffer!
    }

    @Test("an upright orientation yields a CGImage of the same dimensions")
    func uprightKeepsDimensions() throws {
        let image = try #require(
            ARFrameStillBridge.uprightImage(from: Self.makePixelBuffer(width: 4, height: 2), applying: .up)
        )
        #expect(image.width == 4)
        #expect(image.height == 2)
    }

    @Test("a 90° orientation bakes the rotation in, swapping the dimensions")
    func quarterTurnSwapsDimensions() throws {
        let image = try #require(
            ARFrameStillBridge.uprightImage(from: Self.makePixelBuffer(width: 4, height: 2), applying: .right)
        )
        #expect(image.width == 2)
        #expect(image.height == 4)
    }
}
