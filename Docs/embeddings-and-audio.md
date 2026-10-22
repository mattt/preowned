# Embeddings and audio

This page records how preowned serves embeddings, transcriptions,
translations, and speech, and why.
The measurements come from a Mac with macOS 27.0.1 on 2026-10-22.

## Embeddings

`POST /v1/embeddings` uses NaturalLanguage's `NLContextualEmbedding`
and reports the model `apple-nl-embedding`.

NaturalLanguage has two text embeddings.
`NLEmbedding.sentenceEmbedding(for:)` exists on macOS 27.0.1
only for English (512 dimensions)
and for French, German, Italian, and Spanish (640 dimensions),
so one model ID would return vectors of two sizes,
and it reports no token counts.
`NLContextualEmbedding` has one model for each script,
each with 512 dimensions.
The Latin-script model covers 20 languages in one vector space:
cs, da, de, en, es, fi, fr, hr, hu, id, it, nb, nl, pl, pt, ro, sk, sv, tr, and vi.
Other models cover Cyrillic, Chinese, Japanese, and Korean,
Arabic, the Indic scripts, and Thai.
`preowned inventory` lists each model and whether it is downloaded.

The contextual embedding returns one vector for each token.
preowned averages them (mean pooling)
and scales the result to unit length, as OpenAI's vectors are,
so a dot product is the cosine similarity.
In a check of six paraphrase pairs,
both embeddings matched every sentence to its paraphrase.
Mean-pooled vectors have a high baseline:
in the checks, paraphrases scored about 0.9,
and an unrelated English sentence about 0.74,
so similarity thresholds tuned for OpenAI's models don't transfer.

| Parameter | Behavior |
| --- | --- |
| `input` | A string or an array of up to 2048 strings. Empty strings are a 400. Token arrays are a 400, because the models don't use OpenAI's tokenizer. |
| `encoding_format` | `float` (default) or `base64` (little-endian 32-bit floats). |
| `dimensions` | Accepted only if it is 512; any other value is a 400. |
| `user` | Ignored. |

The model reads at most 256 tokens at a time and drops the rest.
preowned embeds a longer input in consecutive windows
and averages the token vectors of all windows.
An input can have at most 8192 tokens, as with OpenAI;
a longer input is a 400 with the code `context_length_exceeded`.
`usage.prompt_tokens` is the model's own count,
including the special tokens that it adds to each window.

preowned picks the model by the input's dominant language.
Inputs in different scripts use different models,
so their vectors are not comparable.
A script whose model is not downloaded returns 503,
unless the server runs with `--allow-asset-downloads`,
which lets NaturalLanguage download the model on first use.

## Transcriptions

`POST /v1/audio/transcriptions` uses `SpeechAnalyzer` with `SpeechTranscriber`
and takes a `multipart/form-data` body of up to 25 MB for the file.

| Parameter | Behavior |
| --- | --- |
| `file` | Any file that `AVAudioFile` can read: WAV, AIFF, CAF, M4A, MP4 audio, AAC, MP3, FLAC, and Ogg Opus. WebM and other formats are a 400 with the code `invalid_file_format`. |
| `model` | Any name, unless the server runs with `--strict-models`. |
| `language` | An ISO-639-1 code, such as `fr`, or a locale, such as `en-GB`. Without it, the system locale applies, because SpeechTranscriber can't detect the language. |
| `prompt`, `temperature` | Ignored; SpeechTranscriber has no matching options. |
| `response_format` | `json` (default), `text`, `srt`, `vtt`, or `verbose_json`. |
| `timestamp_granularities[]` | `segment` and `word`, with `verbose_json` only. |
| `stream`, `chunking_strategy`, `include[]` | Ignored. |

A language without a region prefers the system locale's region
if the system locale has the same language,
then the language's most likely region, such as `fr-FR` for `fr`.
An installed locale wins over one that must be downloaded.
If the locale's speech model is not installed,
the request returns 503 with the message
that `--allow-asset-downloads` lets the server download it;
preowned never downloads a model without that flag.
`preowned inventory` lists the installed locales.

Each final SpeechTranscriber result is one segment.
In `verbose_json`, `language` is the English name of the language, such as `english`,
as Whisper reports it.
Speech doesn't produce Whisper's token IDs or decoder statistics,
but typed clients need the fields to decode a segment, so preowned fills them:

