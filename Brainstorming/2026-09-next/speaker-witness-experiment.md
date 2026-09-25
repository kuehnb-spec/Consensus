# Does Nemotron 3 help as a speaker witness? (2026-09-25)

Question (Brant): VibeVoice stays primary, but if Nemotron 3 Diarization is added
as a discrepancy witness, does resolving the disagreements lower cpWER?

Corpus: Proving Ground Oyez set, 15 clips, 149 min, 6–10 speakers, 25,503
VibeVoice words. Scripts: `Scripts/proving-ground/experiment_speaker_witness.py`,
`experiment_voice_match.py`. Word-level truth comes from aligning each word's
TEXT to the reference; an earlier version used Oyez timestamps and was wrong
(turn timing drifts by a second or more on some clips, which made a "perfect"
oracle look worse on cpWER while improving DER against the same drifted clock).

| | cpWER |
|---|---:|
| VibeVoice alone | 8.18% |
| Oracle: resolve every Nemotron/community-1 flag perfectly (ceiling) | 7.45% |
| Majority vote, VibeVoice + Nemotron + community-1 | 10.48% |
| Majority vote, only when most of a segment is contested | 9.58% |
| Voice match, community-1 segment embeddings | 9.21% |
| Voice match, CAM++ on the exact disputed span, margin 0.15 | 8.28% |

- VibeVoice credits 2.15% of words to the wrong speaker; cpWER−WER is 2.7 pts.
- Nemotron disagrees on 4.6% of words and catches 37% of those errors, but it is
  right in only 8–13% of its disputes (≈27 disputes per 10 min, ≈3 real).
- The two acoustic diarizers fail together (both merge similar voices), so a
  2-of-3 vote overrules VibeVoice when it was right: 59 words fixed, 413 broken.
- Half of VibeVoice's wrong-speaker words sit in long runs (whole sentences
  credited to the wrong justice); Nemotron flags only 24% of those.

Verdict on this corpus: the witness idea is sound (the ceiling is a 9% relative
cpWER cut) but no automatic resolver tested captures it, and as a review signal
it is ~1 real catch per 9 flags. Caveat: 6–10 similar voices is Nemotron's worst
case. Next: rerun on 2–3-speaker audio (Brant's gold files, not on the Studio;
or AMI), try Nemotron's frame probabilities as a confidence gate, and try a
conversational-sense judge (an LLM reading only the disputed lines) for the
long whole-sentence misattributions.
