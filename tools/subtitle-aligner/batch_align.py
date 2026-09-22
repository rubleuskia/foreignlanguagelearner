#!/usr/bin/env python3
"""Align a manifest-defined multi-track audiobook without inventing text boundaries."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

import align

FORMAT = "foreign-language-learner.book"
SCHEMA_VERSION = 1
NORMALIZATION = "aligner-nfc-whitespace-v1"
ALLOWED_TOP = {"format", "schemaVersion", "title", "sourceLanguage", "transcript", "tracks", "textMapping"}
ALLOWED_TRACK = {"id", "title", "audio", "alignmentStatus", "subtitle", "textRange"}
ALLOWED_MAPPING = {"normalization", "normalizedSHA256", "wordCount"}
ALLOWED_RANGE = {"startWord", "endWord"}


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(root, value, extensions=None):
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise ValueError(f"Unsafe relative path: {value!r}")
    path = Path(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"Unsafe relative path: {value!r}")
    if len(path.parts[0]) >= 2 and path.parts[0][0].isalpha() and path.parts[0][1] == ":":
        raise ValueError(f"Windows drive paths are not allowed: {value!r}")
    if extensions and path.suffix.lower() not in extensions:
        raise ValueError(f"Unsupported file extension: {value}")
    resolved = (root / path).resolve()
    if resolved == root.resolve() or root.resolve() not in resolved.parents:
        raise ValueError(f"Path leaves the manifest directory: {value}")
    return resolved


def reject_unknown(value, allowed, context):
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ValueError(f"Unknown {context} field(s): {', '.join(unknown)}")


def load_manifest(path):
    if not path.is_file() or path.name != "manifest.json":
        raise ValueError("--manifest must be an unpacked book manifest.json.")
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("Manifest exceeds 1 MiB.")
    root = path.parent.resolve()
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("Manifest root must be an object.")
    reject_unknown(manifest, ALLOWED_TOP, "manifest")
    if manifest.get("format") != FORMAT or manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError("Unsupported book format or schema version.")
    if not isinstance(manifest.get("title"), str) or not manifest["title"].strip():
        raise ValueError("Manifest title is required.")
    language = manifest.get("sourceLanguage")
    if not isinstance(language, str) or not language or not language.isascii() or len(language) > 64:
        raise ValueError("sourceLanguage must be nonempty ASCII under 65 bytes.")
    transcript_path = safe_path(root, manifest.get("transcript"), {".txt"})
    if not transcript_path.is_file() or not 0 < transcript_path.stat().st_size <= 10_000_000:
        raise ValueError("Transcript must be nonempty and no larger than 10 MB.")
    normalized = align.clean_text(transcript_path.read_text(encoding="utf-8-sig"))
    words = normalized.split(" ")
    mapping = manifest.get("textMapping")
    if not isinstance(mapping, dict):
        raise ValueError("Batch alignment requires textMapping.")
    reject_unknown(mapping, ALLOWED_MAPPING, "textMapping")
    expected_hash = sha256_bytes(normalized.encode("utf-8"))
    if mapping != {"normalization": NORMALIZATION, "normalizedSHA256": expected_hash,
                    "wordCount": len(words)}:
        raise ValueError("textMapping does not match the normalized transcript bytes and word count.")
    tracks = manifest.get("tracks")
    if not isinstance(tracks, list) or not 1 <= len(tracks) <= 100:
        raise ValueError("Manifest must contain 1–100 tracks.")
    seen_ids, seen_audio, expected_start = set(), set(), 0
    prepared = []
    for index, track in enumerate(tracks):
        if not isinstance(track, dict):
            raise ValueError(f"Track {index + 1} must be an object.")
        reject_unknown(track, ALLOWED_TRACK, f"track {index + 1}")
        identifier = track.get("id")
        if (not isinstance(identifier, str) or not identifier or len(identifier) > 64
                or any(not (c.isascii() and (c.isalnum() or c in "_-")) for c in identifier)
                or identifier in seen_ids):
            raise ValueError(f"Invalid or duplicate track ID at index {index + 1}.")
        seen_ids.add(identifier)
        audio_path = safe_path(root, track.get("audio"), {".mp3", ".m4a", ".wav"})
        if not audio_path.is_file() or audio_path.stat().st_size == 0:
            raise ValueError(f"Missing or empty audio for track {identifier}.")
        audio_key = str(audio_path).casefold()
        if audio_key in seen_audio:
            raise ValueError("Audio paths must be unique.")
        seen_audio.add(audio_key)
        text_range = track.get("textRange")
        if not isinstance(text_range, dict):
            raise ValueError(f"Track {identifier} requires textRange.")
        reject_unknown(text_range, ALLOWED_RANGE, f"track {identifier} textRange")
        start, end = text_range.get("startWord"), text_range.get("endWord")
        if type(start) is not int or type(end) is not int or start != expected_start or not start < end <= len(words):
            raise ValueError(f"Track {identifier} textRange is not contiguous and valid.")
        expected_start = end
        prepared.append({"manifest": track, "audio": audio_path,
                         "text": " ".join(words[start:end]), "start": start, "end": end})
    if expected_start != len(words):
        raise ValueError("Track ranges do not cover the full normalized transcript.")
    return root, manifest, transcript_path, normalized, prepared


def fingerprint(track, args, model_digest):
    parameters = {"language": args.language, "model": args.model, "token_step": args.token_step,
                  "guided": args.guided, "allow_untimed_words": args.allow_untimed_words,
                  "format": args.format, "max_chars": args.max_chars,
                  "max_duration": args.max_duration, "max_gap": args.max_gap}
    return {
        "audio_sha256": sha256_bytes(track["audio"].read_bytes()),
        "normalized_slice_sha256": sha256_bytes(track["text"].encode("utf-8")),
        "language": args.language,
        "model_weights_digest": model_digest,
        "core_version": align.ALIGNER_CORE_VERSION,
        "parameters_sha256": sha256_bytes(json.dumps(parameters, sort_keys=True).encode("utf-8")),
    }


def model_identity_digest(model_name, stable_whisper):
    version = getattr(stable_whisper, "__version__", "unknown")
    return sha256_bytes(f"stable-whisper:{version}:model:{model_name}".encode("utf-8"))


def model_weights_digest(model, fallback):
    """Hash actual loaded parameters when the backend exposes a PyTorch-style state_dict."""
    state_dict = getattr(model, "state_dict", None)
    if not callable(state_dict):
        return fallback
    digest = hashlib.sha256()
    for name, tensor in sorted(state_dict().items()):
        digest.update(name.encode("utf-8"))
        value = tensor.detach().cpu().contiguous()
        digest.update(str(value.dtype).encode("ascii"))
        digest.update(json.dumps(list(value.shape)).encode("ascii"))
        digest.update(value.numpy().tobytes())
    return digest.hexdigest()


def probe_audio(path):
    process = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True, check=False)
    if process.returncode:
        raise ValueError(f"Audio metadata check failed for {path.name}: {process.stderr.strip()}")
    try:
        duration = float(process.stdout.strip())
    except ValueError as error:
        raise ValueError(f"Audio duration is missing for {path.name}.") from error
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError(f"Audio duration is invalid for {path.name}.")
    return duration


def perform_alignment(model, track, args):
    if args.guided:
        from guided import align_guided
        data = align_guided(model, str(track["audio"]), track["text"], args.language, args.token_step)
    else:
        result = model.align(str(track["audio"]), track["text"], language=args.language,
                             regroup=False, remove_instant_words=False, token_step=args.token_step)
        if result is None:
            raise ValueError("Alignment failed; check that text matches audio.")
        data = result.to_dict()
    data = align.remove_engine_duplicates(data, track["text"])
    words = align.validate_words(data, track["text"], args.allow_untimed_words)
    cues = align.make_cues(words, args.max_chars, args.max_duration, args.max_gap, 0)
    untimed = [{"index": i, "word": word["word"], "time": word["start"]}
               for i, word in enumerate(words)
               if align.milliseconds(word["start"]) == align.milliseconds(word["end"])]
    review = bool(untimed or data.get("engine_duplicate_words"))
    return data, cues, untimed, review


def write_track_output(directory, track, data, cues, untimed, review, fingerprint_value, args):
    directory.mkdir(parents=True, exist_ok=False)
    formats = ("srt", "vtt") if args.format == "both" else (args.format,)
    for fmt in formats:
        (directory / f"subtitles.{fmt}").write_text(align.render(cues, fmt), encoding="utf-8")
    report = {"schema_version": 1, "track_id": track["manifest"]["id"],
              "status": "review-required" if review else "aligned",
              "fingerprint": fingerprint_value, "untimed_words": untimed,
              "cue_timestamps": "local milliseconds", "cues": cues, "alignment": data}
    (directory / "alignment.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    (directory / "normalized.txt").write_text(track["text"] + "\n", encoding="utf-8")
    return report


def validate_reuse(previous, track, expected_fingerprint, destination):
    track_id = track["manifest"]["id"]
    source = previous / "tracks" / track_id
    report_path = source / "alignment.json"
    if not report_path.is_file():
        return None
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("status") not in ("aligned", "review-required") or report.get("fingerprint") != expected_fingerprint:
        return None
    if not (source / "subtitles.srt").is_file():
        return None
    shutil.copytree(source, destination)
    return report


def publish_book(output, root, manifest, transcript, prepared, reports):
    book = output / "book"
    (book / "audio").mkdir(parents=True)
    (book / "subtitles").mkdir(parents=True)
    shutil.copy2(transcript, book / "transcript.txt")
    final_tracks = []
    for track, report in zip(prepared, reports):
        identifier = track["manifest"]["id"]
        audio_name = f"audio/{identifier}{track['audio'].suffix.lower()}"
        subtitle_name = f"subtitles/{identifier}.srt"
        shutil.copy2(track["audio"], book / audio_name)
        shutil.copy2(output / "tracks" / identifier / "subtitles.srt", book / subtitle_name)
        final_track = {"id": identifier, "title": track["manifest"]["title"],
                       "audio": audio_name, "alignmentStatus": report["status"],
                       "subtitle": subtitle_name, "textRange": track["manifest"]["textRange"]}
        final_tracks.append(final_track)
    final_manifest = dict(manifest)
    final_manifest["transcript"] = "transcript.txt"
    final_manifest["tracks"] = final_tracks
    (book / "manifest.json").write_text(
        json.dumps(final_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    archive_path = output / "book.book.zip"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for path in sorted(book.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(book).as_posix())


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--previous-output", type=Path)
    result.add_argument("--track-id")
    result.add_argument("--language", help="Must match manifest sourceLanguage")
    result.add_argument("--model", default="small")
    result.add_argument("--token-step", type=int, default=100)
    result.add_argument("--guided", action="store_true")
    result.add_argument("--allow-untimed-words", action="store_true")
    result.add_argument("--device", choices=["cpu", "cuda"], default="cpu")
    result.add_argument("--model-dir", type=Path)
    result.add_argument("--format", choices=["srt", "both"], default="srt")
    result.add_argument("--max-chars", type=int, default=42)
    result.add_argument("--max-duration", type=align.positive, default=6.0)
    result.add_argument("--max-gap", type=align.nonnegative, default=0.8)
    return result


def run(args, model_loader=None, aligner=perform_alignment):
    if args.output.exists():
        raise ValueError("Output directory already exists. Choose a new directory.")
    if not 1 <= args.token_step <= 442 or args.max_chars < 1:
        raise ValueError("Invalid grouping parameters.")
    root, manifest, transcript, _, prepared = load_manifest(args.manifest)
    args.language = args.language or manifest["sourceLanguage"]
    if args.language != manifest["sourceLanguage"]:
        raise ValueError("--language must match manifest sourceLanguage for reproducible reruns.")
    track_ids = [track["manifest"]["id"] for track in prepared]
    if (args.previous_output is None) != (args.track_id is None):
        raise ValueError("--previous-output and --track-id must be supplied together.")
    if args.track_id and args.track_id not in track_ids:
        raise ValueError(f"Unknown --track-id {args.track_id}.")
    if not shutil.which("ffmpeg") and model_loader is None:
        raise ValueError("FFmpeg is missing. Install it and add it to PATH.")
    try:
        import stable_whisper
    except ImportError as error:
        if model_loader is None:
            raise ValueError("Install requirements.txt in the utility virtual environment.") from error
        stable_whisper = type("Stub", (), {"__version__": "test"})
    if model_loader is None:
        for track in prepared:
            probe_audio(track["audio"])
        options = {"device": args.device}
        if args.model_dir:
            options["download_root"] = str(args.model_dir.resolve())
        print(f"Loading {args.model} on {args.device}; first use may download weights.", flush=True)
        model = stable_whisper.load_model(args.model, **options)
    else:
        model = model_loader(args)
    identity_digest = model_identity_digest(args.model, stable_whisper)
    digest = model_weights_digest(model, identity_digest)
    fingerprints = {track["manifest"]["id"]: fingerprint(track, args, digest) for track in prepared}

    reused = {}
    if args.previous_output:
        missing = []
        temporary = args.output.parent / f".{args.output.name}-reuse-check"
        if temporary.exists():
            shutil.rmtree(temporary)
        temporary.mkdir()
        try:
            for track in prepared:
                identifier = track["manifest"]["id"]
                if identifier == args.track_id:
                    continue
                destination = temporary / identifier
                report = validate_reuse(args.previous_output, track, fingerprints[identifier], destination)
                if report is None:
                    missing.append(identifier)
                else:
                    reused[identifier] = (destination, report)
            if missing:
                raise ValueError("Previous output cannot be reused; process track IDs: " + ", ".join(missing))
            args.output.mkdir(parents=True)
            (args.output / "tracks").mkdir()
            for identifier, (source, report) in reused.items():
                shutil.move(str(source), args.output / "tracks" / identifier)
                reused[identifier] = (args.output / "tracks" / identifier, report)
        finally:
            shutil.rmtree(temporary, ignore_errors=True)
    else:
        args.output.mkdir(parents=True)
        (args.output / "tracks").mkdir()

    selected = [track for track in prepared if not args.track_id or track["manifest"]["id"] == args.track_id]
    results = dict((identifier, report) for identifier, (_, report) in reused.items())
    failures = []
    for track in selected:
        identifier = track["manifest"]["id"]
        directory = args.output / "tracks" / identifier
        try:
            data, cues, untimed, review = aligner(model, track, args)
            results[identifier] = write_track_output(directory, track, data, cues, untimed, review,
                                                     fingerprints[identifier], args)
        except (ValueError, OSError, RuntimeError, KeyError, TypeError) as error:
            directory.mkdir(parents=True, exist_ok=True)
            failure = {"schema_version": 1, "track_id": identifier, "status": "failed",
                       "error": f"{type(error).__name__}: {error}",
                       "fingerprint": fingerprints[identifier]}
            (directory / "alignment-failed.json").write_text(
                json.dumps(failure, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            results[identifier] = failure
            failures.append(identifier)

    ordered_reports = [results[identifier] for identifier in track_ids]
    report = {"schema_version": 1, "manifest_sha256": sha256_bytes(args.manifest.read_bytes()),
              "tracks": ordered_reports, "failed_track_ids": failures}
    (args.output / "batch-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if failures:
        print("error: alignment failed for track IDs: " + ", ".join(failures), file=sys.stderr)
        return 1
    publish_book(args.output, root, manifest, transcript, prepared, ordered_reports)
    print(f"Aligned {len(prepared)} tracks and wrote {args.output / 'book.book.zip'}")
    return 0


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return run(args)
    except (ValueError, OSError, RuntimeError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
