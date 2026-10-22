# /// script
# requires-python = "==3.14.*"
# dependencies = [
#     "openai>=2,<3",
# ]
# ///
"""Smoke-test a running preowned server with the official OpenAI Python SDK.

Start the server first, for example with `preowned serve`,
then run `uv run Scripts/smoke.py --base-url http://127.0.0.1:8027/v1`.
The script expects the default image mode,
in which images are unavailable on macOS 27 and the endpoint returns 503.
It exits with status 1 if any check fails.
"""

import argparse
import json
import math
import sys
import time
from collections.abc import Callable

import openai
from openai import OpenAI

CHAT_MODEL = "apple-foundation-model"
IMAGE_MODEL = "apple-image-playground"
EMBEDDING_MODEL = "apple-nl-embedding"
TRANSCRIPTION_MODEL = "apple-speech-transcriber"
SPEECH_MODEL = "apple-speech-synthesizer"

SPOKEN_TEXT = "The quick brown fox jumps over the lazy dog."


def check_models(client: OpenAI) -> str:
    ids = sorted(model.id for model in client.models.list())
    expected = {CHAT_MODEL, EMBEDDING_MODEL, TRANSCRIPTION_MODEL, SPEECH_MODEL}
    missing = expected - set(ids)
    assert not missing, f"missing models: {sorted(missing)}"
    assert IMAGE_MODEL not in ids, (
        f"{IMAGE_MODEL} is listed, but the default image mode should leave it out"
    )
    return ", ".join(ids)


def check_chat(client: OpenAI) -> str:
    completion = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "Answer in one short sentence."},
            {"role": "user", "content": "What color is a ripe banana?"},
        ],
        max_completion_tokens=64,
    )
    assert completion.object == "chat.completion"
    assert completion.model == CHAT_MODEL, f"model is {completion.model}"
    choice = completion.choices[0]
    assert choice.message.role == "assistant"
    assert choice.message.content, "empty content"
    assert choice.finish_reason in ("stop", "length"), (
        f"finish_reason is {choice.finish_reason}"
    )
    assert completion.usage and completion.usage.completion_tokens > 0
    return f"{choice.message.content!r} ({completion.usage.total_tokens} tokens)"


def check_chat_stream(client: OpenAI) -> str:
    stream = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "user", "content": "Count from 1 to 5, separated by commas."}
        ],
        stream=True,
        stream_options={"include_usage": True},
    )
    text = ""
    chunks = 0
    finish_reason = None
    usage = None
    for chunk in stream:
        chunks += 1
        assert chunk.object == "chat.completion.chunk"
        if chunk.usage:
            usage = chunk.usage
        for choice in chunk.choices:
            text += choice.delta.content or ""
            finish_reason = choice.finish_reason or finish_reason
    assert text, "no content in the stream"
    assert finish_reason in ("stop", "length"), f"finish_reason is {finish_reason}"
    assert usage is not None, "no usage chunk"
    return f"{text!r} in {chunks} chunks"


def check_structured_output(client: OpenAI) -> str:
    schema = {
        "type": "object",
        "properties": {
            "name": {"type": "string"},
            "wheels": {"type": "integer", "minimum": 0, "maximum": 18},
            "condition": {"type": "string", "enum": ["new", "used"]},
        },
        "required": ["name", "wheels", "condition"],
        "additionalProperties": False,
    }
    completion = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": "Describe a used family station wagon."}],
        response_format={
            "type": "json_schema",
            "json_schema": {"name": "vehicle", "schema": schema, "strict": True},
        },
    )
    content = completion.choices[0].message.content or ""
    vehicle = json.loads(content)
    assert set(vehicle) == {"name", "wheels", "condition"}, (
        f"keys are {sorted(vehicle)}"
    )
    assert isinstance(vehicle["name"], str)
    assert isinstance(vehicle["wheels"], int) and 0 <= vehicle["wheels"] <= 18
    assert vehicle["condition"] in ("new", "used")
    return content


