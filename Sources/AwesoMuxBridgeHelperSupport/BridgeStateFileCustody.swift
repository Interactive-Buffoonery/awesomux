import AwesoMuxBridgeProtocol
import Darwin
import Foundation

/// The remote helper's fd-level custody check on the bridge state file,
/// mirroring `AmxStatusFileWatcher.armSource`'s discipline exactly: open by
/// path once with `O_NOFOLLOW`, validate the *descriptor* (never the path a
/// second time), and read only through that already-validated fd. This custody
/// discipline mirrors the local agent event-file contract.
///
/// Validating the descriptor rather than re-stat'ing the path closes the
/// TOCTOU window where a same-UID process swaps the file for a symlink
/// between an initial check and a later open — the same reasoning
/// `AgentRuntimeEventFile.truncate` documents for the local channel.
///
/// Every failure — non-absolute input path, missing file, symlink,
/// non-regular file (FIFO/device/directory), wrong owner, wrong mode,
/// oversized, malformed JSON, non-absolute or unsafe-scalar `socket`
/// field — degrades to `nil` silently. This type never throws and never
/// logs the file's contents: the contents are a live forgery token, and a
/// diagnostic log line is exactly the kind of side channel the custody
/// check exists to avoid.
public enum BridgeStateFileCustody {

    /// Reads and validates the bridge state file at `path`.
    ///
    /// - Parameters:
    ///   - path: The value of `AWESOMUX_BRIDGE_STATE`. The app always
    ///     injects the fully resolved absolute path (see the spec's env
    ///     table); helpers never expand `~`, so a non-absolute value here is
    ///     itself malformed input and is rejected before any `open(2)`.
    ///   - effectiveUID: Overridable for tests; defaults to the real
    ///     effective UID.
    public static func read(path: String, effectiveUID: uid_t = geteuid()) -> BridgeStateFile? {
        guard path.hasPrefix("/") else {
            return nil
        }

        // O_NONBLOCK: a no-op for regular files, but without it a FIFO
        // squatting the state-file path would block open(2) forever —
        // O_NOFOLLOW only guards the symlink case, and the S_IFREG check
        // below never runs if open never returns. With it, a FIFO opens
        // immediately and fstat rejects it like any other non-regular file.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == effectiveUID,
              // Exactly 0600 across ALL non-file-type mode bits — no
              // group/world access of any kind (a group-readable file could
              // leak the token to another local account on a shared host),
              // and no setuid/setgid/sticky either: masking only the rwx
              // triads would let an anomalous 04600 pass an "exactly 0600"
              // check.
              (st.st_mode & ~mode_t(S_IFMT)) == (S_IRUSR | S_IWUSR),
              st.st_size >= 0,
              st.st_size <= off_t(BridgeStateFile.maximumByteCount)
        else {
            return nil
        }

        guard let data = readAll(fd: fd, expectedSize: Int(st.st_size)) else {
            return nil
        }

        return BridgeStateFile.parse(data: data)
    }

    /// Reads exactly `expectedSize` bytes via `pread` off the already-
    /// validated descriptor. Never re-opens by path.
    private static func readAll(fd: Int32, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else {
            return Data()
        }

        var buffer = [UInt8](repeating: 0, count: expectedSize)
        var totalRead = 0
        while totalRead < expectedSize {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                pread(fd, rawBuffer.baseAddress!.advanced(by: totalRead), expectedSize - totalRead, off_t(totalRead))
            }

            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if bytesRead == 0 {
                // File shrank mid-read. The app's own writer atomically
                // replaces (temp + rename), so an in-place truncate is
                // off-contract; fail closed rather than hand the parser a
                // truncated buffer that might still be valid-looking JSON
                // the fstat'd file never actually contained.
                return nil
            }
            totalRead += bytesRead
        }

        return Data(buffer)
    }
}
