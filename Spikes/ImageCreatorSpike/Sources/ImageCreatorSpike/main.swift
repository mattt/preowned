// A spike that tests whether ImageCreator can make images
// from a process that could host an HTTP server.
//
// Usage:
//   ImageCreatorSpike [--host bare|accessory|regular]
//                     [--task text|twice|styles|extracted|limit2|image]
//                     [--style NAME] [--prompt TEXT] [--input PNG]
//                     [--out DIR] [--delay SECONDS]
//
// Each line of output starts with "SPIKE" so that logs are easy to filter.

import AppKit
import Foundation
import FoundationModels
import ImagePlayground
import UniformTypeIdentifiers

struct Options {
    var host = "bare"
    var task = "text"
    var style = "illustration"
    var prompt = "a red bicycle leaning against a brick wall"
    var input: String?
    var out = "out"
    var delay: Double = 0

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            let value = iterator.next() ?? ""
            switch argument {
            case "--host": host = value
            case "--task": task = value
            case "--style": style = value
            case "--prompt": prompt = value
            case "--input": input = value
            case "--out": out = value
            case "--delay": delay = Double(value) ?? 0
            default: log("ignoring argument \(argument)")
            }
        }
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current,
        formatOptions: [.withFullTime, .withFractionalSeconds])
    print("SPIKE \(stamp) \(message)")
    fflush(stdout)
}

func describe(_ error: any Error) -> String {
    let nsError = error as NSError
    return
        "\(String(reflecting: error)) | domain=\(nsError.domain) code=\(nsError.code) "
        + "description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
}

func style(named name: String) -> ImagePlaygroundStyle {
    switch name {
    case "animation": return .animation
    case "sketch": return .sketch
    case "emoji": return .emoji
    case "externalProvider": return .externalProvider
    case "any":
        if #available(macOS 27, *) { return .any }
        return .illustration
    default: return .illustration
    }
}

func frontmostDescription() -> String {
    let front = NSWorkspace.shared.frontmostApplication
    return "frontmost=\(front?.bundleIdentifier ?? "nil") pid=\(front?.processIdentifier ?? -1) "
        + "self.pid=\(ProcessInfo.processInfo.processIdentifier) "
        + "self.bundleID=\(Bundle.main.bundleIdentifier ?? "nil")"
}

func save(_ image: CGImage, name: String, directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "\(name).png")
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    log("saved \(url.path) bytes=\(size)")
    return url
}

func generate(
    creator: ImageCreator, concepts: [ImagePlaygroundConcept], style: ImagePlaygroundStyle,
    limit: Int, label: String, directory: URL
) async throws -> [URL] {
    log("\(label): start style=\(style.id) limit=\(limit) \(frontmostDescription())")
    let start = ContinuousClock.now
    var last = start
    var urls: [URL] = []
    var index = 0
    for try await created in creator.images(for: concepts, style: style, limit: limit) {
        let now = ContinuousClock.now
        log(
            "\(label): image \(index) size=\(created.cgImage.width)x\(created.cgImage.height) "
                + "elapsed=\(now - start) sinceLast=\(now - last)")
        last = now
        urls.append(try save(created.cgImage, name: "\(label)-\(index)", directory: directory))
        index += 1
    }
    log("\(label): done count=\(index) total=\(ContinuousClock.now - start)")
    return urls
}

func run(_ options: Options) async -> Int32 {
    log("host=\(options.host) task=\(options.task) \(frontmostDescription())")
    log("ImagePlaygroundViewController.isAvailable=\(ImagePlaygroundViewController.isAvailable)")
    log("SystemLanguageModel.default.availability=\(SystemLanguageModel.default.availability)")
    if options.delay > 0 {
        log("sleeping \(options.delay)s before creating; switch to another app now")
        try? await Task.sleep(for: .seconds(options.delay))
        log("awake \(frontmostDescription())")
    }
    let directory = URL(filePath: options.out)
    do {
        let initStart = ContinuousClock.now
        let creator = try await ImageCreator()
        log("ImageCreator.init took \(ContinuousClock.now - initStart)")
        log("availableStyles=\(creator.availableStyles.map(\.id))")
        log("ImagePlaygroundStyle.all=\(ImagePlaygroundStyle.all.map(\.id))")
        if #available(macOS 27, *) {
            log("ImagePlaygroundStyle.any.id=\(ImagePlaygroundStyle.any.id)")
        }
        let chosen = style(named: options.style)
        switch options.task {
        case "text":
            _ = try await generate(
                creator: creator, concepts: [.text(options.prompt)], style: chosen, limit: 1,
                label: "text-\(chosen.id)", directory: directory)
        case "twice":
            for round in 1...2 {
                _ = try await generate(
                    creator: creator, concepts: [.text(options.prompt)], style: chosen, limit: 1,
                    label: "twice-\(round)", directory: directory)
            }
        case "styles":
            for candidate in creator.availableStyles {
                do {
                    _ = try await generate(
                        creator: creator, concepts: [.text(options.prompt)], style: candidate,
                        limit: 1, label: "style-\(candidate.id)", directory: directory)
                } catch {
                    log("style-\(candidate.id): error \(describe(error))")
                }
            }
        case "extracted":
            _ = try await generate(
                creator: creator,
                concepts: [.extracted(from: options.prompt, title: "Harbor morning")],
                style: chosen, limit: 1, label: "extracted", directory: directory)
        case "limit2":
            _ = try await generate(
                creator: creator, concepts: [.text(options.prompt)], style: chosen, limit: 2,
                label: "limit2", directory: directory)
        case "image":
            guard let path = options.input,
                let concept = ImagePlaygroundConcept.image(URL(filePath: path))
            else {
                log("image: could not load --input")
                return 2
            }
            var concepts = [concept]
            if !options.prompt.isEmpty { concepts.append(.text(options.prompt)) }
            _ = try await generate(
                creator: creator, concepts: concepts, style: chosen, limit: 1, label: "image",
                directory: directory)
        default:
            log("unknown task \(options.task)")
            return 2
        }
        log("RESULT success")
        return 0
    } catch {
        log("RESULT error \(describe(error))")
        return 1
    }
}

let options = Options(arguments: CommandLine.arguments)

switch options.host {
case "accessory", "regular":
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy =
            options.host == "regular" ? .regular : .accessory
        log("setActivationPolicy(\(options.host)) -> \(app.setActivationPolicy(policy))")
        if options.host == "regular" {
            app.activate()
        }
        Task { @MainActor in
            // Let the run loop start and the activation settle.
            try? await Task.sleep(for: .milliseconds(500))
            log("isActive=\(app.isActive) \(frontmostDescription())")
            let status = await run(options)
            exit(status)
        }
        app.run()
    }
default:
    Task {
        let status = await run(options)
        exit(status)
    }
    dispatchMain()
}
