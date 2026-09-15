#!/usr/bin/env python3
"""Align matching UTF-8 text and local audio; export app-compatible subtitles."""
import argparse
import html
import json
import math
from pathlib import Path
import re
import shutil
import sys
import textwrap
import unicodedata


def clean_text(text):
    text = unicodedata.normalize("NFC", text.replace("\ufeff", ""))
    text = " ".join(text.split())
    if not text:
        raise ValueError("TXT is empty after whitespace normalization.")
    return text


def milliseconds(seconds):
    return round(seconds * 1000)


def timestamp(ms, separator):
    hours, rest = divmod(ms, 3600000)
    minutes, rest = divmod(rest, 60000)
    seconds, fraction = divmod(rest, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02}{separator}{fraction:03}"


def validate_words(data, text):
    """Reject missing text or unusable timings instead of silently dropping words."""
    words = [word for segment in data["segments"] for word in segment["words"]]
    if not words:
        raise ValueError("Alignment returned no words.")
    if clean_text("".join(w["word"] for w in words)) != text:
        raise ValueError("Aligned text differs from input. Review the text/audio match.")
    previous_end = 0
    for index, word in enumerate(words):
        start, end = word["start"], word["end"]
        if not all(isinstance(t, (float, int)) and math.isfinite(t) for t in (start, end)):
            raise ValueError(f"Word {index + 1} has missing or non-finite timestamps.")
        if start < 0 or milliseconds(end) <= milliseconds(start):
            raise ValueError(f"Word {index + 1} has zero/negative duration. Review alignment.")
        if milliseconds(start) < previous_end:
            raise ValueError(f"Word {index + 1} overlaps the previous word. Review alignment.")
        previous_end = milliseconds(end)
    return words


def make_cues(words, max_chars=42, max_duration=6.0, max_gap=0.8, offset=0.0):
    cues, group = [], []

    def body(items):
        return "".join(w["word"] for w in items).strip()

    def lines(items):
        return textwrap.wrap(body(items), width=max_chars, break_long_words=False,
                             break_on_hyphens=False)

    def flush():
        if group:
            cues.append({"start": milliseconds(group[0]["start"] + offset),
                         "end": milliseconds(group[-1]["end"] + offset),
                         "text": "\n".join(lines(group))})
            group.clear()

    for word in words:
        if group and (len(lines(group + [word])) > 2
                      or word["end"] - group[0]["start"] > max_duration
                      or word["start"] - group[-1]["end"] > max_gap):
            flush()
        group.append(word)
        if re.search(r'[.!?…][”’"»)]*$', word["word"].strip()):
            flush()
    flush()
    return cues


def render(cues, fmt):
    separator = "," if fmt == "srt" else "."
    blocks = ["WEBVTT"] if fmt == "vtt" else []
    for index, cue in enumerate(cues, 1):
        blocks.append(f"{index}\n{timestamp(cue['start'], separator)} --> "
                      f"{timestamp(cue['end'], separator)}\n"
                      + html.escape(cue["text"], quote=False))
    return "\n\n".join(blocks) + "\n"


def nonnegative(value):
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("must be finite and nonnegative")
    return number


def positive(value):
    number = nonnegative(value)
    if number == 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--text", type=Path, required=True, help="Matching UTF-8 TXT")
    result.add_argument("--audio", type=Path, required=True, help="Local audio file")
    result.add_argument("--output", type=Path, required=True, help="New output directory")
    result.add_argument("--language", default="pl", help="Whisper language code (default: pl)")
    result.add_argument("--model", default="small", help="Multilingual model name or checkpoint")
    result.add_argument("--device", choices=["cpu", "cuda"], default="cpu")
    result.add_argument("--model-dir", type=Path, help="Model download/cache directory")
    result.add_argument("--format", choices=["srt", "vtt", "both"], default="both")
    result.add_argument("--max-chars", type=int, default=42, help="Target line width")
    result.add_argument("--max-duration", type=positive, default=6.0, help="Target cue seconds")
    result.add_argument("--max-gap", type=nonnegative, default=0.8, help="Split at longer pauses")
    result.add_argument("--offset", type=nonnegative, default=0.0, help="Seconds added to subtitles")
    return result


def run(args):
    if args.max_chars < 1:
        raise ValueError("--max-chars must be positive.")
    if args.text.suffix.lower() != ".txt":
        raise ValueError("--text must be a UTF-8 .txt file; extract PDFs first.")
    for path in (args.text, args.audio):
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Input is missing or empty: {path}")
    if args.output.exists():
        raise ValueError("Output directory already exists. Choose a new directory.")
    text = clean_text(args.text.read_text(encoding="utf-8-sig"))
    if not shutil.which("ffmpeg"):
        raise ValueError("FFmpeg is missing. Install it and add it to PATH.")
    try:
        import stable_whisper
    except ImportError as error:
        raise ValueError("Install requirements.txt in the utility virtual environment.") from error
    options = {"device": args.device}
    if args.model_dir:
        options["download_root"] = str(args.model_dir.resolve())
    print(f"Loading {args.model} on {args.device}; first use may download weights.", flush=True)
    model = stable_whisper.load_model(args.model, **options)
    result = model.align(str(args.audio.resolve()), text, language=args.language,
                         regroup=False, remove_instant_words=False)
    if result is None:
        raise ValueError("Alignment failed; check that the text matches the audio.")
    data = result.to_dict()
    try:
        words = validate_words(data, text)
    except ValueError as error:
        args.output.mkdir(parents=True, exist_ok=False)
        diagnostic = args.output / "alignment-failed.json"
        diagnostic.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                              encoding="utf-8")
        (args.output / "normalized.txt").write_text(text + "\n", encoding="utf-8")
        raise ValueError(f"{error} Raw diagnostics saved to {diagnostic}") from error
    cues = make_cues(words, args.max_chars, args.max_duration, args.max_gap, args.offset)
    formats = ("srt", "vtt") if args.format == "both" else (args.format,)
    outputs = {f"subtitles.{fmt}": render(cues, fmt) for fmt in formats}
    if any(len(content.encode("utf-8")) >= 10_000_000 for content in outputs.values()):
        raise ValueError("Subtitles exceed the app's 10 MB limit. Process shorter chapters.")
    report = {"schema_version": 1, "language": args.language, "model": args.model,
              "offset_seconds": args.offset, "word_timestamps": "relative to input audio",
              "cue_timestamps": "milliseconds including offset", "cues": cues,
              "alignment": data}
    outputs["alignment.json"] = json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    outputs["normalized.txt"] = text + "\n"
    args.output.mkdir(parents=True, exist_ok=False)
    for name, content in outputs.items():
        (args.output / name).write_text(content, encoding="utf-8")
    print(f"Wrote {len(cues)} cues / {len(words)} words to {args.output.resolve()}")
    print("Review timing against narration before importing into the app.")


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        run(args)
    except (ValueError, OSError, RuntimeError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
