import Testing

@_spi(Fixtures) @testable import PingFrontCore

@Suite("App key checksum")
struct KeyTests {
    @Test("CRC-32 matches the IEEE check value")
    func crcCheckValue() {
        #expect(KeyCheck.crc32("123456789") == 0xCBF4_3926)
    }

    @Test(
        "Published valid vectors pass",
        arguments: [
            ("pk_test_abcdefghijklmnopqrstuvvd", AppKey.Mode.test),
            ("pk_live_0123456789ABCDEFGHIJKLNy", AppKey.Mode.live),
        ])
    func valid(key: String, mode: AppKey.Mode) throws {
        let parsed = try AppKey.parse(key).get()
        #expect(parsed.mode == mode)
        #expect(parsed.rawValue == key)
        #expect(!parsed.description.contains(String(key.dropFirst(8).prefix(10))))
    }

    @Test(
        "Published invalid vectors fail with the exact problem",
        arguments: [
            ("pk_test_abcdefghijklmnopqrstuwvd", KeyProblem.checksumMismatch),
            ("pk_live_0123456789ABCDEFGHIJKLNz", .checksumMismatch),
            ("pk_live_0123456789ABCDEFGHIJKLN", .wrongLength),
            // A secret key pasted by mistake. Spelled in two parts so secret scanners don't take the test vector for a key.
            ("sk" + "_live_0123456789ABCDEFGHIJKLNy", .wrongPrefix),
            ("", .empty),
            (" pk_live_0123456789ABCDEFGHIJKLNy", .whitespace),
            ("pk_live_0123456789ABCDEFGHIJKLNy\n", .whitespace),
            ("pk_prod_0123456789ABCDEFGHIJKLNy", .wrongPrefix),
            ("pk_live_0123456789ABCDEFGHIJK-Ny", .badCharacters),
        ])
    func invalid(key: String, problem: KeyProblem) {
        #expect(AppKey.parse(key) == .failure(KeyCheckError(problem: problem)))
    }

    @Test("Every problem has an actionable message")
    func messages() {
        for problem in KeyProblem.allCases {
            #expect(!problem.message.isEmpty)
            #expect(problem.message.hasSuffix("."))
        }
    }
}
