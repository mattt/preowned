<p align="center">
  <img src="Docs/Images/lot.webp" width="800"
       alt="A hand-lettered PREOWNED sign stands over three beige all-in-one computers with price tags. A bald salesman in a plaid jacket and tiny hat gestures at them. Beside him, a woman with a high ponytail, round glasses, and a yellow dress holds a ledger.">
</p>

# preowned

> "We have GPT at home."
> — Barb

Come on down to preowned!
Your Mac drove off the line with a language model, an image maker,
a transcriber, a translator, and a trunk full of voices.
Dutch has put every one of them behind an OpenAI-compatible API.
Low mileage. One careful owner: you!

In plain terms,
preowned is a local HTTP server that serves the models built into macOS
through the OpenAI API.
Point any OpenAI client at `http://127.0.0.1:8027/v1`,
and chat, embeddings, transcription, translation, and speech
run on your Mac.

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

Ask for `gpt-4o` or `whisper-1` and you get the Apple model for that endpoint.
The response reports the model ID from this table,
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

With [Homebrew](https://brew.sh):

```sh
brew install mattt/tap/preowned
```

The formula installs a prebuilt binary,
so you don't need Xcode.

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

<img src="Docs/Images/dutch.webp" width="180" align="left"
     alt="Dutch, bald and grinning in a plaid jacket and bow tie, holds out one hand for a handshake and gives a thumbs-up with the other.">

Walk the lot first.
`preowned inventory` lists each model, whether it works,
and the details under the hood:
installed languages, embedding models, and which Apple voice
stands in for each OpenAI voice.

```sh
preowned inventory
```

Then open for business:

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

### Take it for a test drive

Ask Dutch a question:

```sh
curl http://127.0.0.1:8027/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [
      {"role": "system", "content": "You sell used cars. Answer in one sentence."},
      {"role": "user", "content": "Is this Mac any good?"}
    ]
  }'
```

Record his pitch, then play it back through the transcriber:

```sh
curl http://127.0.0.1:8027/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1", "voice": "onyx", "input": "Come on down! Everything on the lot must go."}' \
  -o pitch.mp3

curl http://127.0.0.1:8027/v1/audio/transcriptions \
  -F file=@pitch.mp3 -F model=whisper-1 -F language=en
```

On a Mac with macOS 27.0.1, that round trip came back as this:

```json
{"text":"Come on down. Everything on the lock must go.","usage":{"seconds":4,"type":"duration"}}
```

Close enough.
Add `-F response_format=srt` for subtitles.

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
Both SDKs also read `OPENAI_BASE_URL` and `OPENAI_API_KEY`,
so many tools work without code changes:

```sh
export OPENAI_BASE_URL=http://127.0.0.1:8027/v1
export OPENAI_API_KEY=anything
```

### Python

Chat, streamed a token at a time:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8027/v1", api_key="anything")

stream = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Write a four-line jingle for a used car lot."}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

Structured output, straight into a Pydantic model:

```python
from typing import Literal

from pydantic import BaseModel


class Listing(BaseModel):
    make: str
    model: str
    year: int
    mileage: int
    condition: Literal["like new", "good", "fair", "as is"]


completion = client.chat.completions.parse(
    model="gpt-4o",
    messages=[{"role": "user", "content": "Write a listing for a rusty 1967 station wagon."}],
    response_format=Listing,
)
print(completion.choices[0].message.parsed)
# make='Ford' model='station wagon' year=1967 mileage=120000 condition='as is'
```

Embeddings, to match a customer with a vehicle:

```python
listings = [
    "A roomy station wagon that seats the whole family.",
    "A two-seat convertible that is fast, loud, and red.",
    "A pickup truck with a long bed and a tow hitch.",
]
query = "a truck for towing a boat"

response = client.embeddings.create(model="text-embedding-3-small", input=[query, *listings])
query_vector, *listing_vectors = [item.embedding for item in response.data]

# The vectors are unit length, so the dot product is the cosine similarity.
scores = [sum(a * b for a, b in zip(query_vector, v)) for v in listing_vectors]
print(max(zip(scores, listings)))
# (0.927..., 'A pickup truck with a long bed and a tow hitch.')
```

Barb wants you to look at the other two scores too:
0.876 for the station wagon and 0.845 for the convertible.
Apple's embeddings rank well enough for short, plain text,
but the margins are thin.
Test them on your own data before you trust a threshold.

Speech to a file, then back to text:

```python
with client.audio.speech.with_streaming_response.create(
    model="tts-1",
    voice="nova",
    input="Low mileage. One careful owner. Priced to move.",
) as response:
    response.stream_to_file("pitch.mp3")

with open("pitch.mp3", "rb") as audio:
    transcript = client.audio.transcriptions.create(model="whisper-1", file=audio, language="en")
print(transcript.text)
# Low mileage. One careful owner. Price to move.
```

### JavaScript and TypeScript

```ts
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://127.0.0.1:8027/v1", apiKey: "anything" });

const stream = await client.chat.completions.create({
  model: "gpt-4o",
  messages: [{ role: "user", content: "Write a four-line jingle for a used car lot." }],
  stream: true,
});
for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0]?.delta?.content ?? "");
}
```

## Images

On macOS 26, Image Playground's `ImageCreator` makes images without any UI.
On macOS 27, Apple deprecated `ImageCreator`,
and it refuses to run in third-party processes such as preowned.
The only way left is an Image Playground window,
and that window hands over an image only after a person accepts it.
preowned has three image modes for this,
chosen with `preowned serve --images=<mode>`:

| Mode | How it works | Needs |
| --- | --- | --- |
| `default` | `ImageCreator`, with no UI. | macOS 26. On macOS 27, images are unavailable: `GET /v1/models` leaves out `apple-image-playground`, and the image endpoints return 503. |
| `interactive` | Each image opens an Image Playground window with the prompt, style, and source image filled in. The request waits until a person clicks Done, and returns an error if they cancel or the timeout passes. | A person at the Mac. |
| `auto-approve` | The same window, and Accessibility automation clicks Done. | The Accessibility permission. |

<img src="Docs/Images/barb.webp" width="180" align="right"
     alt="Barb, arms folded over her ledger and one eyebrow raised, stands in front of a wood-paneled station wagon with a computer strapped to the roof.">

`auto-approve` is... a hack.
It searches the window's Accessibility tree for a button labeled "Done"
and presses it.
That button belongs to Apple's private UI,
so any macOS update can break this mode,
and it works only when the system language is English.
The permission belongs to the app that starts preowned, such as Terminal:
add it in System Settings > Privacy & Security > Accessibility.
Until you do, the mode reports images as unavailable.
`preowned inventory --images=auto-approve` shows whether the permission is granted.

## Sold as-is

<p align="center">
  <img src="Docs/Images/fine-print.webp" width="600"
       alt="Dutch whistles with his eyes closed and waves, while a scroll of fine print unrolls from his other hand across the ground.">
</p>

Every model on the lot runs.
Barb read the fine print so you don't have to.

- **No tool calling.**
  A chat request with `tools` or `functions` gets a 400.
- **One answer per request.**
  `n` must be 1.
- **Some chat parameters do nothing.**
  `top_p`, `stop`, `seed`, the penalties, `logit_bias`, and `logprobs`
  are accepted and ignored.
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
  macOS can't encode MP3,
  so preowned runs `lame` or `ffmpeg` if it finds one
  (`brew install lame`).
  Without either, a request for `mp3`, which is OpenAI's default,
  returns AAC with `Content-Type: audio/aac`,
  and a player that trusts the `.mp3` extension may refuse the file.
  `preowned inventory` shows which you get.
- **Voices are approximate.**
  Each OpenAI voice maps to a similar installed Apple voice,
  and `speed` maps to a speaking rate that varies by voice.
  If Oliver and Arthur aren't installed, `ballad` is Grandpa.
  Download higher-quality voices in System Settings > Accessibility > Spoken Content,
  or ask for any installed voice by name, such as `"voice": "Samantha"`.
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
  There is no Responses API, no legacy completions, no files, no moderation,
  and no Realtime.

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
