import Foundation
import Testing

@testable import PreownedKit

@Suite("MP3 encoder")
struct MP3EncoderTests {
    @Test("lame comes before ffmpeg, and PATH before the fallback directories")
    func locate() {
        func locate(_ path: String?, _ installed: Set<String>) -> MP3Encoder? {
            MP3Encoder.locate(path: path, isExecutable: installed.contains)
        }
        #expect(locate("/usr/bin:/bin", []) == nil)
        #expect(locate(nil, []) == nil)
        #expect(
            locate("/a:/b", ["/b/lame", "/a/ffmpeg"]) == MP3Encoder(path: "/b/lame", kind: .lame)
        )
        #expect(
            locate("/a", ["/a/ffmpeg", "/opt/homebrew/bin/lame"])
                == MP3Encoder(path: "/opt/homebrew/bin/lame", kind: .lame)
        )
        #expect(
            locate("/usr/bin", ["/usr/local/bin/ffmpeg"])
                == MP3Encoder(path: "/usr/local/bin/ffmpeg", kind: .ffmpeg)
        )
        #expect(locate("", ["/opt/homebrew/bin/ffmpeg"])?.path == "/opt/homebrew/bin/ffmpeg")
    }

    @Test("The kind comes from the file name")
    func kind() {
        #expect(MP3Encoder(path: "/opt/homebrew/bin/lame").kind == .lame)
        #expect(MP3Encoder(path: "/usr/local/bin/ffmpeg").kind == .ffmpeg)
        #expect(MP3Encoder(path: "/tmp/FFmpeg-7").kind == .ffmpeg)
        #expect(MP3Encoder(path: "/tmp/encoder").kind == .lame)
    }

    @Test("Each kind reads mono 16-bit PCM from standard input and writes the output file")
    func arguments() {
        let lame = MP3Encoder(path: "lame", kind: .lame).arguments(sampleRate: 24_000, output: "out.mp3")
        #expect(lame.starts(with: ["-r", "-s", "24", "--bitwidth", "16", "--signed", "--little-endian", "-m", "m"]))
        #expect(lame.suffix(2) == ["-", "out.mp3"])
        let ffmpeg = MP3Encoder(path: "ffmpeg", kind: .ffmpeg).arguments(sampleRate: 24_000, output: "out.mp3")
        #expect(ffmpeg.contains("s16le"))
        #expect(ffmpeg.contains("pipe:0"))
        #expect(ffmpeg.contains("libmp3lame"))
        #expect(ffmpeg.last == "out.mp3")
    }

    /// An executable shell script in a new directory.
    func script(_ body: String) throws -> (encoder: MP3Encoder, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preowned-mp3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("lame")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (MP3Encoder(path: url.path, kind: .lame), directory)
    }

    @Test("The input reaches the program, and the output file comes back")
    func encode() async throws {
        // The script copies standard input to its last argument, the output file.
        let (encoder, directory) = try script(#"for argument; do output="$argument"; done; cat > "$output""#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcm = Data((0..<200_000).map { UInt8($0 & 0xFF) })
        let data = try await encoder.encode(pcm, sampleRate: 24_000)
        #expect(data == pcm)
    }

    @Test(
        "A failing, silent, or slow program is a 500 server_error",
        arguments: [
            ("echo 'bad input' >&2; exit 3", "exited with status 3: bad input"),
            ("cat > /dev/null", "wrote no audio."),
            ("sleep 10", "did not finish in"),
        ]
    )
    func failures(body: String, detail: String) async throws {
        let (encoder, directory) = try script(body)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = await #expect(throws: OpenAIError.self) {
            try await encoder.encode(Data(count: 48_000), sampleRate: 24_000, timeout: .milliseconds(500))
        }
        #expect(error?.status == .internalServerError)
        #expect(error?.type == "server_error")
        #expect(error?.message.contains(detail) == true)
    }

    @Test("A program that doesn't exist is a 500")
    func missingProgram() async throws {
        let encoder = MP3Encoder(path: "/nonexistent/lame", kind: .lame)
        let error = await #expect(throws: OpenAIError.self) {
            try await encoder.encode(Data(count: 2), sampleRate: 24_000)
        }
        #expect(error?.status == .internalServerError)
    }
}
