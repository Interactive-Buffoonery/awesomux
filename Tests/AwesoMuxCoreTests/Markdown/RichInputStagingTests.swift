import Testing
@testable import AwesoMuxCore

@Suite("RichInputStaging")
struct RichInputStagingTests {
    @Test(arguments: [
        ("safe\u{1B}[201~rm -rf ~", "safe[201~rm -rf ~"),
        ("a\u{1B}b\u{07}c\u{00}d\ne", "abcd\ne"),
        ("\u{1B}\u{00}\u{07}", ""),
        ("run\u{202E}elif.txt", "runelif.txt"),
        ("a\u{2066}b\u{2069}c", "abc"),
    ])
    func stagedPayload(input: String, expected: String) {
        #expect(RichInputStaging.stagedPayload(input) == expected)
    }

}
