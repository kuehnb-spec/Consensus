# Consensus — Improvement Ideas

## Date: March 27, 2026

Ideas for improving the application, organized by category. Some are quick wins, some are longer-term.

---

## Output Quality

### 1. LLM Post-Processing Cleanup (High Impact, Medium Effort)
After transcription and diarization are finalized, run the local LLM (Qwen) to fix obvious transcription artifacts:
- Remove repeated words ("the the", "I I")
- Fix common misheard words using conversational context ("litigated" vs "mitigated" — the LLM knows which makes sense in a legal discussion)
- Normalize number formatting ("fourteen point eight million" → "$14.8 million")
- Fix broken sentence fragments at speaker boundaries
- Remove filler word runs (extended "um um um" sequences)

This could be an automatic step after Deep Transcription, or an optional "Polish" step in the wizard.

### 2. Punctuation Refinement
Whisper's punctuation is often wrong, especially for:
- Question marks at the end of statements (or missing question marks on actual questions)
- Period placement mid-sentence when there should be a comma
- Missing paragraph breaks in long monologues

An LLM pass specifically for punctuation would be cheap (small token count) and high-impact for readability.

### 3. Proper Noun Correction
Build a per-project dictionary of proper nouns (names, companies, legal terms) that the user enters once, then auto-correct throughout the transcript. For example, "Mr. Kirby" might be transcribed as "Mr. Curby" or "Mr. Kerby" — a dictionary entry fixes all instances.

### 4. Confidence-Based Highlighting in Exports
When exporting, optionally highlight or footnote words below a confidence threshold. In the Legal PDF, this could be italic text or a subtle underline for low-confidence words, so the reader knows which parts to verify against the audio.

---

## User Experience

### 5. Waveform Visualization
Show the audio waveform alongside the transcript, with speaker colors overlaid. Clicking a position in the waveform jumps to that point in the transcript and vice versa. This is the #1 feature request in competing apps.

### 6. Click-to-Play on Transcript Text
Click any sentence in the transcript to hear the audio for that segment. Currently only available in the flag review panels. Making it available everywhere would be hugely useful for verification.

### 7. Keyboard-Driven Speaker Correction
While reading the transcript, press a key to reassign the current segment to a different speaker. For example, press "1" to assign to Speaker 1, "2" for Speaker 2. This would let the user quickly fix diarization errors while reading.

### 8. Search Within Transcript
Full-text search within the current transcript, with highlighting and jump-to-result. Essential for long transcripts.

### 9. Undo/Redo
Currently no undo support. Speaker renames, flag resolutions, and text edits should all be undoable.

### 10. Project Templates
Save preferred settings (model, speaker count, export format, legal header) as named templates. "Phone Call (2 speakers)" vs "Team Meeting (4-8 speakers)" vs "Interview (2 speakers, Parakeet)".

### 11. Batch Processing
Drop multiple audio files and transcribe them all in sequence. Each becomes its own project. Useful for processing a day's worth of recorded calls.

---

## Export Improvements

### 12. Word-Level SRT/VTT with Speaker Colors
For subtitles, include speaker identification and optionally color-code by speaker. Useful for video editing.

### 13. Direct Email Export
"Email Transcript" button that creates a new email in the default mail client with the transcript attached and a summary in the body.

### 14. Clipboard Copy
One-click "Copy to Clipboard" for the full formatted transcript, so the user can paste it into any application.

### 15. Export Presets
Save export configurations (which formats, legal PDF options, quality badge) as presets. "Standard Client Delivery" vs "Internal Review" vs "Court Filing".

### 16. Redaction
Mark sections of the transcript as redacted before export. In Legal PDF, show "[REDACTED]" with a black bar. Useful for privileged content.

---

## Technical / Architecture

### 17. Incremental Transcription
For very long audio files (2+ hours), transcribe in chunks and show results as they come in, rather than waiting for the entire file to process. The user can start reviewing the first 10 minutes while the rest is still transcribing.

