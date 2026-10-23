import ArgumentParser
import Foundation
import PreownedKit

/// The `--mp3-encoder` option of `serve` and `inventory`.
struct MP3EncoderOption: ParsableArguments {
    @Option(
        name: .customLong("mp3-encoder"),
        help: ArgumentHelp(
            "The program that encodes MP3 speech: the path of lame or ffmpeg, or none.",
            discussion: "Without it, preowned looks for lame, then ffmpeg, "
                + "on PATH and in /opt/homebrew/bin and /usr/local/bin. "
                + "Without an encoder, mp3 requests get AAC.",
            valueName: "path"
        )
    )
    var path: String?

    func validate() throws {
        if let path, path != "none", !FileManager.default.isExecutableFile(atPath: path) {
            throw ValidationError("--mp3-encoder: \(path) is not an executable program.")
        }
    }

    /// The encoder that the option selects.
    var encoder: MP3Encoder? {
        switch path {
        case nil: MP3Encoder.locate()
        case "none": nil
        case let path?: MP3Encoder(path: path)
        }
    }
}
