import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

/// Runs the language-neutral protocol fixtures (`TestPaths.protocolFixtures`, the same cases the server and the
/// other SDKs run) against the SDK's models, so iOS drift fails CI.
@Suite("Protocol fixtures")
struct ConformanceTests {
    static let root = TestPaths.protocolFixtures

    struct Case: Sendable, CustomTestStringConvertible {
        let file: String
        let name: String
        let value: Data
        var testDescription: String { "\(file): \(name)" }
    }

    /// Schemas the SDK decodes (it only encodes the request schemas).
    static let decoded: [String: @Sendable (Data) throws -> Void] = [
        "sdk/CreateSessionResponse.json": { _ = try WireJSON.decode(CreateSessionResponse.self, from: $0) },
        "sdk/UpdateMeResponse.json": { _ = try WireJSON.decode(UpdateMeResponse.self, from: $0) },
        "sdk/ThreadResponse.json": { _ = try WireJSON.decode(ThreadResponse.self, from: $0) },
        "sdk/ListenedMomentsResponse.json": { _ = try WireJSON.decode(ListenedMomentsResponse.self, from: $0) },
        "sdk/AppConfig.json": { _ = try WireJSON.decode(AppConfig.self, from: $0) },
        "sdk/Message.json": { _ = try WireJSON.decode(Message.self, from: $0) },
        "sdk/OfferSlot.json": { _ = try WireJSON.decode(OfferSlot.self, from: $0) },
        "sdk/StoreActionCard.json": { data in
            // Card decoding never throws (unknown kinds become .unknown), so check it really is a store action.
            guard case .storeAction = try WireJSON.decode(Card.self, from: data) else { throw CocoaError(.coderReadCorrupt) }
        },
        "sdk/Entitlement.json": { _ = try WireJSON.decode(Entitlement.self, from: $0) },
        "sdk/PersonSummary.json": { _ = try WireJSON.decode(PersonSummary.self, from: $0) },
        "sdk/TeamActionPayload.json": { _ = try WireJSON.decode(TeamActionPayload.self, from: $0) },
        "sdk/OfferSignatureResponse.json": { _ = try WireJSON.decode(PromotionalOfferSignature.self, from: $0) },
        "sdk/StoreActionResultResponse.json": { _ = try WireJSON.decode(StoreActionResultResponse.self, from: $0) },
        "sdk/DeviceContext.json": { data in
            // The SDK encodes context; a valid fixture must also survive the round trip unchanged.
            let context = try WireJSON.decode(DeviceContext.self, from: data)
            let again = try WireJSON.decode(DeviceContext.self, from: WireJSON.encode(context))
            guard again == context else { throw CocoaError(.coderReadCorrupt) }
        },
        "sdk/ContextCollection.json": { _ = try WireJSON.decode(ContextCollection.self, from: $0) },
        "sdk/PersonExport.json": { data in
            // exportMyData() hands the bytes over as they are; the thread's messages must still read as Messages.
            for message in try ConformanceTests.exportMessages(data) { _ = try WireJSON.decode(Message.self, from: message) }
        },
        "look/ChatLook.json": { _ = try WireJSON.decode(ChatLook.self, from: $0) },
        "live/ServerEvent.json": { _ = try ServerEvent.decode($0) },
        "errors/ErrorBody.json": { _ = try WireJSON.decode(ErrorEnvelope.self, from: $0) },
        "push/ApnsPayload.json": { data in
            let object = try JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] ?? [:]
            guard PushPayload(userInfo: object) != nil else { throw CocoaError(.coderReadCorrupt) }
        },
    ]

    static var cases: [Case] {
        decoded.keys.sorted().flatMap { file -> [Case] in
            guard let data = try? Data(contentsOf: root.appending(path: file)),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let valid = json["valid"] as? [[String: Any]]
            else { return [Case(file: file, name: "fixture file is missing", value: Data())] }
            return valid.compactMap { item in
                guard let name = item["name"] as? String, let value = item["value"],
                    let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                else { return nil }
                return Case(file: file, name: name, value: bytes)
            }
        }
    }

    /// The messages of a `PersonExport` fixture value (`person.thread.messages`), each as JSON.
    static func exportMessages(_ data: Data) throws -> [Data] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let person = object?["person"] as? [String: Any]
        let messages = (person?["thread"] as? [String: Any])?["messages"] as? [Any] ?? []
        return try messages.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    @Test("A photo removed by retention decodes as removed, with no url to fetch (PersonExport fixture)")
    func removedImagePart() throws {
        let images = try Self.cases.filter { $0.file == "sdk/PersonExport.json" }.flatMap { try Self.exportMessages($0.value) }
            .flatMap { try WireJSON.decode(Message.self, from: $0).parts }
            .compactMap { part -> ImagePart? in
                if case .image(let image) = part { return image }
                return nil
            }
        let removed = images.filter(\.removed)
        #expect(!removed.isEmpty, "the PersonExport fixture carries a removed image part")
        for image in removed {
            #expect(image.url == nil)
            #expect(image.attachmentId == "att_1")
        }
        // A removed part keeps the flag through the thread cache (encode, then decode).
        let again = try WireJSON.decode(ImagePart.self, from: WireJSON.encode(try #require(removed.first)))
        #expect(again.removed && again.url == nil)
        // Present photos stay as they were.
        let present = try WireJSON.decode(
            ImagePart.self, from: Data(#"{"type":"image","attachmentId":"a","width":1,"height":1,"url":"https://f.test/a"}"#.utf8))
        #expect(!present.removed && present.url != nil)
        // A url next to removed: true is dropped, so nothing tries to fetch it.
        let both = try WireJSON.decode(
            ImagePart.self, from: Data(#"{"attachmentId":"a","width":1,"height":1,"url":"https://f.test/a","removed":true}"#.utf8))
        #expect(both.removed && both.url == nil)
    }

    @Test("Every valid fixture decodes", arguments: cases)
    func validDecodes(_ fixture: Case) throws {
        let decode = try #require(Self.decoded[fixture.file])
        #expect(throws: Never.self) { try decode(fixture.value) }
    }

    @Test("Key fixtures: crc32, check characters, valid and invalid keys")
    func keys() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "keys.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for item in json["crc32"] as? [[String: Any]] ?? [] {
            let input = try #require(item["input"] as? String)
            #expect(Int(KeyCheck.crc32(input)) == (item["expected"] as? Int))
        }
        for item in json["checkChars"] as? [[String: Any]] ?? [] {
            let input = try #require(item["input"] as? String)
            #expect(KeyCheck.checkChars(input) == item["expected"] as? String)
        }
        for item in json["valid"] as? [[String: Any]] ?? [] where item["kind"] as? String == "pk" {
            let key = try #require(item["key"] as? String)
            let parsed = try AppKey.parse(key).get()
            #expect(parsed.mode.rawValue == item["mode"] as? String, "\(key)")
        }
        for item in json["invalid"] as? [[String: Any]] ?? [] where item["kind"] as? String == "pk" {
            let key = try #require(item["key"] as? String)
            guard case .failure(let error) = AppKey.parse(key) else {
                Issue.record("\(item["name"] ?? key) was accepted")
                continue
            }
            #expect(error.problem.rawValue == item["problem"] as? String, "\(item["name"] ?? key)")
        }
    }
}
