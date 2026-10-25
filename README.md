<!--
  Drawing: Dutch and Barb in front of the lot,
  in the style of a 1960s roadside sign.
  The drawings are not done yet; put them here.
-->

# preowned

> "We have GPT at home."
> — Barb

Come on down to preowned!
Your Mac came off the line with a language model, an image maker,
a transcriber, a translator, and a set of voices,
and Dutch has put every one of them behind an OpenAI-compatible API.
Low mileage. One careful owner. That owner is you.

In plain terms:
preowned is a local HTTP server with an OpenAI-compatible API
for the models that ship with macOS.
Point an OpenAI client at `http://127.0.0.1:8027/v1`,
and chat, embeddings, transcription, translation, and speech
run on your Mac, with no account and no model download of its own.

"preowned" is a working name.

## Meet the family

<!-- Drawing: Dutch, mid-handshake. -->

**Dutch** runs the lot.
He will tell you that every model on it is good as new,
and he means it.
He is less interested in the fine print,
so this README keeps the fine print for him.

<!-- Drawing: Barb, arms folded, next to the family station wagon. -->

**Barbara** keeps the books.
When somebody asks for GPT, she points at the Mac on the desk.

## What's on the lot

| Endpoint | Model ID | Apple framework |
| --- | --- | --- |
| `GET /v1/models`, `GET /v1/models/{id}` | | |
| `POST /v1/chat/completions` | `apple-foundation-model` | Foundation Models |
| `POST /v1/images/generations` | `apple-image-playground` | Image Playground |
| `POST /v1/images/edits` | `apple-image-playground` | Image Playground |
| `POST /v1/images/variations` | `apple-image-playground` | Image Playground |
| `POST /v1/embeddings` | `apple-nl-embedding` | NaturalLanguage |
| `POST /v1/audio/transcriptions` | `apple-speech-transcriber` | Speech |
| `POST /v1/audio/translations` | `apple-speech-transcriber` | Speech, then Translation |
| `POST /v1/audio/speech` | `apple-speech-synthesizer` | AVFoundation (`AVSpeechSynthesizer`) |

A request can name any model, such as `gpt-4o` or `whisper-1`,
and the response reports the model ID from this table,
so existing code works without changes.
`GET /v1/models` lists only the models that work on this Mac right now.
[Docs/compatibility.md](Docs/compatibility.md) lists every OpenAI parameter
and what preowned does with it.

## Requirements

- A Mac with Apple silicon.
- macOS 26 or later.
- Apple Intelligence turned on in System Settings, for chat and images.
- Xcode 27 or later, to build preowned.
  The build needs the macOS 27 SDK, even for a Mac with macOS 26.
