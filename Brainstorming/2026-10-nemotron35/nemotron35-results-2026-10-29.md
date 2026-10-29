---
title: "Nemotron 3.5 Transcribe on the Proving Ground"
date: 2026-10-29
---

# Nemotron 3.5 Transcribe on the Proving Ground

29 October 2026

## Keep VibeVoice as primary and add Nemotron 3.5 as the word witness

Nemotron 3.5 Transcribe is the best second witness we've measured for VibeVoice, but it shouldn't replace it as primary. Used as a checker, it puts 65% of VibeVoice's word errors inside flagged spans, against 59% for Parakeet, at the same review burden (about 6% of words flagged). As primary, it trails VibeVoice on words, merges speakers, emits no timestamps on the Mac, and once in 30 runs fell into a repetition loop that wiped out most of a clip. Confidence is moderate. This is 15 clips of one kind of audio, run on a 4-bit community port of NVIDIA's early-access checkpoint.

Last night's evaluation brief said to prefer exactly this smaller change if it performed as well as a swap. On this corpus it clears that bar.

## What I ran

I ran three of the brief's five arms on the existing Proving Ground: 15 Supreme Court clips, 149 minutes, 6 to 10 speakers each, with the same scorer and normalizer as the September results. The arms were Nemotron alone, VibeVoice primary with a blind Nemotron checker, and Nemotron primary with a blind VibeVoice checker. The current-production numbers are the September VibeVoice run. I didn't run the Deep Review arm.

The model ran locally on the Mac Studio (M2 Max, 32 GB) through `mlx-audio` 0.6.3, using `nativ-community/Nemotron-3.5-Transcribe-30B-A4B-EA-4bit` (18 GB on the G-Drive SSD; checksums verified). I used two prompts: the port's speaker-attributed prompt (verbatim, with `<spk:N>` tags) and its plain verbatim prompt.

## Nemotron trails VibeVoice on words and leads as a checker

| Engine | Word error (WER) | Words and speakers (cpWER) | Diarization error (DER) |
|---|---:|---:|---:|
| VibeVoice (current) | 5.51% | 8.18% | 2.95% |
| Nemotron 3.5, speaker prompt | 6.60% | 29.82% | n/a (no timestamps) |
| Nemotron 3.5 words on VibeVoice speakers | 6.60% | 9.95% | 3.14% |
| Nemotron 3.5, plain prompt | 11.48% | n/a | n/a |
| Parakeet words on Nemotron 3 speakers (Sept.) | 7.58% | 13.63% | 6.28% |

The plain-prompt figure includes the one runaway clip. Without that clip, on the other 14, plain Nemotron scores 5.62% against VibeVoice's 5.20%, with almost the same substitution rate (1.61% against 1.55%).

As a witness:

| Primary : witness | Words flagged | Primary's errors flagged | Flags that were errors | WER if every flag were resolved |
|---|---:|---:|---:|---:|
| VibeVoice : Parakeet | 6.0% | 59.0% | 42.1% | 2.26% |
| VibeVoice : Nemotron 3.5 | 6.1% | 64.9% | 46.4% | 1.93% |
| Nemotron 3.5 : VibeVoice | 6.0% | 66.2% | 65.0% | 2.23% |

Automatic resolution helps only a little. A three-way vote (VibeVoice, Nemotron, Parakeet as tie-breaker) takes VibeVoice from 5.51% to 5.31%. Most of the gain comes from a reviewer resolving the flags.

## Four problems keep it from being primary

In speaker mode Nemotron often merges several justices into one voice: 2 labels for 6 speakers in *Tanzin v. Tanvir*, 4 for 10 in *Google v. Oracle*, both 2020 telephone arguments. On other clips it's excellent (4.1% cpWER against VibeVoice's 5.3% on the 2022 clip). That isn't dependable enough to be the record's speaker engine.

The MLX port doesn't produce word times, which the Record needs for page:line citation and re-listening. I wrote an aligner that hangs Nemotron's words on VibeVoice's clock and speakers. It works, adding only 0.2 points of DER, but it means VibeVoice runs anyway.

Its output can also run away. On one clip the plain prompt produced "the State of the State of the State of…" until the 8,192-token cap, losing about 1,600 words. A conventional recognizer like Parakeet can't fail this way. It also argues for keeping a witness in the loop whatever we choose as primary, since the witness flags every word of a span like that.

And it's big. The 4-bit model needs 18 GB of the Studio's 25 GB GPU working set. It runs only when Ollama is empty, and DealCrawler's hourly classifier (qwen3:8b, 6.3 GB) and another Ollama client (7.6 GB) keep a model loaded for much of the night. I worked around it by having the runner load Nemotron only while Ollama was idle. For anyone else's Mac, this rules out machines under 32 GB, where VibeVoice still fits.

## Some of Nemotron's extra words are probably real speech

I believe this but haven't measured it. Leaving insertions aside, Nemotron drops far fewer words than VibeVoice (485 against 769) and mishears somewhat more (534 against 439). Its insertions run three times as high (693 against 220). I checked one against the audio: at about 5:50 in the *Loper Bright Enterprises v. Raimondo* clip (22-451), Justice Gorsuch says "they get to appeal, they get to appeal" over the Solicitor General. The reporter's transcript stops at "They get a neutral judge." Nemotron caught the overlapping speech, though it misheard "neutral judge" as "new set of judges." I haven't measured how many of the 693 insertions are like that. Many are false starts ("th," "w") and backchannels ("yeah," "okay"), which a certified transcript might well keep.

Quantization may also be costing Nemotron. NVIDIA's numbers are for full precision. A different 4-bit conversion doubled errors on a small easy sample (0.38% to 0.77% WER, 522 words), so this run may understate the model.

## Once loaded, Nemotron is several times faster than VibeVoice

Once loaded, Nemotron transcribed a 10-minute clip in 32 to 45 seconds, about 16 times real time. VibeVoice took about 150 to 245 seconds on the same clips in September, and Parakeet about 3.

## What would change this answer

If a full-precision or 8-bit run beats VibeVoice on words, I'd reopen the primary question. So would a reference that keeps cross-talk, if it shows most of Nemotron's insertions are real speech. Even then, the timestamp and speaker gaps would need closing first.

## What I didn't check

Names, numbers and negations; timing drift; long silences; anything over 10 minutes (the model card caps input at an hour, and the CLI contract asks for two); reviewer time; and any audio other than Supreme Court arguments. The checkpoint is NVIDIA's early-access build, not the public release under OpenMDW-1.1, so production use would need a conversion of the public weights.

## The decision for you

May I run the same test at 8-bit or full precision on the MacBook Pro (96 GB)? It needs a 35 GB (8-bit) or roughly 68 GB (full precision) download there and about an hour of heavy GPU use.

## Files

Scripts are in `Scripts/proving-ground/` (`run_nemotron35.py`, `align_untimed_words.py`, `experiment_word_witness.py`). Run outputs are in `TestCorpus/runs/nemotron35-*` and score tables in `TestCorpus/results-2026-10-29.md` and `word-witness-2026-10-29.json` (both git-ignored, Studio only). The brief this answers is "Consensus Nemotron Transcribe evaluation brief 2026 10 29" in the Drive reading room.