### 18. Audio Preprocessing
Automatically detect and handle:
- Stereo audio where each channel is a different speaker (split and process separately for 100% diarization accuracy)
- Background noise reduction before transcription
- Volume normalization

### 19. Model Management in Settings
Show which models are downloaded, how much disk space they use, and let the user delete unused models. Currently models accumulate in the HuggingFace cache with no visibility.

### 20. Cohere Transcribe Integration
When an MLX port of Cohere Transcribe (the new SOTA model, 5.42% WER) appears, add it as a third engine. The conformer architecture produces errors uncorrelated with Whisper's — ideal for multi-engine voting.

### 21. Real-Time Transcription
Support live audio input (microphone) for real-time transcription. This is a major feature but would dramatically expand the use case.

### 22. Speaker Voice Profiles
Save speaker voice embeddings from one project and use them to auto-identify the same speakers in future projects. "I know this voice — it's Clayton from the March 19 call."

---

## Quick Wins (Can Do Today)

### 23. Auto-Name Speakers from Transcript Context
After transcription, scan for patterns like "This is [Name] speaking" or "Hi [Name]" in the first few minutes and suggest speaker names automatically.

### 24. Progress Time Estimates
Show estimated time remaining during transcription and diarization, based on audio duration and historical processing speed on this hardware.

### 25. Tutorial / Guided Walkthrough
A built-in tutorial that walks through the workflow using the demo project. The welcome tour exists but doesn't demonstrate the actual process.

### 26. Export Preview Before Saving
Show a full preview of all export formats (not just Legal PDF) before the user commits. Currently only Legal PDF has a live preview.

---

## Project Management

### 27. Project Dashboard View
Replace the sidebar project list with a proper project management view showing rich cards for each project. Each card displays:
- Project name / audio filename
- Date and clock time of the recording
- Duration
- Speaker names (from the speaker mapping)
- Quality tier badge (Standard / Verified)
- A 1-2 sentence summary of the subject matter (auto-generated by the LLM from the transcript)
- Number of passes, export history

Cards should be sortable/filterable by date, speaker, quality tier. This becomes the "home screen" of the app — you see all your projects at a glance with enough context to know what each one is without opening it.

### 28. Auto-Generated Project Summary
After transcription (or after Deep Review), automatically run the LLM to produce a 1-2 sentence summary of the audio content. Store this in the project metadata so it appears on the project card. Example: "Legal strategy call between Brant Kuehn and Clayton Everett regarding the Kirby bankruptcy filing, focusing on property equity claims and creditor payment timeline." This runs once and is saved — not regenerated every time.

---

## Visual Identity & Typography

### 29. Custom Font Exploration
Explore non-standard fonts to give the app a distinctive visual identity beyond default SF Pro. Consider:
- **Display/headings**: A distinctive sans-serif (Inter, Geist, Satoshi) for titles and section headers
- **Monospace**: Berkeley Mono or JetBrains Mono for timestamps, confidence numbers, metadata
- **Transcript body**: A serif font (Source Serif, Literata) or high-readability sans for the main transcript text — this is what users stare at longest
- **Legal PDF export**: Already uses Courier 12pt per court reporter standards, but could offer alternative professional fonts

The goal is that someone seeing the app for the first time recognizes it as "designed," not "default SwiftUI."

---

## Prioritized Recommendations

If I were to pick the top 5 to do next:

1. **Click-to-Play on Transcript Text** (#6) — highest impact for daily usability, relatively straightforward since audio playback already works
2. **LLM Post-Processing Cleanup** (#1) — the LLM is already integrated, just needs a cleanup pass prompt wired into the Deep Review wizard
3. **Search Within Transcript** (#8) — essential for long transcripts, standard macOS Cmd+F behavior
4. **Clipboard Copy** (#14) — trivially easy, surprisingly missing
5. **Proper Noun Dictionary** (#3) — addresses a real pain point for professional transcription users