- [uv](https://docs.astral.sh/uv/), only for `make smoke`.

`preowned inventory` tells you what works on your Mac and why the rest doesn't.

## Install

From a checkout of this repository:

```sh
make
make install
```

`make` builds a release binary at `./preowned`,
and `make install` copies it to `/usr/local/bin`.
The Makefile runs Xcode's Swift through `xcrun`,
even when another Swift, such as one from swiftly, comes first on `PATH`.
If you can't write to `/usr/local/bin`,
run `sudo make install`,
or install somewhere else with `make install PREFIX="$HOME/.local"`.

## Quick start

See what's on the lot:

```sh
preowned inventory
```

Start the server:

```sh
preowned serve
```

On a Mac with macOS 27, it prints this:

```
The lot is open at http://127.0.0.1:8027/v1
Here's what's on the lot today:
  apple-foundation-model    Chat completions (Foundation Models): available
  apple-image-playground    Images (Image Playground): unavailable
                            ImageCreator is not supported for this process.
                            On macOS 27, run `preowned serve` with
                            `--images=interactive` or `--images=auto-approve`.
  apple-nl-embedding        Embeddings (NaturalLanguage): available
  apple-speech-transcriber  Transcriptions (Speech): available
  apple-speech-synthesizer  Speech (AVFoundation): available
Any API key works. No credit check.
Press Control-C to close the lot.
```

Take it for a test drive:

```sh
curl http://127.0.0.1:8027/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o", "messages": [{"role": "user", "content": "Say hello."}]}'
```

### Options

| Option | Default | Effect |
| --- | --- | --- |
| `--host` | `127.0.0.1` | The address to listen on. |
| `--port` | `8027` | The port to listen on. |
| `--api-key <key>` | none | Requests must send `Authorization: Bearer <key>`. Without it, any key works, or none. |
| `--strict-models` | off | Reject model names other than the model IDs above. |
| `--images <mode>` | `default` | `default`, `interactive`, or `auto-approve`. See [Images](#images). |
| `--image-timeout <seconds>` | `120` | How long each image waits for a person, in the window modes. |
| `--allow-origin <origin>` | none | Allow browser requests from this origin, such as `http://localhost:5173`. Repeat it for more origins. Without it, any request with an `Origin` header gets 403. |
| `--allow-asset-downloads` | off | Let Speech and NaturalLanguage download the language models that a request needs. Without it, such a request returns 503. |
| `--mp3-encoder <path>` | search | The `lame` or `ffmpeg` program that encodes MP3 speech, or `none`. Without it, preowned looks on `PATH`, then in `/opt/homebrew/bin` and `/usr/local/bin`. |

## Use it with the OpenAI SDKs

Set the base URL to `http://127.0.0.1:8027/v1`.
The SDKs require an API key, and any value works
unless you start the server with `--api-key`.

Python:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8027/v1", api_key="anything")

completion = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "What's a fair price for a used station wagon?"}],
)
print(completion.choices[0].message.content)
```

JavaScript and TypeScript:

```ts
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://127.0.0.1:8027/v1", apiKey: "anything" });

