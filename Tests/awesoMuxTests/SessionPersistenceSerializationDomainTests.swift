import Foundation
import Testing

@Suite("SessionPersistence shared-state serialization", .serialized)
struct SessionPersistenceSerializationDomainTests {
    @Test("every temporary support-directory caller uses this serialized parent")
    func temporarySupportDirectoryCallersShareSerializationDomain() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let helperCall = "SessionPersistence." + "withTemporarySupportDirectory"
        let enumerator = try #require(
            FileManager.default.enumerator(at: testDirectory, includingPropertiesForKeys: nil)
        )
        let sourceFiles =
            enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        let callers = try sourceFiles.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains(helperCall)
        }
        #expect(!callers.isEmpty)
        let extensionMarker = "extension SessionPersistenceSerializationDomainTests"
        for caller in callers {
            let source = try String(contentsOf: caller, encoding: .utf8)
            guard let extRange = source.range(of: extensionMarker),
                  let callRange = source.range(of: helperCall)
            else {
                #expect(Bool(false), "file \(caller.lastPathComponent) must declare \(extensionMarker) before calling \(helperCall)")
                continue
            }
            #expect(callRange.lowerBound > extRange.lowerBound, "\(caller.lastPathComponent): helper call must appear inside the serialized extension, not before it")
        }
    }
}
