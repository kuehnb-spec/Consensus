# Proving Ground

A zero-hand-editing accuracy benchmark: public audio with speaker-attributed,
time-stamped reference transcripts, every engine run over it, one score table.
Started 2026-09-23; first results in `TestCorpus/results-2026-09-23.md`.

Corpus data lives in `TestCorpus/` at the repo root (git-ignored, re-fetchable).
Scripts run from the repo root with the benchmark venv:

```bash
/opt/homebrew/bin/python3.13 -m venv Scripts/.venv
Scripts/.venv/bin/pip install jiwer meeteval whisper-normalizer

# 1. Build clips (10-min windows with the most speaker changes)
Scripts/.venv/bin/python Scripts/proving-ground/fetch_oyez.py --out TestCorpus/oyez --term 2020 --count 3

# 2. Run engines (needs fluidaudiocli >= 0.17.0 and the installed `consensus` CLI)
FLUIDAUDIO_CLI=/path/to/fluidaudiocli Scripts/proving-ground/run_engines.sh TestCorpus/oyez

# 3. Pair one engine's words with another's speakers
Scripts/.venv/bin/python Scripts/proving-ground/combine_words_speakers.py \
    --words TestCorpus/runs/vibevoice --speakers TestCorpus/runs/nemotron3-offline \
    --out TestCorpus/runs/vibevoice+nemotron3-offline

# 4. Score (content WER, cpWER, DER)
Scripts/.venv/bin/python Scripts/proving-ground/score_corpus.py --corpus TestCorpus/oyez \
    --run vibevoice=TestCorpus/runs/vibevoice --run vv+nemo=TestCorpus/runs/vibevoice+nemotron3-offline

# 5. Audit the references: turns where independent engines agree with each
#    other but not with the reference go on a listen-list with snippets
Scripts/.venv/bin/python Scripts/proving-ground/audit_reference.py --corpus TestCorpus/oyez \
    --witness vibevoice=TestCorpus/runs/vibevoice --witness parakeet=TestCorpus/runs/parakeet \
    --out TestCorpus/oyez/_audit
```

## Why Supreme Court arguments

Public-domain federal audio; words from the Court's official reporter; Oyez has
aligned every turn with a named speaker (Oyez curation is CC BY-NC 4.0, so the
data stays local and evaluation-only). Legal register, 6–10 speakers per clip,
the same justices recur across recordings, and the 2020 term was argued by
telephone. The references are clean verbatim (no fillers or stutters), so every
metric runs on `pg_text.content()`, which drops fillers and collapses repeats on
both sides.

## Known quirks

- Oyez turn timing drifts on 1990s recordings; the audit surfaces those turns.
- Turns are sequential, so cross-talk is unmarked; DER uses a 0.25 s collar.
- Raw diarizer DER shows high "missed" time because Oyez turns span the short
  pauses between sentences. Compare diarizers on speaker confusion, or pair them
  with an ASR's words and compare cpWER.
- Oyez docket numbers can carry stray whitespace; the fetcher strips it.

## Next corpora

Earnings-21 (Rev, CC BY-SA text + RTTM, 44 calls; token references have no
timestamps, so score whole files ≤ 60 min with cpWER), AMI (CC BY 4.0), and a
synthetic stress lab with known overlap and phone-codec filtering.
