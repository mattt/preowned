# Compatibility

This page lists, for each endpoint family,
every OpenAI request parameter and what preowned does with it,
and which response fields carry real values and which are placeholders.
It describes the code at the time of writing;
[images](images.md) and [embeddings and audio](embeddings-and-audio.md)
explain the choices behind it.

Each parameter has one of these behaviors:

- **Supported**: preowned uses the value.
- **Ignored**: preowned accepts the value and does nothing with it.
  The request still succeeds.
- **Rejected**: preowned returns a 400 error in OpenAI's error format.

## Everything

These rules apply to every endpoint.

- Every error has OpenAI's body:
  `{"error": {"message", "type", "param", "code"}}`,
  with `null` for a missing `param` or `code`.
- Without `--api-key`, the server accepts any bearer token, or none.
  With `--api-key`, a request without the token gets 401 with no code,
  and a request with the wrong token gets 401 with the code `invalid_api_key`.
- `model` can be any name, such as `gpt-4o` or `whisper-1`,
  and responses that have a `model` field report the canonical ID.
  With `--strict-models`, a name other than the canonical ID is a 404 `model_not_found`,
  and a missing `model` is a 400 `missing_required_parameter`.
  In both modes, the canonical ID of another endpoint's model,
  such as `apple-nl-embedding` in a chat request,
  is a 400 `model_not_supported`.
- A model that is unavailable on this Mac gives 503
  with `type: server_error` and `code: service_unavailable`,
  and a message that gives the reason.
  `preowned inventory` prints the same reasons.
- A JSON body that doesn't decode is a 400 with no code,
  such as "Missing required parameter: 'messages'."
- JSON and multipart image bodies can have up to 32 MiB.
  Audio uploads can have up to 26 MiB, with a file of up to 25 MiB.
  A larger body is a 413.
- A path that has no route is a 404 with the message `Invalid URL (METHOD /path)`.
  preowned has no `/v1/responses`, `/v1/completions`, `/v1/moderations`,
  `/v1/files`, `/v1/batches`, `/v1/fine_tuning`, Assistants, Realtime,
  or `DELETE /v1/models/{id}`.

## Models

`GET /v1/models` and `GET /v1/models/{id}` list only the models
that are available on this Mac now.
A model that is unavailable, such as `apple-image-playground` in the default image mode on macOS 27,
is a 404 `model_not_found` from `GET /v1/models/{id}`.

| Response field | Value |
| --- | --- |
| `object` | `list`, and `model` for each model. Real. |
| `id` | `apple-foundation-model`, `apple-image-playground`, `apple-nl-embedding`, `apple-speech-transcriber`, or `apple-speech-synthesizer`. Real. |
| `created` | Always 0. Placeholder. |
| `owned_by` | Always `apple`. |

## Chat completions

`POST /v1/chat/completions` uses Foundation Models.

