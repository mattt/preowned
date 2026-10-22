# Image Playground spike

This spike asks whether `ImagePlayground.ImageCreator`
can create images from a process that could host an HTTP server,
and what that process needs.
The code is in `Spikes/ImageCreatorSpike/`,
a standalone SwiftPM package with one executable and a script,
`make-app.sh`, that wraps the executable in an ad hoc signed `.app` bundle.

The short answer is no.
On macOS 27.0.1, `ImageCreator()` throws `notSupported` within milliseconds
in every hosting variant,
and the framework logs that ImageCreator "is deprecated and no longer available
for this application."
No variant reached image generation,
so the per-image questions have no `ImageCreator` answers.

## Environment

- Mac: Apple M4 Max (arm64).
- macOS 27.0.1 (26A434); macOS 27 SDK from Xcode;
  Apple Swift 6.4 (swiftlang-6.4.0.34.1).
- Locale `en_US`, language `en-US`.
- `SystemLanguageModel.default.availability` is `available`,
  and `ImagePlaygroundViewController.isAvailable` is `true`,
  so Apple Intelligence is on and the image models are present.
- The screen was locked for the whole run
  (`CGSSessionScreenIsLocked` and `IOConsoleLocked` were true,
  and the frontmost application was `com.apple.loginwindow`).
  See [Confounds](#confounds).
- Test date: 2026-10-22, 15:48 to 15:56 Pacific.

## Declarations

From `ImagePlayground.swiftmodule/arm64e-apple-macos.swiftinterface`
in the macOS 27 SDK:

- `ImageCreator`, its `Error` enum, and both `images(for:style:...)` overloads
  carry `@available(anyAppleOS, deprecated: 27.0,
  message: "Use ImagePlaygroundViewController or imagePlaygroundSheet.")`.
- `ImageCreator.init() async throws` is the only initializer.
- `ImageCreator.Error` has `notSupported`, `unavailable`, `creationCancelled`,
  `faceInImageTooSmall`, `unsupportedLanguage`, `unsupportedInputImage`,
  `backgroundCreationForbidden`, `creationFailed`,
  and (macOS 26) `conceptsRequirePersonIdentity`.
  Sosumi's page for `backgroundCreationForbidden` says
  "Apps must perform image creation only when running in the foreground."
- `ImagePlaygroundStyle.any` is new in macOS 27,
  and `ImagePlaygroundOptions` gains `creationStrategy`
  and `sizeSpecification` (`.closest(to: CGSize)`) in macOS 27.
- `ImagePlaygroundViewController` is an `NSViewController`
  with `concepts`, `selectedGenerationStyle`, `allowedGenerationStyles`,
  `options`, `sourceImage`, and a delegate
  that receives `didCreateImageAt` or `DidCancel`.

## Results

Each run asked for one image from `.text("a red bicycle leaning against a brick wall")`
in the `illustration` style.
"Time" is from process start to the error.

| # | Variant | Outcome | Exact error | Time |
| --- | --- | --- | --- | --- |
| 1 | Bare executable from the terminal (`.build/debug`, no bundle) | Failed in `ImageCreator()` | `ImagePlayground.ImageCreator.Error.notSupported`, domain `ImageCreatorError`, code 0, "Image Playground is not supported on this device." | about 10 ms |
| 2 | Same, `NSApplication.shared` with `.accessory` and a running run loop | Failed in `ImageCreator()` | Same as 1 | about 4 ms after the run loop started |
| 3 | Same, `.regular` and `activate()` | Failed in `ImageCreator()` | Same as 1 | about 1 ms after the run loop started |
| 3b | `.app` bundle with `LSUIElement` false, `.regular`, launched with `open` | Failed in `ImageCreator()` | Same as 1 | about 10 ms |
| 4a | `.app` bundle (`com.example.preowned.ImageCreatorSpike`, `LSUIElement` true, `codesign -s -`), binary run directly, bare and `.accessory` | Failed in `ImageCreator()` | Same as 1 | under 10 ms |
| 4b | Same bundle launched with `open -n`, bare and `.accessory` | Failed in `ImageCreator()` | Same as 1 | under 20 ms |
| 4c | Bare executable with its `LC_BUILD_VERSION` rewritten by `vtool` to SDK 15.4 and to SDK 26.0, then ad hoc signed | Failed in `ImageCreator()` | Same as 1 | under 10 ms |
| 5 | Not frontmost; two requests in a row | Not run | No variant created an image | n/a |

In every run, the unified log has this line from the spike process,
subsystem `com.apple.ImagePlayground`, category `InlineAPI`:

```
ImageCreator is deprecated and no longer available for this application.
```

`backgroundCreationForbidden` never appeared,
because the failure happens in `init()`, before any foreground check.
The SwiftPM build records SDK 26.0 in the Mach-O build version
(`vtool -show-build`), and rewriting it to 15.4 changed nothing,
so the gate does not look like a linked-on-or-after SDK check (observed).
What the gate does check is unknown;
"for this application" suggests a per-application decision
(inferred, not verified).

## Other questions

The per-image questions need a working `ImageCreator`, which no variant had:

- Time per image, CGImage pixel size, `.extracted(from:title:)`,
  `images(for:style:options:limit:)` with `limit` 2,
  and `.image(_:)` image-to-image: not observable.
- `availableStyles` is an instance property, so it was not observable.
  The static `ImagePlaygroundStyle.all` returns these IDs (observed):
  `any`, `animation`, `illustration`, `sketch`, `emoji`, `z_external_provider`.
  `.any.id` is `any`, and `.externalProvider.id` is `z_external_provider`.
  What `.any` produces was not observable.
- No sample PNGs were saved; the spike created no `ImageCreator` images.

## ImagePlaygroundViewController

`--task viewcontroller` puts an `ImagePlaygroundViewController`
in an `NSWindow` in a `.regular` process (no bundle),
sets `concepts` and `selectedGenerationStyle`,
and waits 60 seconds for a delegate callback with no user action.
These are the observations, from the spike's output and the unified log:

- The controller's view hosts an app extension:
  the view tree is `NSHostingView<GPImageEditionView>`, `_EXHostView`, `NSRemoteView`,
  and the UI runs in `GPUIExtension`,
  bundle `com.apple.GenerativePlaygroundApp.remoteUIExtension`.
- Concepts set before the extension connects are lost.
  The host logs "Could not send prompt elements to remote view",
  and the extension logs "setPromptElements - composingViewModel is nil".
  Setting `concepts` again 3 seconds later worked.
- After the second assignment,
  the extension generated one preview without user action,
  about 2.8 seconds after the concepts arrived
  (log timestamps 15:54:03.020 to 15:54:05.827),
  while the screen was locked.
  It stored the preview in its own sandbox container.
- No delegate callback arrived in 60 seconds.
  `didCreateImageAt` needs the person to accept an image in the sheet
  (observed: no callback; inferred: the accept button is the trigger,
  consistent with the delegate's design).
- The extension checks a Private Cloud Compute quota
  (`PCCUsageMonitor`, feature `VisualGeneration.ImagePlayground`) when it starts.
  Whether generation itself uses Private Cloud Compute was not determined.

The host cannot read the image without a click inside the remote view.
Synthesizing that click through the Accessibility API,
or reading files from the extension's container,
might work but would be fragile and would need Accessibility or Full Disk Access
permission (inferred, not attempted).

The Image Playground app's App Intents extension
(`GenerativePlaygroundAppIntents.appex`) declares no actions (observed),
so there is no App Intent or Shortcuts action from that app to call.
Whether another Shortcuts action can create images was not checked.

## Confounds

The screen was locked during every run,
and the agent could not unlock it.
The `InlineAPI` log line names deprecation, not the lock or the foreground state,
and the view controller generated a preview while locked,
so the lock is unlikely to cause `notSupported` (inferred).
A rerun with the screen unlocked and the spike frontmost would settle it:

```sh
cd Spikes/ImageCreatorSpike
swift run ImageCreatorSpike --host regular
./make-app.sh && open -W -n --stdout /dev/ttys000 build/ImageCreatorSpike.app --args --host regular
```

Replace `/dev/ttys000` with the output of `tty`.

## Recommendation

On macOS 27, `preowned serve` cannot create images without UI
through any hosting arrangement tested here:
not as a bare CLI, not as an accessory or regular `NSApplication`,
and not as an ad hoc signed `.app` bundle launched by LaunchServices.
A helper `.app` reached over XPC or a local socket would fail the same way,
because the bundle variants already fail.
So the recommendation is to keep the server a plain CLI and do not build a helper app.

For phase 3, the agent proposes this:

1. Put `ImageService` behind a capability check
   that calls `try await ImageCreator()` once at startup.
   On `notSupported` or `unavailable`,
   `GET /v1/models` leaves out `apple-image-playground`,
   `inventory` reports Image Playground as unavailable
   with the reason "ImageCreator is disabled for third-party processes on macOS 27",
   and the image endpoints return 503 with OpenAI's error shape.
2. Keep the `ImageCreator` code path for macOS 26,
   where the API is not deprecated.
   It is untested there; the documentation's `backgroundCreationForbidden`
   suggests that even on macOS 26 the process must be a frontmost app,
   which a background server is not (inferred).
   Test it on a macOS 26 Mac before relying on it.
3. Do not build an interactive fallback in version 1.
   A route that opens `ImagePlaygroundViewController`
   and waits for the person to accept an image
   would work only with someone at the Mac,
   which does not fit an API that clients call.

If Mattt wants image endpoints on macOS 27 anyway,
the only path the spike found is the interactive one:
a `.regular` app (the CLI can become one) shows the view controller,
sets `concepts` after the remote view connects,
and returns the file from `didCreateImageAt` after the person accepts it.
That is a product decision, not a hosting fix.
