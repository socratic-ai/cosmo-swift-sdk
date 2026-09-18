import CoreGraphics
import Foundation
import Testing
@testable import CosmoRealtime

@Suite struct ScreenCaptureCacheTests {
    private func capture(appPID: pid_t? = 123) -> ScreenCapture {
        ScreenCapture(
            imageJPEG: Data([0xff, 0xd8]),
            elements: [
                ScreenElement(
                    index: 0, role: "AXButton", title: "OK", label: nil, value: nil,
                    frame: CGRect(x: 10, y: 20, width: 100, height: 30)
                )
            ],
            context: appPID
        )
    }

    @Test func returnsCurrentCaptureForMatchingId() {
        let cache = ScreenCaptureCache()
        cache.put("cap-1", capture())
        let found = cache.get("cap-1")
        #expect(found?.elements.first?.frame.midX == 60)
        #expect(found?.context as? pid_t == 123)
    }

    @Test func missesOnWrongId() {
        let cache = ScreenCaptureCache()
        cache.put("cap-1", capture())
        #expect(cache.get("cap-other") == nil)
    }

    @Test func expiresAfterMaxAge() {
        let cache = ScreenCaptureCache()
        let created = Date()
        cache.put("cap-1", capture(), now: created)
        let justInside = created.addingTimeInterval(ScreenCaptureCache.maxAge - 1)
        let justOutside = created.addingTimeInterval(ScreenCaptureCache.maxAge + 1)
        #expect(cache.get("cap-1", now: justInside) != nil)
        #expect(cache.get("cap-1", now: justOutside) == nil)
    }

    @Test func concurrentDistinctCapturesCoexist() {
        let cache = ScreenCaptureCache()
        cache.put("cap-1", capture())
        cache.put("cap-2", capture())
        #expect(cache.get("cap-1") != nil)
        #expect(cache.get("cap-2") != nil)
    }

    @Test func evictsOldestBeyondCap() {
        let cache = ScreenCaptureCache()
        let base = Date()
        for i in 0...ScreenCaptureCache.maxEntries {
            cache.put("cap-\(i)", capture(), now: base.addingTimeInterval(Double(i)))
        }
        #expect(cache.get("cap-0", now: base) == nil)
        for i in 1...ScreenCaptureCache.maxEntries {
            #expect(cache.get("cap-\(i)", now: base) != nil)
        }
    }

    @Test func exactlyAtMaxAgeIsExpired() {
        // The boundary is exclusive, matching the Python and TypeScript caches:
        // a handle exactly maxAge old no longer resolves.
        let cache = ScreenCaptureCache()
        let base = Date(timeIntervalSince1970: 1_000)
        cache.put("cap-1", capture(), now: base)
        #expect(cache.get("cap-1", now: base.addingTimeInterval(ScreenCaptureCache.maxAge)) == nil)
        #expect(cache.get("cap-1", now: base.addingTimeInterval(ScreenCaptureCache.maxAge - 0.001)) != nil)
    }
}
