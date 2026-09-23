"""Text normalization shared by the Proving Ground scorers.

`content()` is the text every metric is computed on. Whisper's
EnglishTextNormalizer lowercases, strips punctuation and fillers, and unifies
spellings and numbers; on top of that we collapse immediate repeats of one
to three words ("there there there is" -> "there is", "it is not it is not"
-> "it is not"). Court reporters and most human transcribers drop those
stutters, so without the collapse a verbatim engine is charged for hearing
exactly what was said.
"""

from whisper_normalizer.english import EnglishTextNormalizer

_WHISPER = EnglishTextNormalizer()


def collapse_repeats(tokens: list[str], max_n: int = 3) -> list[str]:
    out: list[str] = []
    for tok in tokens:
        out.append(tok)
        for n in range(max_n, 0, -1):
            if len(out) >= 2 * n and out[-n:] == out[-2 * n:-n]:
                del out[-n:]
                break
    return out


def content(text: str) -> str:
    return " ".join(collapse_repeats(_WHISPER(text).split()))
