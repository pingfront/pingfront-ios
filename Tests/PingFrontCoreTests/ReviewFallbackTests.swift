import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

/// Review cards without a store URL fall back to the App Store id from the remote config.
@Suite("Review card fallback")
struct ReviewFallbackTests {
    @Test("the App Store id becomes the write-a-review page; anything but digits is refused")
    func appStoreID() {
        #expect(
            ReviewLink.writeReview(appStoreID: "6450012345")?.absoluteString
                == "itms-apps://apps.apple.com/app/id6450012345?action=write-review")
        #expect(ReviewLink.writeReview(appStoreID: "id6450012345") == nil)
        #expect(ReviewLink.writeReview(appStoreID: "") == nil)
    }

    @Test("AppConfig decodes appStoreId, drops a malformed one, and still decodes without it")
    func decodesAppStoreID() throws {
        let base =
            #"{"schema":1,"revision":1,"draft":false,"appName":"Clockwise","look":{},"team":[],"features":{"photos":true,"reports":true,"translation":false,"ai":false},"liveUrl":"wss://api.test/v1/live""#
        let decode = { (extra: String) throws -> AppConfig in
            try JSONDecoder().decode(AppConfig.self, from: Data((base + extra + "}").utf8))
        }
        #expect(try decode(#","appStoreId":"6450012345""#).appStoreId == "6450012345")
        #expect(try decode(#","appStoreId":"6450/../x""#).appStoreId == nil)
        #expect(try decode("").appStoreId == nil)
    }
}