const completion = await client.chat.completions.create({
  model: "gpt-4o",
  messages: [{ role: "user", content: "What's a fair price for a used station wagon?" }],
});
console.log(completion.choices[0].message.content);
```

Both SDKs also read the `OPENAI_BASE_URL` and `OPENAI_API_KEY` environment variables,
so many tools work without code changes:

```sh
export OPENAI_BASE_URL=http://127.0.0.1:8027/v1
export OPENAI_API_KEY=anything
```

## Images

Dutch would like you to know that the image maker runs great.
Barb would like you to know the rest.

On macOS 26, Image Playground's `ImageCreator` can make images without any UI.
On macOS 27, Apple deprecated `ImageCreator`,
and it refuses to run in third-party processes such as preowned.
The only way left to get an image is an Image Playground window,
and that window hands over an image only after a person accepts it.
preowned has three image modes for this,
chosen with `preowned serve --images=<mode>`:

| Mode | How it works | Needs |
| --- | --- | --- |
| `default` | `ImageCreator`, with no UI. | macOS 26. On macOS 27, images are unavailable: `GET /v1/models` leaves out `apple-image-playground`, and the image endpoints return 503. |
| `interactive` | Each image opens an Image Playground window with the prompt, style, and source image filled in. The request waits until a person clicks Done, and returns an error if they cancel or the timeout passes. | A person at the Mac. |
| `auto-approve` | The same window, and Accessibility automation clicks Done. | The Accessibility permission. |

`auto-approve` is a hack.
It looks through the window's Accessibility tree for a button labeled "Done"
and presses it.
That button belongs to Apple's private UI,
so any macOS update can break this mode,
and it works only when the system language is English.
The permission belongs to the app that starts preowned, such as Terminal:
add it in System Settings > Privacy & Security > Accessibility.
Until you do, the mode reports images as unavailable.
`preowned inventory --images=auto-approve` shows whether the permission is granted.

The `default` mode on macOS 26 has not been tested on a macOS 26 Mac.
The server makes one image at a time.
[Docs/images.md](Docs/images.md) has the details,
and [Docs/image-playground-spike.md](Docs/image-playground-spike.md)
records what was tried on macOS 27.

## Sold as is

<!-- Drawing: Dutch waving a hand over a long scroll of fine print. -->

Every model on the lot runs.
Here is what Dutch forgot to mention.

- **No tool calling.**
  A chat request with `tools` or `functions` gets a 400.
- **One answer per request.**
  `n` must be 1.
- **Some chat parameters do nothing.**
  `top_p`, `stop`, `seed`, the penalties, `logit_bias`, and `logprobs` are accepted and ignored.
- **Structured output covers a subset of JSON Schema.**
  An unsupported keyword gets a 400 that names it.
  `json_object` mode asks the model for JSON but can't enforce it.
- **Images in chat** work only as base64 `data:` URLs,
  and only on macOS 27 with a model that accepts images.
- **Images on macOS 27 need a person**, or the `auto-approve` hack.
  See [Images](#images).
  Image Playground has no masks, so `mask` gets a 400,
  and the image can have a different size than the request asks for.
- **MP3 needs LAME or FFmpeg.**
  macOS has no MP3 encoder,
  so preowned runs `lame` or `ffmpeg` if it finds one
  (`brew install lame`).
  Without either, a speech request for `mp3`, which is OpenAI's default,
  returns AAC audio with `Content-Type: audio/aac`,
  and a player that trusts the `.mp3` extension may refuse the file.
  `preowned inventory` shows which you get.
- **Voices are approximate.**
  Each OpenAI voice name maps to a similar installed Apple voice,
  and `speed` maps to a speaking rate that varies by voice.
- **Embeddings have 512 dimensions**,
  and similarity scores run higher than OpenAI's,
  so thresholds tuned for OpenAI's models don't carry over.
  Inputs in different scripts use different models,
  so their vectors aren't comparable.
- **Transcription doesn't detect the language.**
  Send `language`, or the system language applies.
  `prompt` and `temperature` are ignored.
- **Translation needs installed languages.**
  A language pair that isn't installed gets a 503
  that names the System Settings pane where you can add it.
- **Chat token counts are estimates on macOS 26.**
  On macOS 27, they come from the model.
- **Only the endpoints in the table.**
  There is no Responses API, no legacy completions, no files, no moderation, and no Realtime.

[Docs/embeddings-and-audio.md](Docs/embeddings-and-audio.md) explains the audio and embedding choices,
and [Docs/compatibility.md](Docs/compatibility.md) has the full list.

## Development

| Command | What it does |
| --- | --- |
| `make` | Builds the release binary `./preowned`. |
| `make build` | Builds a debug binary in `.build/debug`. |
| `make test` | Runs the tests. They use fake services, so they don't need Apple Intelligence. |
| `make lint` | Checks the code with `swift format lint --strict`. |
| `make format` | Formats the code in place. |
| `make smoke` | Runs [Scripts/smoke.py](Scripts/smoke.py), which tests a running server with the official OpenAI Python SDK. |
| `make serve` | Builds and starts the server. |
| `make install` | Installs `preowned` in `/usr/local/bin`. |
| `make help` | Lists the targets. |

`make smoke` needs a server that is already running in the default image mode,
and its image check expects the 503 that macOS 27 gives.
Start one in another terminal, then run the test:

```sh
make serve
make smoke
```

For a server on another port, set `SMOKE_BASE_URL`,
such as `make smoke SMOKE_BASE_URL=http://127.0.0.1:18104/v1`.
The script checks the model list, chat with streaming and structured output,
embeddings, speech, a round trip from speech to transcription,
and the 503 from the image endpoint.

Tests that call the real Apple models run only with `PREOWNED_LIVE_TESTS=1`:

```sh
PREOWNED_LIVE_TESTS=1 swift test
```

## License

MIT. See [LICENSE.md](LICENSE.md).