def check_embeddings(client: OpenAI) -> str:
    texts = [
        "The car has low mileage and new tires.",
        "This vehicle was driven very little and its tires are new.",
        "Bake the bread for forty minutes.",
    ]
    response = client.embeddings.create(model="text-embedding-3-small", input=texts)
    assert response.model == EMBEDDING_MODEL, f"model is {response.model}"
    vectors = [
        item.embedding for item in sorted(response.data, key=lambda item: item.index)
    ]
    assert len(vectors) == 3
    dimensions = {len(vector) for vector in vectors}
    assert dimensions == {512}, f"dimensions are {dimensions}"
    for vector in vectors:
        norm = math.sqrt(sum(value * value for value in vector))
        assert abs(norm - 1) < 1e-3, f"norm is {norm}"

    def cosine(a: list[float], b: list[float]) -> float:
        return sum(x * y for x, y in zip(a, b))

    paraphrase = cosine(vectors[0], vectors[1])
    unrelated = cosine(vectors[0], vectors[2])
    assert paraphrase > unrelated, (
        f"paraphrase {paraphrase:.3f} <= unrelated {unrelated:.3f}"
    )
    return f"512 dimensions; paraphrase {paraphrase:.3f}, unrelated {unrelated:.3f}"


def check_speech_mp3(client: OpenAI) -> str:
    response = client.audio.speech.with_raw_response.create(
        model="tts-1",
        voice="alloy",
        input="Sold as is.",
        response_format="mp3",
    )
    content_type = response.headers.get("content-type")
    assert content_type == "audio/aac", f"Content-Type is {content_type}"
    data = response.content
    # An ADTS frame starts with the 12-bit sync word 0xFFF.
    assert len(data) > 2 and data[0] == 0xFF and data[1] & 0xF0 == 0xF0, (
        "not an ADTS stream"
    )
    return f"{len(data)} bytes of {content_type}"


def check_speech_round_trip(client: OpenAI) -> str:
    speech = client.audio.speech.create(
        model="tts-1",
        voice="alloy",
        input=SPOKEN_TEXT,
        response_format="wav",
    )
    audio = speech.read()
    assert audio[:4] == b"RIFF" and audio[8:12] == b"WAVE", "not a WAV file"

    transcription = client.audio.transcriptions.create(
        model="whisper-1",
        file=("speech.wav", audio, "audio/wav"),
        language="en",
    )
    text = transcription.text
    words = {word.strip(".,!?").lower() for word in text.split()}
    expected = {"quick", "brown", "fox", "lazy", "dog"}
    missing = expected - words
    assert not missing, f"transcript {text!r} is missing {sorted(missing)}"
    return f"{len(audio)} bytes of WAV, transcribed as {text!r}"


def check_images_unavailable(client: OpenAI) -> str:
    try:
        client.images.generate(
            model="dall-e-3", prompt="A red station wagon on a sunny lot"
        )
    except openai.InternalServerError as error:
        assert error.status_code == 503, f"status is {error.status_code}"
        body = error.body if isinstance(error.body, dict) else {}
        assert body.get("code") == "service_unavailable", f"body is {error.body}"
        assert body.get("type") == "server_error", f"body is {error.body}"
        return f"{type(error).__name__} {error.status_code}: {body.get('message')}"
    raise AssertionError(
        "images.generate succeeded, but the default image mode should return 503"
    )


CHECKS: list[tuple[str, Callable[[OpenAI], str]]] = [
    ("models.list", check_models),
    ("chat.completions", check_chat),
    ("chat.completions stream", check_chat_stream),
    ("chat.completions json_schema", check_structured_output),
    ("embeddings", check_embeddings),
    ("audio.speech mp3", check_speech_mp3),
    ("audio.speech then audio.transcriptions", check_speech_round_trip),
    ("images.generate (503 expected)", check_images_unavailable),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-url", default="http://127.0.0.1:8027/v1")
    parser.add_argument(
        "--api-key",
        default="sk-preowned",
        help="Any key works unless the server has --api-key.",
    )
    arguments = parser.parse_args()

    client = OpenAI(
        base_url=arguments.base_url,
        api_key=arguments.api_key,
        max_retries=0,
        timeout=300,
    )
    print(
        f"openai {openai.__version__}, Python {sys.version.split()[0]}, {arguments.base_url}"
    )

    failures = 0
    for name, check in CHECKS:
        start = time.monotonic()
        try:
            detail = check(client)
        except Exception as error:  # noqa: BLE001 -- report every failure and run the other checks
            failures += 1
            print(
                f"FAIL  {name} ({time.monotonic() - start:.1f} s): {type(error).__name__}: {error}"
            )
        else:
            print(f"PASS  {name} ({time.monotonic() - start:.1f} s): {detail}")

    print(f"{len(CHECKS) - failures} of {len(CHECKS)} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
