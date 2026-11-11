import CryptoKit
package import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A JPEG ready to upload: at most 2 MB and 2400 px on the long edge.
package struct PreparedImage: Sendable, Equatable {
    package var data: Data
    package var width: Int
    package var height: Int
    package var sha256: String
}

package enum ImagePreparation {
    /// Re-encodes any ImageIO-readable image (JPEG, PNG, HEIC, …) as an upright JPEG within the limits.
    ///
    /// Runs off the caller's actor: decoding, scaling, encoding and hashing are CPU work.
    @concurrent package static func prepare(_ input: sending Data, maxEdge: Int = Limits.imageMaxEdge, maxBytes: Int = Limits.imageBytes)
        async throws(PingFrontError) -> PreparedImage
    {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw .invalidInput("This file is not an image.") }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? maxEdge
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? maxEdge
        var edge = min(maxEdge, max(width, height))
        // Small images are fine as they are; large ones step down until they fit the byte limit.
        while edge >= 1 {
            try Task.checkCancellation(or: PingFrontError.cancelled)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw .invalidInput("This image could not be read.")
            }
            for quality in [0.85, 0.72, 0.6, 0.48] {
                if let data = encodeJPEG(image, quality: quality), data.count <= maxBytes {
                    return PreparedImage(data: data, width: image.width, height: image.height, sha256: sha256(data))
                }
            }
            if edge <= 160 { break }
            edge = edge * 3 / 4
        }
        throw .invalidInput("This image is too large to send.")
    }

    package static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension Task where Success == Never, Failure == Never {
    /// Throws `error` when the current task is cancelled (typed-throws friendly).
    package static func checkCancellation<E: Error>(or error: E) throws(E) {
        if Task.isCancelled { throw error }
    }
}
