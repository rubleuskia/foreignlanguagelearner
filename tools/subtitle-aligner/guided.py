"""Use rough transcription matches to bound long-book forced alignment."""
import difflib
import re


def plan_chunks(text, transcription, duration, target_seconds=60):
    book = text.split()
    words = [w for s in transcription["segments"] for w in s["words"]]
    normalize = lambda value: re.sub(r"[^\w]", "", value.lower())
    matcher = difflib.SequenceMatcher(None, [normalize(w) for w in book],
                                     [normalize(w["word"]) for w in words], autojunk=False)
    cuts = [(0, 0.0)]
    for a, b, size in matcher.get_matching_blocks():
        for offset in range(max(0, size - 3)):
            start = float(words[b + offset]["start"])
            if (a + offset > cuts[-1][0] and start - cuts[-1][1] >= target_seconds
                    and start < duration):
                cuts.append((a + offset, start))
    cuts.append((len(book), duration))
    if any(end - start > 180 for (_, start), (_, end) in zip(cuts, cuts[1:])):
        raise ValueError("Insufficient matching transcript anchors. Use shorter matching excerpts.")
    return cuts


def align_guided(model, audio_path, text, language, token_step):
    from stable_whisper.audio.utils import load_audio

    print("Transcribing to locate matching passages before alignment.", flush=True)
    transcription = model.transcribe(audio_path, language=language, fp16=False).to_dict()
    audio = load_audio(audio_path, sr=16000)
    cuts = plan_chunks(text, transcription, len(audio) / 16000)
    book = text.split()
    segments = []
    for index, ((a, start), (b, end)) in enumerate(zip(cuts, cuts[1:]), 1):
        result = model.align(audio[int(start * 16000):int(end * 16000)],
                             " ".join(book[a:b]), language=language, regroup=False,
                             remove_instant_words=False, token_step=token_step)
        if result is None:
            raise ValueError(f"Guided alignment failed in chunk {index}.")
        for segment in result.to_dict()["segments"]:
            segment["start"] += start
            segment["end"] += start
            for word in segment["words"]:
                word["start"] += start
                word["end"] += start
            segments.append(segment)
        print(f"Aligned passage {index}/{len(cuts) - 1}", flush=True)
    return {"segments": segments, "language": language,
            "guidance": {"cuts": cuts, "transcription": transcription}}
