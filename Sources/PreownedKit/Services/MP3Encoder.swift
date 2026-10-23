import Foundation
import Synchronization

/// An external program that encodes MP3: LAME, or FFmpeg with libmp3lame.
///
/// macOS has no MP3 encoder,
/// so the speech service pipes 16-bit PCM to one of these programs.
/// The program writes to a temporary file, not to standard output,
/// because an encoder can write the LAME tag,
/// with the encoder delay and padding that let decoders trim the silence it adds,
/// only to an output that it can seek.
public struct MP3Encoder: Sendable, Equatable {
    /// The command-line interface that the program has.
    public enum Kind: String, Sendable {
        case lame
        case ffmpeg
    }

    /// The program's path.
    public var path: String
    public var kind: Kind
    /// The bit rate in kilobits per second.
    public var bitRate = 64

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    /// An encoder whose kind comes from its file name:
    /// FFmpeg if the name starts with `ffmpeg`, otherwise LAME.
    public init(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        self.init(path: path, kind: name.hasPrefix("ffmpeg") ? .ffmpeg : .lame)
    }

    /// The directories to search after `PATH`,
    /// because a server that launchd starts has a short `PATH`.
    public static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Finds `lame`, then `ffmpeg`,
    /// in the directories of `PATH`, then in ``fallbackDirectories``.
    ///
    /// - Parameters:
    ///   - path: The value of the `PATH` environment variable.
    ///   - isExecutable: Whether a file is an executable program.
    public static func locate(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> MP3Encoder? {
        var directories: [String] = []
        for directory in (path ?? "").split(separator: ":").map(String.init) + fallbackDirectories
        where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        for kind in [Kind.lame, .ffmpeg] {
            for directory in directories {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(kind.rawValue).path
                if isExecutable(candidate) {
                    return MP3Encoder(path: candidate, kind: kind)
                }
            }
        }
        return nil
    }

    /// The program's arguments for mono 16-bit little-endian PCM on standard input.
    func arguments(sampleRate: Int, output: String) -> [String] {
        switch kind {
        case .lame:
            [
                "-r", "-s", String(format: "%g", Double(sampleRate) / 1000),
                "--bitwidth", "16", "--signed", "--little-endian", "-m", "m",
                "-b", String(bitRate), "--silent", "-", output,
            ]
        case .ffmpeg:
            [
                "-hide_banner", "-loglevel", "error",
                "-f", "s16le", "-ar", String(sampleRate), "-ac", "1", "-i", "pipe:0",
                "-c:a", "libmp3lame", "-b:a", "\(bitRate)k",
                "-map_metadata", "-1", "-id3v2_version", "0",
                "-f", "mp3", "-y", output,
            ]
        }
    }

    /// Encodes mono 16-bit signed little-endian samples.
    ///
    /// - Throws: A 500 ``OpenAIError`` if the program can't start,
    ///   fails, writes nothing, or runs longer than `timeout`.
    public func encode(_ pcm: Data, sampleRate: Int, timeout: Duration = .seconds(60)) async throws -> Data {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("preowned-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments(sampleRate: sampleRate, output: output.path)
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        // An encoder that exits early closes the pipe;
        // without this, the write would raise SIGPIPE and end the server.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let exited = Exit()
        process.terminationHandler = { process in
            exited.finish(process.terminationReason == .exit ? process.terminationStatus : -1)
        }
        do {
            try process.run()
        } catch {
            throw failure("could not start: \(error.localizedDescription)")
        }

        // Write and read on threads outside the concurrency pool, because both block.
        let writer = input.fileHandleForWriting
        Thread.detachNewThread {
            try? writer.write(contentsOf: pcm)
            try? writer.close()
        }
        let reader = errors.fileHandleForReading
        let stderr = Task { await Self.onThread { reader.readDataToEndOfFile() } }

        let timedOut = Atomic(false)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.store(true, ordering: .relaxed)
            process.terminate()
        }
        let status = await exited.value
        watchdog.cancel()
        let message =
            String(decoding: await stderr.value, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""

        if timedOut.load(ordering: .relaxed) {
            throw failure("did not finish in \(timeout).")
        }
        guard status == 0 else {
            throw failure("exited with status \(status)" + (message.isEmpty ? "." : ": \(message)"))
        }
        guard let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw failure("wrote no audio.")
        }
        return data
    }

    /// Runs blocking work on its own thread.
    private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: body()) }
        }
    }

    private func failure(_ detail: String) -> OpenAIError {
        OpenAIError.server("The MP3 encoder at \(path) \(detail)")
    }

    /// The exit status of a process, which its termination handler reports once.
    private final class Exit: Sendable {
        private let state = Mutex<(status: Int32?, waiter: CheckedContinuation<Int32, Never>?)>((nil, nil))

        func finish(_ status: Int32) {
            let waiter = state.withLock { state in
                state.status = status
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: status)
        }

        var value: Int32 {
            get async {
                await withCheckedContinuation { continuation in
                    let status = state.withLock { state in
                        if state.status == nil { state.waiter = continuation }
                        return state.status
                    }
                    if let status { continuation.resume(returning: status) }
                }
            }
        }
    }
}
