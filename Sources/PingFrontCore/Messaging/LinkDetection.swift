package import Foundation

/// Web links in message text, detected on this device.
///
/// Nothing about them is sent anywhere.
package enum LinkDetection {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The http(s) links in `text` with their ranges, in order.
    package static func links(in text: String) -> [(url: URL, range: Range<String.Index>)] {
        guard let detector else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                let range = Range(match.range, in: text)
            else { return nil }
            return (url, range)
        }
    }

    /// The URL when the whole message is a single link (it gets a preview card).
    package static func soleLink(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = links(in: trimmed)
        guard found.count == 1, let only = found.first, only.range == trimmed.startIndex..<trimmed.endIndex else { return nil }
        return only.url
    }
}

/// The photo viewer's gesture rules.
package enum PhotoZoom {
    /// Zoom stays between fitting the screen and 5x.
    package static func clamped(_ scale: Double) -> Double { min(max(scale, 1), 5) }

    /// Swiping down closes the viewer when the photo is not zoomed and the swipe is long or fast enough.
    package static func dismisses(scale: Double, translation: Double, predicted: Double) -> Bool {
        scale <= 1 && (translation > 120 || predicted > 400)
    }
}