| Parameter | Behavior |
| --- | --- |
| `messages` | Supported. `system` and `developer` messages become instructions. The last message other than those must be a `user` message, or the request is a 400. Earlier `user` and `assistant` messages become the transcript. |
| `messages[].content` | Supported as a string or as content parts. `text` and `refusal` parts are text. `image_url` parts are supported only in `user` messages, only as base64 `data:image/...;base64,` URLs, and only when the model on this Mac accepts images (macOS 27 with the vision capability); otherwise they are a 400. `detail` is ignored. Other part types, such as `input_audio` and `file`, are a 400 `unsupported_value`. |
| `messages[].name` | Ignored. |
| `messages[].tool_calls`, `tool` and `function` messages | Rejected: 400 `unsupported_parameter` or `unsupported_value`. |
| `model` | See [Everything](#everything). |
| `temperature` | Supported, from 0 to 2. Other values are a 400 `invalid_value`. |
| `max_completion_tokens`, `max_tokens` | Supported as the model's maximum response tokens. `max_completion_tokens` wins if both are present. A value under 1 is a 400 `invalid_value`. |
| `n` | Supported only as 1. Other values are a 400 `unsupported_value`. |
| `stream` | Supported. |
| `stream_options.include_usage` | Supported. |
| `response_format` | `text` and `json_schema` are supported. `json_object` adds an instruction to answer with one JSON object and removes a Markdown code fence from the answer; the model is not constrained, so the JSON is not guaranteed. Other types are a 400 `invalid_value`. |
| `response_format.json_schema` | Supported for a subset of JSON Schema, which guided generation enforces: `type` (one type, optionally with `null` in object properties), `properties`, `required`, `additionalProperties: false`, `items`, `minItems`, `maxItems`, string `enum` and `const`, `pattern`, `minimum` and `maximum`, `exclusiveMinimum` and `exclusiveMaximum` for integers, `anyOf`, `oneOf`, and `$ref` to `#/$defs` or `#/definitions`. Annotations such as `title`, `description`, and `format` are ignored. Any other keyword is a 400 that names the keyword and its location. `strict` is ignored, because the schema is always enforced. |
| `tools`, `functions` | Rejected when not empty: 400 `unsupported_parameter`. |
| `tool_choice`, `function_call`, `parallel_tool_calls` | Ignored. |
| `top_p`, `stop`, `seed`, `frequency_penalty`, `presence_penalty`, `logit_bias` | Ignored. |
| `logprobs`, `top_logprobs` | Ignored. `logprobs` in the response is always `null`. |
| `modalities`, `audio`, `prediction`, `reasoning_effort`, `verbosity`, `web_search_options` | Ignored. The response is always text. |
| `store`, `metadata`, `service_tier`, `user`, `safety_identifier`, `prompt_cache_key` | Ignored. |

| Response field | Value |
| --- | --- |
| `id` | `chatcmpl-` and a random UUID. Real, but nothing can look it up later. |
| `object`, `created`, `model` | Real. `model` is `apple-foundation-model`. |
| `choices` | Always one choice, with `index` 0. |
| `choices[].message.role`, `.content` | Real. |
| `choices[].message.refusal` | Always `null`. A refusal or a guardrail violation is a 400 `content_policy_violation` instead. |
| `choices[].logprobs` | Always `null`. |
| `choices[].finish_reason` | `stop`, or `length` when the model reports token counts and the answer reached the token limit. On macOS 26, which reports no counts, it is always `stop`. Never `tool_calls` or `content_filter`. |
| `usage.prompt_tokens`, `.completion_tokens`, `.total_tokens` | The model's own counts on macOS 27. On macOS 26, an estimate of one token for every four characters. |
| `system_fingerprint`, `service_tier`, `usage.*_details` | Not present. |

A stream sends a first chunk with `role: assistant` and empty content,
then content deltas,
then a chunk with an empty delta and the `finish_reason`,
then, with `include_usage`, a chunk with empty `choices` and `usage`,
then `data: [DONE]`.
The deltas are the differences between Foundation Models' snapshots.
With `json_schema`, the whole JSON arrives as one delta at the end,
because partial JSON snapshots don't extend each other.
An error before the first event gets its own status code;
an error after it arrives as a `data:` event with OpenAI's error body,
and the stream ends without `[DONE]`.

These errors come from Foundation Models:

| Situation | Status | `code` |
| --- | --- | --- |
| The conversation exceeds the context window | 400 | `context_length_exceeded` |
| A guardrail violation or a refusal | 400 | `content_policy_violation` |
| An unsupported language or locale | 400 | `unsupported_language` |
| Rate limited, or too many requests at once | 429 | `rate_limit_exceeded` |
| The model's assets are unavailable | 503 | `service_unavailable` |
| A timeout (macOS 27) | 504 | `timeout` |

## Images

`POST /v1/images/generations` (JSON),
`POST /v1/images/edits`, and `POST /v1/images/variations` (multipart)
use Image Playground.
In the default image mode on macOS 27, every request that passes validation
returns 503 `service_unavailable`;
[images](images.md#modes) explains the modes.
The server makes one image at a time.

| Parameter | Endpoints | Behavior |
| --- | --- | --- |
| `prompt` | generations, edits | Supported and required. A prompt of more than 200 characters becomes `.extracted(from:title:)`. A missing prompt is a 400. Variations ignore it. |
| `image`, `image[]` | edits, variations | Supported and required. Exactly one image that ImageIO can read. More than one image is a 400 `invalid_value`; an unreadable image is a 400 `invalid_image`. |
| `mask` | edits | Rejected: 400 `unsupported_parameter`. |
| `model` | all | See [Everything](#everything). |
| `n` | all | Supported, from 1 to 10. Other values are a 400 `invalid_value`; a multipart value that is not an integer is a 400 `invalid_type`. |
| `style` | all | Supported: an Image Playground style, such as `animation`, `illustration`, or `sketch`, or OpenAI's `vivid` (`animation`) and `natural` (`illustration`). Other values are a 400 `invalid_value`. |
| `size` | all | Supported as a hint in the window modes on macOS 27; ignored in the default mode. `auto` or `WIDTHxHEIGHT`; other values are a 400 `invalid_value`. The image can have another size. |
| `response_format` | all | `b64_json` (default) or `url`, which is a `data:image/png;base64,` URL. Other values are a 400 `invalid_value`. |
| `quality` | generations, edits | Ignored. |
| `output_format`, `output_compression` | generations, edits | Ignored. The image is always PNG. |
| `background`, `moderation`, `input_fidelity` | generations, edits | Ignored. |
| `stream`, `partial_images` | generations, edits | Ignored. The response is never streamed. |
| `user` | all | Ignored. |

| Response field | Value |
| --- | --- |
| `created` | Real. |
| `data[].b64_json` or `data[].url` | Real PNG data. |
| `data[].revised_prompt`, `usage`, `background`, `output_format`, `quality`, `size` | Not present. |

| Situation | Status | `code` |
| --- | --- | --- |
| Images are unavailable in this mode | 503 | `service_unavailable` |
| A person cancels or closes the window | 400 | `image_generation_cancelled` |
| Nobody accepts the image before `--image-timeout` | 504 | `timeout` |

## Embeddings

`POST /v1/embeddings` uses NaturalLanguage's contextual embeddings.

| Parameter | Behavior |
| --- | --- |
| `input` | Supported: a string or an array of up to 2048 strings. An empty string or an empty array is a 400. Token arrays are a 400 `unsupported_value`. An input of more than 8192 tokens is a 400 `context_length_exceeded`. |
| `model` | See [Everything](#everything). |
| `encoding_format` | `float` (default) or `base64`. Other values are a 400 `unsupported_value`. |
| `dimensions` | Supported only as 512. Other values are a 400 `unsupported_value`. |
| `user` | Ignored. |

| Response field | Value |
| --- | --- |
| `object`, `data[].object`, `data[].index` | Real. |
| `data[].embedding` | Real: the mean of the token vectors, scaled to unit length. |
| `model` | `apple-nl-embedding`. |
| `usage.prompt_tokens`, `usage.total_tokens` | The model's own token count, including the special tokens that it adds. Not comparable with OpenAI's counts. |

## Transcriptions and translations

`POST /v1/audio/transcriptions` uses SpeechAnalyzer with SpeechTranscriber.
`POST /v1/audio/translations` transcribes,
then translates into English with the Translation framework.
Both take `multipart/form-data`.

| Parameter | Endpoints | Behavior |
| --- | --- | --- |
| `file` | both | Supported and required. Any format that `AVAudioFile` reads, such as WAV, M4A, MP3, FLAC, and Ogg Opus. Other formats, such as WebM, are a 400 `invalid_file_format`. |
| `model` | both | See [Everything](#everything). |
| `language` | both | Supported: an ISO-639-1 code or a locale. Without it, the system locale applies, because SpeechTranscriber doesn't detect the language. OpenAI's translations endpoint has no `language`; preowned accepts it there as an extension. A language that Speech can't transcribe is a 400 `unsupported_language`. |
| `response_format` | both | `json` (default), `text`, `srt`, `vtt`, or `verbose_json`. Other values, such as `diarized_json`, are a 400 `unsupported_value`. |
| `timestamp_granularities[]` | transcriptions | Supported: `segment` and `word`, with `verbose_json` only; with another format, a 400 `unsupported_value`. Translations ignore it. |
| `prompt`, `temperature` | both | Ignored. |
| `stream`, `chunking_strategy`, `include[]` | transcriptions | Ignored. The response is never streamed. |
| `known_speaker_names[]`, `known_speaker_references[]` | transcriptions | Ignored. |

| Response field | Value |
| --- | --- |
| `text` | Real. |
| `usage` (`json` and `verbose_json` transcriptions) | `{"type": "duration", "seconds": N}`, the audio's length rounded up. Real. Translations have no `usage`. |
| `task`, `duration` (`verbose_json`) | Real. |
| `language` (`verbose_json`) | The English name of the language, such as `english`. Translations always report `english`. |
| `segments[].id`, `.start`, `.end`, `.text` | Real. Each segment is one final SpeechTranscriber result. |
| `segments[].avg_logprob` | The natural logarithm of the segment's mean word confidence, or 0. |
| `segments[].compression_ratio` | Computed from the text, as Whisper does. |
| `segments[].seek`, `.tokens`, `.temperature`, `.no_speech_prob` | Placeholders: 0, `[]`, 0, and 0. |
| `words[]` | Real, with `word` granularity. Translations have no words. |
| `logprobs` | Not present. |

Missing speech models and translation languages give 503;
[embeddings and audio](embeddings-and-audio.md) explains when the server can download them.

## Speech

`POST /v1/audio/speech` uses AVSpeechSynthesizer
and returns 24 kHz mono audio.

| Parameter | Behavior |
| --- | --- |
| `input` | Supported, up to 4096 characters. An empty input is a 400. |
| `voice` | Supported: an OpenAI voice name, which maps to an installed Apple voice, or the name or identifier of an installed system voice. Other values are a 400 `invalid_value`. |
| `model` | See [Everything](#everything). |
| `response_format` | `wav`, `pcm`, `aac`, and `flac` are supported. `mp3`, the default, returns AAC in ADTS with `Content-Type: audio/aac`, because AVFoundation has no MP3 encoder. `opus` and other values are a 400 `unsupported_value`. |
| `speed` | Supported, from 0.25 to 4.0, as an approximate speaking rate. Other values are a 400 `invalid_value`. |
| `instructions` | Ignored. |
| `stream_format` | `audio` is supported. `sse` is a 400 `unsupported_value`. |

The response body is the audio,
with the `Content-Type` of the format that the server wrote:
`audio/wav`, `audio/pcm`, `audio/aac`, or `audio/flac`.
A client that saves the default response as `.mp3` gets an AAC file with the wrong extension;
ask for `aac` or `wav` to avoid that.
