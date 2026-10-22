# Images

preowned serves three image endpoints with Image Playground:
`POST /v1/images/generations` (JSON),
and `POST /v1/images/edits` and `POST /v1/images/variations` (multipart).
Each returns OpenAI's image response, `{"created", "data"}`,
with one PNG for each image.
The model ID is `apple-image-playground`.

The server makes one image at a time.
Other requests wait in a queue, in the order that they arrive.

## Modes

On macOS 27, Image Playground's `ImageCreator` refuses to run
in third-party processes
([the spike](image-playground-spike.md) has the details),
so `preowned serve --images=<mode>` offers three modes.
`preowned inventory --images=<mode>` reports what that mode can do on this Mac,
and whether the process has the Accessibility permission.

| Mode | How it works | Needs |
| --- | --- | --- |
| `default` | `ImageCreator`, without UI. | macOS 26. On macOS 27, images are unavailable: `GET /v1/models` leaves out `apple-image-playground`, `inventory` gives the reason, and the endpoints return 503. |
| `interactive` | Each image opens an Image Playground window with the prompt, style, and source image filled in. The request waits until a person clicks Done or cancels. | A person at the Mac. |
| `auto-approve` | The same window, with Accessibility automation that presses Done. | The Accessibility permission. |

In the window modes, the CLI runs an AppKit main loop next to the server.
The process has no Dock icon until a window opens.
`--image-timeout <seconds>` (default 120) sets how long each image can wait.
A request for `n` images opens `n` windows, one after another,
and each window has its own timeout.

### Auto-approve is a hack

Image Playground returns an image only after someone accepts it,
and Apple offers no API to accept it in code.
Auto-approve mode searches the window's Accessibility tree
for an enabled button labeled "Done" and presses it.
That label and the tree belong to Apple's private extension UI,
so any macOS update can break this mode,
and it works only when the system language is English.

The permission belongs to the app that starts `preowned`,
such as Terminal.
`serve --images=auto-approve` asks macOS to show the permission prompt.
Until the permission is granted,
the mode reports images as unavailable and the endpoints return 503.
Set `PREOWNED_AX_DEBUG=1` to log the buttons that the automation finds.

## Parameters

| Parameter | Endpoints | Behavior |
| --- | --- | --- |
| `prompt` | generations, edits | Required. A prompt of up to 200 characters becomes `.text(_:)`; a longer prompt becomes `.extracted(from:title:)`, which picks the key ideas out of the text. Variations ignore it. |
| `image`, `image[]` | edits, variations | Required. One image in a format that ImageIO reads. More than one image returns 400. |
| `mask` | edits | Returns 400 `unsupported_parameter`; Image Playground has no masks. |
| `n` | all | 1 to 10, or 1 to 4 in the window modes. Each image is one `ImageCreator` result or one window. |
| `style` | all | An Image Playground style: `animation`, `illustration`, `sketch`, and any other on-device style that the Mac offers, such as `emoji` or `any`. OpenAI's `vivid` maps to `animation`, and `natural` maps to `illustration`. The external-provider style is not offered. Without a style, `ImageCreator` uses `illustration`, and the window keeps its own choice. |
| `size` | all | `auto` or `WIDTHxHEIGHT`. The window modes on macOS 27 pass it to Image Playground as the closest size it supports. The server never resamples, so the image can have another size. The default mode ignores it. |
| `quality` | generations | Accepted and ignored. |
| `response_format` | all | `b64_json` (the default) or `url`. preowned has no place to host files, so `url` is a `data:image/png;base64,` URL. |
| `model` | all | Any name, unless `--strict-models` is set. |

## Errors

Every error has OpenAI's shape.

| Situation | Status | `type` | `code` |
| --- | --- | --- | --- |
| Images unavailable in this mode | 503 | `server_error` | `service_unavailable` |
| Invalid parameter or image | 400 | `invalid_request_error` | `invalid_value`, `invalid_image`, `missing_required_parameter`, or `unsupported_parameter` |
| A person cancels or closes the window | 400 | `invalid_request_error` | `image_generation_cancelled` |
| Nobody accepts the image in time | 504 | `server_error` | `timeout` |
