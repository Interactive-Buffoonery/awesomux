import Testing
@testable import AwesoMuxCore

@Suite("SourceOffsetMapper")
struct SourceOffsetMapperTests {
    @Test(
        arguments: [
            ("abc\ndef", 1, 1, 0), ("abc\ndef", 1, 3, 2), ("abc\ndef", 2, 1, 4),
            ("é!\nx", 1, 3, 2), ("é!\nx", 2, 1, 4),
            ("abc", 9, 1, nil), ("abc", 1, 99, nil), ("abc\ndef", 1, 5, nil),
        ] as [(String, Int, Int, Int?)])
    func sourceOffsets(source: String, line: Int, column: Int, expected: Int?) {
        #expect(SourceOffsetMapper(source: source).utf8Offset(forLine: line, column: column) == expected)
    }

}
