#!/usr/bin/env python3
"""Align matching UTF-8 text and local audio; export app-compatible subtitles."""
import argparse
import difflib
import html
import json
import math
from pathlib import Path
import re
import shutil
import sys
import textwrap
import unicodedata

ALIGNER_CORE_VERSION = "1"
ALIGNER_WHITESPACE = ("\\u0009-\\u000d\\u001c-\\u001f\\u0020\\u0085\\u00a0\\u1680"
                      "\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000")
ALIGNER_WHITESPACE_RE = re.compile(f"[{ALIGNER_WHITESPACE}]+")

def clean_text(text):
    text = unicodedata.normalize("NFC", text.replace("\ufeff", ""))
    text = ALIGNER_WHITESPACE_RE.sub(" ", text).strip(" ")
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


def remove_engine_duplicates(data, text):
    """Remove only extra adjacent repeated tokens proven absent from the source."""
    words = [w for s in data["segments"] for w in s["words"]]
    expected = text.split()
    actual = [w["word"].strip() for w in words]
    changes = [op for op in difflib.SequenceMatcher(None, expected, actual, autojunk=False)
               .get_opcodes() if op[0] != "equal"]
    removed = set()
    for tag, _, _, start, end in changes:
        if tag != "insert" or not all(
                (i > 0 and actual[i] == actual[i - 1])
                or (i + 1 < len(actual) and actual[i] == actual[i + 1])
                for i in range(start, end)):
            return data
        removed.update(range(start, end))
    if not removed:
        return data
    corrected = dict(data)
    corrected["engine_duplicate_words"] = [dict(words[i], original_index=i) for i in sorted(removed)]
    corrected["segments"] = []
    index = 0
    for segment in data["segments"]:
        kept = [w for i, w in enumerate(segment["words"], index) if i not in removed]
        index += len(segment["words"])
        if kept:
            corrected["segments"].append(dict(segment, words=kept,
                                               text="".join(w["word"] for w in kept)))
    return corrected


def validate_words(data, text, allow_untimed=False):
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
        if start < 0 or end < start or (not allow_untimed and milliseconds(end) == milliseconds(start)):
            raise ValueError(f"Word {index + 1} has zero/negative duration. Review alignment.")
        if milliseconds(start) < previous_end:
            raise ValueError(f"Word {index + 1} overlaps the previous word. Review alignment.")
        previous_end = milliseconds(end)
    if not any(milliseconds(w["end"]) > milliseconds(w["start"]) for w in words):
        raise ValueError("Alignment has no words with positive duration.")
    return words


def make_cues(words, max_chars=42, max_duration=6.0, max_gap=0.8, offset=0.0):
    cues, group = [], []

    def body(items):
        return "".join(w["word"] for w in items).strip()

    def lines(items):
        return textwrap.wrap(body(items), width=max_chars, break_long_words=False,
                             break_on_hyphens=False)

    def flush(final=False):
        if group:
            if milliseconds(group[-1]["end"]) <= milliseconds(group[0]["start"]):
                if final:
                    if not cues:
                        raise ValueError("No positive-duration subtitle cues could be formed.")
                    cues[-1]["text"] += " " + body(group)
                    cues[-1]["end"] = max(cues[-1]["end"], milliseconds(group[-1]["end"] + offset))
                    group.clear()
                return
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
    flush(final=True)
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
    result.add_argument("--alignment-json", type=Path,
                        help="Reuse raw alignment or this utility's JSON; must match input audio/text")
    result.add_argument("--output", type=Path, required=True, help="New output directory")
    result.add_argument("--language", default="pl", help="Whisper language code (default: pl)")
    result.add_argument("--model", default="small", help="Multilingual model name or checkpoint")
    result.add_argument("--token-step", type=int, default=100,
                        help="Tokens aligned per pass, 1–442 (larger windows may reduce drift)")
    result.add_argument("--guided", action="store_true",
                        help="Use rough transcription anchors to align long audio in passages")
    result.add_argument("--allow-untimed-words", action="store_true",
                        help="Keep zero-duration words in neighboring cues and flag for review")
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
    if not 1 <= args.token_step <= 442:
        raise ValueError("--token-step must be between 1 and 442.")
    if args.text.suffix.lower() != ".txt":
        raise ValueError("--text must be a UTF-8 .txt file; extract PDFs first.")
    for path in (args.text, args.audio):
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Input is missing or empty: {path}")
    if args.output.exists():
        raise ValueError("Output directory already exists. Choose a new directory.")
    text = clean_text(args.text.read_text(encoding="utf-8-sig"))
    if not args.alignment_json and not shutil.which("ffmpeg"):
        raise ValueError("FFmpeg is missing. Install it and add it to PATH.")
    if args.alignment_json:
        cached = json.loads(args.alignment_json.read_text(encoding="utf-8"))
        data = cached.get("alignment", cached)
    else:
        try:
            import stable_whisper
        except ImportError as error:
            raise ValueError("Install requirements.txt in the utility virtual environment.") from error
        options = {"device": args.device}
        if args.model_dir:
            options["download_root"] = str(args.model_dir.resolve())
        print(f"Loading {args.model} on {args.device}; first use may download weights.", flush=True)
        model = stable_whisper.load_model(args.model, **options)
        if args.guided:
            from guided import align_guided
            data = align_guided(model, str(args.audio.resolve()), text, args.language, args.token_step)
        else:
            result = model.align(str(args.audio.resolve()), text, language=args.language,
                                 regroup=False, remove_instant_words=False, token_step=args.token_step)
            if result is None:
                raise ValueError("Alignment failed; check that the text matches the audio.")
            data = result.to_dict()
    data = remove_engine_duplicates(data, text)
    try:
        words = validate_words(data, text, args.allow_untimed_words)
    except ValueError as error:
        args.output.mkdir(parents=True, exist_ok=False)
        diagnostic = args.output / "alignment-failed.json"
        diagnostic.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                              encoding="utf-8")
        (args.output / "normalized.txt").write_text(text + "\n", encoding="utf-8")
        raise ValueError(f"{error} Raw diagnostics saved to {diagnostic}") from error
    cues = make_cues(words, args.max_chars, args.max_duration, args.max_gap, args.offset)
    untimed = [{"index": i, "word": w["word"], "time": w["start"]}
               for i, w in enumerate(words) if milliseconds(w["start"]) == milliseconds(w["end"])]
    if untimed:
        print(f"warning: {len(untimed)} words have no individual duration; review alignment.json.",
              file=sys.stderr)
    formats = ("srt", "vtt") if args.format == "both" else (args.format,)
    outputs = {f"subtitles.{fmt}": render(cues, fmt) for fmt in formats}
    if any(len(content.encode("utf-8")) >= 10_000_000 for content in outputs.values()):
        raise ValueError("Subtitles exceed the app's 10 MB limit. Process shorter chapters.")
    report = {"schema_version": 1, "language": args.language, "model": args.model,
              "token_step": args.token_step,
              "guided": args.guided or bool(data.get("guidance")),
              "reused_alignment": str(args.alignment_json) if args.alignment_json else None,
              "requires_review": bool(untimed or data.get("engine_duplicate_words")),
              "untimed_words": untimed,
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
