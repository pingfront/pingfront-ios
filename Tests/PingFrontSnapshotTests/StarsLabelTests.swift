#if canImport(UIKit)
    import XCTest
    @testable import PingFrontUI

    /// The rating card's star label agrees with the number its noun counts in each language.
    ///
    /// "%1$lld of %2$lld stars" reads the total in English and the rating in French, from the built catalog. Android
    /// and the web say the same.
    @MainActor
    final class StarsLabelTests: XCTestCase {
        private func labels(_ language: String, total: Int = 5, ratings: [Int] = [1, 2, 5]) -> [String] {
            let t = L10n(Locale(identifier: language))
            return ratings.map { t("%1$lld of %2$lld stars", $0, total) }
        }

        func testEnglishAgreesWithTheTotal() {
            XCTAssertEqual(labels("en"), ["1 of 5 stars", "2 of 5 stars", "5 of 5 stars"])
            XCTAssertEqual(labels("en", total: 1, ratings: [1]), ["1 of 1 star"])
        }

        func testFrenchAgreesWithTheRating() {
            XCTAssertEqual(labels("fr"), ["1 étoile sur 5", "2 étoiles sur 5", "5 étoiles sur 5"])
            XCTAssertEqual(labels("fr-CA"), ["1 étoile sur 5", "2 étoiles sur 5", "5 étoiles sur 5"])
        }

        func testArabicAgreesWithTheTotal() {
            XCTAssertEqual(labels("ar"), ["1 من 5 نجوم", "2 من 5 نجوم", "5 من 5 نجوم"])
            XCTAssertEqual(labels("ar", total: 2, ratings: [1]), ["1 من 2 نجمتين"])
        }

        func testRussianAndPolishReadAsAScore() {
            XCTAssertEqual(labels("ru"), ["Оценка: 1 из 5", "Оценка: 2 из 5", "Оценка: 5 из 5"])
            XCTAssertEqual(labels("pl"), ["Ocena: 1 z 5", "Ocena: 2 z 5", "Ocena: 5 z 5"])
        }
    }
#endif
