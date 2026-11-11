#if canImport(UIKit)
    import UIKit
    import XCTest
    @testable import PingFrontUI

    /// The composer's camera path without a camera (the simulator has none).
    ///
    /// When the + menu offers it, what the picker hands back, and the staging of that photo. Taking a real photo
    /// is checked on a device.
    @MainActor
    final class CameraPickerTests: XCTestCase {
        func testNotOfferedWithoutACameraOrAUsageDescription() {
            // The simulator has no camera, and this test host declares no NSCameraUsageDescription: either one
            // alone hides the item.
            XCTAssertFalse(UIImagePickerController.isSourceTypeAvailable(.camera))
            XCTAssertFalse(CameraPicker.isAvailable)
        }

        func testATakenPhotoIsHandedBackAsJPEGAndThePickerCloses() throws {
            var photos: [Data] = []
            var dismissed = 0
            let coordinator = CameraPicker.Coordinator(onPhoto: { photos.append($0) }, dismiss: { dismissed += 1 })
            let photo = Self.photo(CGSize(width: 400, height: 300))
            coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: photo])
            XCTAssertEqual(dismissed, 1)
            let data = try XCTUnwrap(photos.first)
            XCTAssertEqual(photos.count, 1)
            XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
            let decoded = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(decoded.size.width * decoded.scale, 400 * photo.scale, accuracy: 1)
        }

        func testCancellingOrNoImageStagesNothing() {
            var photos: [Data] = []
            var dismissed = 0
            let coordinator = CameraPicker.Coordinator(onPhoto: { photos.append($0) }, dismiss: { dismissed += 1 })
            coordinator.imagePickerControllerDidCancel(UIImagePickerController())
            coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [:])
            XCTAssertTrue(photos.isEmpty)
            XCTAssertEqual(dismissed, 2, "the camera closes either way")
        }

        /// A full-size camera photo stages as a small thumbnail (the composer keeps the bytes, not the decoded
        /// original).
        func testACameraSizedPhotoStagesAsAThumbnail() throws {
            var photos: [Data] = []
            let coordinator = CameraPicker.Coordinator(onPhoto: { photos.append($0) }, dismiss: {})
            let photo = Self.photo(CGSize(width: 4032, height: 3024), scale: 1)
            coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: photo])
            let data = try XCTUnwrap(photos.first)
            let thumbnail = try XCTUnwrap(ImageStore.downsample(data, maxPixelSize: 240))
            XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height) * thumbnail.scale, 240)
        }

        private static func photo(_ size: CGSize, scale: CGFloat = 2) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.systemOrange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
            }
        }
    }
#endif