| Field | Value |
| --- | --- |
| `seek` | Always 0. |
| `tokens` | Always empty. |
| `temperature` | Always 0. |
| `avg_logprob` | The natural logarithm of the segment's mean word confidence from Speech, or 0 if Speech reports none. |
| `compression_ratio` | The text's UTF-8 size divided by its zlib-compressed size, as Whisper computes it. |
| `no_speech_prob` | Always 0. |

`json` and `verbose_json` include `usage` with the seconds of audio, rounded up.

## Translations

`POST /v1/audio/translations` transcribes the audio,
then translates each segment into English
with `TranslationSession(installedSource:target:)`,
which the macOS 26 SDK added and which works without a window.
It takes the same parameters as transcriptions, without timestamp granularities.
OpenAI's endpoint has no `language` parameter, because Whisper detects the language;
preowned accepts `language` as an extension,
and uses the system locale without it.
Audio in English comes back as transcribed.

That session can't download languages.
A language pair that is not installed returns 503
and names the System Settings pane where a person can add it:
General > Language & Region > Translation Languages.
`--allow-asset-downloads` does not apply to translation.

On macOS 27.0.1, a language pair can be installed for one translation strategy
and not the other.
A binary that SwiftPM builds for the macOS 26 deployment target records SDK 26.0,
and Translation then defaults to the `lowLatency` strategy,
while the installed models on the test Mac were `highFidelity`.
preowned asks for `highFidelity` first, then `lowLatency`.

## Speech

`POST /v1/audio/speech` uses `AVSpeechSynthesizer.write(_:toBufferCallback:)`,
resamples the output to 24 kHz mono, as OpenAI's audio is,
and encodes it.

| `response_format` | Result |
| --- | --- |
| `wav` | 16-bit WAV, `audio/wav`. |
| `pcm` | Raw 16-bit signed little-endian samples, `audio/pcm`. |
| `aac` | AAC in ADTS, `audio/aac`. |
| `flac` | FLAC, `audio/flac`. |
| `mp3`, or none | AAC in ADTS, `audio/aac`. |
| `opus` | 400. |

AVFoundation has no MP3 encoder,
and MP3 is OpenAI's default format,
so preowned answers `mp3` with AAC and says so in the `Content-Type`
instead of failing the default request.
A player that trusts a `.mp3` file extension, such as `afplay`, can't open the file;
FFmpeg reads the content and identifies it as AAC.
Ask for `wav` or `aac` to avoid the mismatch.
`opus` is a 400 because AVFoundation can write Opus only in CAF, not in Ogg,
and a client that asks for Opus usually hands the bytes to an Ogg Opus decoder.

`speed` from 0.25 to 4.0 maps to `AVSpeechUtterance.rate`
through a curve measured with the Samantha voice,
whose rates run from about 0.56× (rate 0) to about 4× (rate 1).
Slower speeds use rate 0.
Other voices scale differently, so the speed is approximate.
`instructions` is ignored, because the synthesizer has no prompt.
`stream_format` `sse` is a 400.
Inputs can have up to 4096 characters.

Each OpenAI voice has a list of Apple voices, chosen by gender and character.
preowned uses the first listed voice that is installed in English,
in its best installed quality, preferring `en-US`.

| OpenAI | Apple voices, in order | Gender |
| --- | --- | --- |
| alloy | Samantha, Ava, Allison | female |
| ash | Evan, Nathan, Reed | male |
| ballad | Oliver, Arthur, Grandpa | male |
| coral | Ava, Zoe, Shelley | female |
| echo | Tom, Aaron, Eddy | male |
| fable | Daniel, Arthur, Oliver | male |
| onyx | Nathan, Evan, Rocko | male |
| nova | Allison, Nicky, Sandy | female |
| sage | Susan, Kate, Flo | female |
| shimmer | Zoe, Joelle, Moira | female |
| verse | Evan, Aaron, Fred | male |

If none of the listed voices is installed,
preowned uses the best English voice of the same gender,
then the system's default English voice.
It never uses novelty voices, such as Bells, or Personal Voices.
If the input's dominant language is not English,
preowned uses a voice for that language:
the same name if it exists, as the Eloquence voices do,
then the best voice of the same gender, then any voice for the language.
A request can also name an installed system voice by its identifier or name.
Higher-quality voices download in System Settings > Accessibility > Spoken Content.
`preowned inventory` shows the voice that each OpenAI name maps to.

## Asset downloads

`preowned serve --allow-asset-downloads` lets NaturalLanguage and Speech
download the embedding and speech models that a request needs.
The first request that needs a model waits for the download.
Without the flag, such a request returns 503
with `type: server_error` and `code: service_unavailable`.
The download path was not exercised in the 2026-10-22 checks.
