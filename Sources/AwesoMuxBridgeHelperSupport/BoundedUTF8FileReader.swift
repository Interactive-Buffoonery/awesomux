import Foundation

/// Small bounded UTF-8 file reader for helper/test fixtures.
///
/// Production bridge paths use descriptor-safe readers elsewhere; `--emit`
/// previously called `String(contentsOfFile:)`, which could allocate an
/// arbitrary fixture into memory. Keep the helper's model aligned with bounded
/// production reads.
public enum BoundedUTF8FileReader {
    public enum ReadError: Error, Equatable, Sendable {
        case unreadable
        case tooLarge
        case invalidUTF8
    }

    /// Cap for `--emit` JSONL fixtures. Large enough for realistic multi-event
    /// smoke files; small enough that an accidental huge path cannot inflate
    /// helper memory.
    public static let emitFixtureMaximumBytes = 1_048_576

    public static func read(
        path: String,
        maximumBytes: Int = emitFixtureMaximumBytes
    ) throws -> String {
        guard maximumBytes >= 0 else { throw ReadError.unreadable }
        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ReadError.unreadable
        }
        defer { try? handle.close() }

        var data = Data()
        let chunkSize = 64 * 1024
        while true {
            let remainingBudget = maximumBytes + 1 - data.count
            if remainingBudget <= 0 {
                throw ReadError.tooLarge
            }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(chunkSize, remainingBudget)) ?? Data()
            } catch {
                throw ReadError.unreadable
            }
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maximumBytes {
                throw ReadError.tooLarge
            }
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw ReadError.invalidUTF8
        }
        return string
    }
}
