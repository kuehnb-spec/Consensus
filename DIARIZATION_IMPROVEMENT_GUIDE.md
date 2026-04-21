# Diarization Improvement Guide — Hearing Transcriber

## Purpose

This document is a reference for improving speaker diarization quality in the Hearing Transcriber pipeline. It covers the full transcription→alignment→diarization→attribution pipeline, identifies where errors occur, and provides actionable strategies ranked by effort and impact. It is intended to be read by both humans and AI coding assistants (Claude Code, Codex) working on this project.

## Current Setup

- **ASR**: WhisperX (or other Whisper-family models via MLX)
- **Diarization**: pyannote.audio 4.0 with `community-1` model
- **Hardware**: Apple M2 Max, 96GB unified memory
- **Use case**: One-off transcription of privileged legal hearing recordings
- **Known problems**:
  - Missing single-word or short-phrase interjections ("yes," "objection," "sustained")
  - Incorrect speaker attribution at turn boundaries
  - Segment-level diarization not granular enough for word-level accuracy

---

## 1. Understanding the Pipeline

The transcription-to-diarization pipeline has four stages. Errors at any stage cascade downstream.

```
┌─────────────────────────────────────────────────────────────────┐
│                        RAW AUDIO                                │
└──────────┬──────────────────────────────────┬───────────────────┘
           │                                  │
           ▼                                  ▼
┌─────────────────────┐            ┌─────────────────────┐
│  Stage 1: ASR       │            │  Stage 3: Diarize   │
│  (Transcription)    │            │  (Who spoke when)   │
│  Output: text       │            │  Output: speaker    │
│                     │            │  segments with       │
│                     │            │  timestamps          │
└──────────┬──────────┘            └──────────┬──────────┘
           │                                  │
           ▼                                  │
┌─────────────────────┐                       │
│  Stage 2: Forced    │                       │
│  Alignment          │                       │
│  (Word timestamps)  │                       │
│  Output: per-word   │                       │
│  start/end times    │                       │
└──────────┬──────────┘                       │
           │                                  │
           ▼                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  Stage 4: Reconciliation                                        │
│  Overlay word timestamps onto speaker segments                  │
│  Output: speaker-attributed transcript                          │
└─────────────────────────────────────────────────────────────────┘
```

### Where errors originate

| Stage | Error Type | Impact on Final Output |
|-------|-----------|----------------------|
| ASR | Missed words, hallucinated text | Words that don't exist get timestamps; real words get no attribution |
| Forced Alignment | Imprecise word boundaries (±100-200ms) | Words near speaker turns get assigned to wrong speaker |
| Diarization | Missed short speech segments; wrong speaker boundaries | Interjections attributed to wrong speaker or lost entirely |
| Reconciliation | Naive segment-level assignment | Words at segment boundaries get wrong speaker; overlapping speech mishandled |

### Key insight

Stages 2 and 3 are completely independent — they both work from the raw audio but produce different outputs. Neither knows about the other. All the intelligence about "which word belongs to which speaker" happens in Stage 4, which is typically the simplest, most naive step in the pipeline (often just: "if word timestamp falls within speaker segment, assign that speaker").

---

## 2. Strategies Ranked by Effort/Impact

### Tier 1: Quick wins (hours of work)

#### 2.1 Access pyannote frame-level posteriors for word-level attribution

Instead of relying on pyannote's merged RTTM segments (which smooth over short events), access the raw frame-level speaker probabilities and assign speakers per-word.

```python
from pyannote.audio import Pipeline
import torch

pipeline = Pipeline.from_pretrained(
    "pyannote/speaker-diarization-community-1",
    use_auth_token="HF_TOKEN"
)

# Run diarization but capture the internal hook output
# The segmentation model outputs frame-level posteriors (~16ms resolution)
diarization = pipeline("audio.wav")

# For word-level assignment, instead of using the final RTTM segments,
# use the pipeline's internal segmentation step:
from pyannote.audio import Model
segmentation_model = Model.from_pretrained(
    "pyannote/segmentation-3.0",  # or the community-1 segmentation model
    use_auth_token="HF_TOKEN"
)

from pyannote.audio import Inference
inference = Inference(segmentation_model, window="sliding")
# This gives per-frame speaker activity probabilities
segmentation = inference("audio.wav")

# segmentation is a SlidingWindowFeature with shape (num_frames, num_speakers)
# Each frame is ~16ms. You can look up speaker probabilities at any timestamp.

def get_speaker_at_time(segmentation, time_sec):
    """Get the most likely speaker at a specific timestamp."""
    frame_idx = int(time_sec / segmentation.sliding_window.step)
    frame_idx = min(frame_idx, len(segmentation.data) - 1)
    probs = segmentation.data[frame_idx]
    return int(probs.argmax()), float(probs.max())

# For each word from forced alignment:
for word in aligned_words:
    midpoint = (word["start"] + word["end"]) / 2
    speaker_idx, confidence = get_speaker_at_time(segmentation, midpoint)
    word["speaker"] = f"SPEAKER_{speaker_idx}"
    word["speaker_confidence"] = confidence
```

**Caveat**: The segmentation model's speaker indices are local to each window and need to be mapped to global speaker identities via the clustering step. The full pipeline handles this internally. To do true word-level assignment, you may need to hook into the pipeline at the right point after clustering but before segment merging. Check `pyannote.audio.pipelines.speaker_diarization.SpeakerDiarization` source code for the `apply` method internals.

#### 2.2 Tune pyannote pipeline hyperparameters

The default parameters are optimized for benchmark DER, not for catching interjections. Key parameters to adjust:

```python
from pyannote.audio import Pipeline

pipeline = Pipeline.from_pretrained(
    "pyannote/speaker-diarization-community-1",
    use_auth_token="HF_TOKEN"
)

# Access and modify hyperparameters
# Lower min_duration_on to catch shorter speech segments
# Lower min_duration_off to allow quicker speaker switches
params = pipeline.parameters()
# Typical adjustments for interjection-sensitive diarization:
# - Reduce segmentation threshold (more sensitive to speech)
# - Reduce minimum segment duration
# - Adjust clustering threshold (how aggressively speakers are merged)

# You can instantiate with modified params:
pipeline.instantiate({
    "segmentation": {
        "threshold": 0.4,        # default ~0.5; lower = more sensitive
        "min_duration_off": 0.1,  # default ~0.6; lower = catch shorter pauses
    },
    "clustering": {
        "threshold": 0.7,        # adjust based on number of speakers
        "min_cluster_size": 5,   # minimum segments per speaker
    },
})

diarization = pipeline("audio.wav")
```

**Note**: The exact parameter names and defaults change between pyannote versions. Inspect `pipeline.parameters()` or the pipeline's `config.yaml` for the current schema.

#### 2.3 LLM post-processing of attributed transcript

After generating a speaker-attributed transcript, use an LLM to fix contextually obvious errors. This is especially powerful for legal proceedings where conversational structure is predictable.

```python
import anthropic

client = anthropic.Anthropic()

def fix_attribution_with_llm(transcript_segments):
    """
    transcript_segments: list of dicts with keys:
        speaker, text, start, end
    """
    formatted = "\n".join(
        f"[{seg['start']:.1f}s-{seg['end']:.1f}s] {seg['speaker']}: {seg['text']}"
        for seg in transcript_segments
    )

    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=8000,
        system="""You are a legal transcript editor. You will receive a 
speaker-attributed transcript from an automated diarization system. 
Fix obvious speaker attribution errors based on conversational context.

Rules:
- A question and its answer should be from different speakers
- Legal procedural statements (sustained, overruled, counsel approach)
  come from the judge
- Witness answers follow attorney questions
- Do not change the text, only the speaker labels
- If uncertain, keep the original attribution
- Output the corrected transcript in the same format""",
        messages=[{
            "role": "user",
            "content": f"Fix speaker attribution errors:\n\n{formatted}"
        }]
    )
    return response.content[0].text
```

This catches 10-15% of errors that are contextually obvious — a surprisingly high yield for minimal effort. Run this as a final cleanup pass.

### Tier 2: Moderate effort (days of work)

#### 2.4 Speech separation before transcription

Instead of diarize-then-reconcile, separate the audio into per-speaker streams first, then transcribe each independently. This eliminates the reconciliation problem entirely.

Pyannote 3.3+ includes a `SpeechSeparation` pipeline using the ToTaToNet model:

```python
from pyannote.audio import Pipeline

# Load separation pipeline
separation = Pipeline.from_pretrained(
    "pyannote/speech-separation-ami-1.0",  # check for latest model
    use_auth_token="HF_TOKEN"
)

# Output: one waveform per detected speaker
separated = separation("audio.wav")

# separated.sources is a dict mapping speaker labels to audio tensors
# Transcribe each speaker's stream independently
for speaker, audio_tensor in separated.sources.items():
    # Save to temp file or pass directly to ASR
    import soundfile as sf
    sf.write(f"/tmp/{speaker}.wav", audio_tensor.numpy(), 16000)
    # Transcribe with your ASR model of choice
    transcript = transcribe(f"/tmp/{speaker}.wav")
    print(f"{speaker}: {transcript}")
```

**Why this helps**: Every word in speaker A's separated stream belongs to speaker A by definition. No reconciliation needed. Interjections that overlap with another speaker's speech get properly separated rather than being attributed to whoever was louder.

**Limitations**: Speech separation quality degrades with more than 3-4 speakers and with significant reverberation. For legal hearings with a small, known number of speakers (judge, attorney(s), witness), this is ideal. The separated audio may have artifacts that degrade ASR quality — test empirically.

#### 2.5 Speech enhancement preprocessing

Clean the audio before both ASR and diarization to improve both pipelines.

```python
# Option 1: Simple spectral gating with noisereduce
import noisereduce as nr
import soundfile as sf
import numpy as np

audio, sr = sf.read("hearing.wav")
reduced_noise = nr.reduce_noise(y=audio, sr=sr, prop_decrease=0.8)
sf.write("hearing_cleaned.wav", reduced_noise, sr)

# Option 2: Meta's Demucs for source separation
# (has an MLX port: mlx-community)
# Demucs can separate vocals from background noise
# pip install demucs
# demucs --two-stems=vocals hearing.wav

# Option 3: SpeechBrain enhancement
# pip install speechbrain
from speechbrain.inference.separation import SepformerSeparation
model = SepformerSeparation.from_hparams(
    source="speechbrain/sepformer-wham-enhancement",
    savedir="pretrained_models/sepformer"
)
enhanced = model.separate_file(path="hearing.wav")
```

**Impact**: Even simple noise reduction can improve forced alignment precision by 50-100ms, which directly improves word-to-speaker mapping at turn boundaries.

#### 2.6 CTC-based ASR for inherently better timestamps

CTC models (Conformer-CTC, Parakeet) produce monotonic alignments — each output token maps to a specific input frame. This eliminates the need for a separate forced alignment step and produces inherently more precise word boundaries.

Parakeet is available on MLX via `parakeet-mlx`:

```bash
pip install parakeet-mlx
```

```python
from parakeet_mlx import from_pretrained

model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")

# Parakeet gives word-level timestamps natively
result = model.transcribe("hearing.wav")

for sentence in result.sentences:
    print(f"[{sentence.start:.2f}s - {sentence.end:.2f}s] {sentence.text}")
    # Access word-level timestamps
    for token in sentence.tokens:
        print(f"  [{token.start:.2f}s - {token.end:.2f}s] {token.text}")
```

**Key advantage**: No separate forced alignment step means no alignment errors to cascade into diarization. Parakeet v3 supports 25 European languages and runs natively on Apple Silicon via MLX.

#### 2.7 Cohere Transcribe on M2 Max

Cohere Transcribe is a 2B parameter Conformer-based ASR model with strong accuracy. It does NOT produce timestamps or diarization, so it would replace only Stage 1 of the pipeline. Use it for transcription quality, then use a separate alignment model for timestamps.

```bash
pip install "transformers>=4.56" torch soundfile librosa sentencepiece protobuf
```

```python
import torch
from transformers import AutoProcessor, AutoModelForSpeechSeq2Seq

model_id = "CohereLabs/cohere-transcribe-03-2026"

# Try MPS first, fall back to CPU
if torch.backends.mps.is_available():
    device = "mps"
elif torch.cuda.is_available():
    device = "cuda:0"
else:
    device = "cpu"

processor = AutoProcessor.from_pretrained(model_id, trust_remote_code=True)
model = AutoModelForSpeechSeq2Seq.from_pretrained(
    model_id, trust_remote_code=True
).to(device)
model.eval()

texts = model.transcribe(
    processor=processor,
    audio_files=["hearing.wav"],
    language="en"
)
print(texts[0])
```

**MPS caveat**: The model uses custom Conformer ops via `trust_remote_code=True`. If MPS throws unsupported-operation errors, fall back to CPU:

```python
# If MPS fails, catch and retry on CPU
try:
    model = model.to("mps")
    texts = model.transcribe(processor=processor, audio_files=["hearing.wav"], language="en")
except Exception as e:
    print(f"MPS failed ({e}), falling back to CPU")
    model = model.to("cpu")
    texts = model.transcribe(processor=processor, audio_files=["hearing.wav"], language="en")
```

CPU inference on M2 Max for a 2B model will be slow but workable for one-off transcription. Expect roughly 0.3-0.5x realtime (i.e., a 10-minute file takes 20-30 minutes).

**Important**: Cohere Transcribe does not output timestamps. If you use it, you need a separate forced alignment step (wav2vec2 via WhisperX, or CTC alignment via NeMo) to produce word-level timestamps for diarization reconciliation.

### Tier 3: Significant effort (week+)

#### 2.8 NeMo MSDD on Apple Silicon

NeMo's Multi-Scale Diarization Decoder analyzes speaker embeddings at five simultaneous time scales (1.5s, 1.25s, 1.0s, 0.75s, 0.5s), with a neural network dynamically weighting each scale. The 0.5s scale can capture brief interjections that pyannote's fixed-resolution segmentation misses.

##### Installation on M2 Max

NeMo's primary dependency blocker on macOS is `triton` (Linux-only). Work around it:

```bash
# Create a dedicated conda environment
conda create -n nemo python=3.10 -y
conda activate nemo

# Install PyTorch with MPS support
pip install torch torchaudio

# Install NeMo without triton
# Clone the repo to selectively install
git clone https://github.com/NVIDIA/NeMo.git
cd NeMo

# Edit requirements to remove triton dependency
# In setup.py or requirements files, comment out triton

# Install with ASR extras only
pip install '.[asr]' --no-deps
# Then install remaining deps manually, skipping triton:
pip install hydra-core omegaconf pytorch-lightning \
    sentencepiece transformers huggingface_hub \
    soundfile librosa scipy pandas \
    braceexpand editdistance jiwer \
    webdataset lhotse

# Set MPS fallback for unsupported ops
export PYTORCH_ENABLE_MPS_FALLBACK=1
```

##### Running MSDD diarization

```python
import json
import os

# Create manifest file (NeMo's input format)
manifest = {
    "audio_filepath": "/absolute/path/to/hearing.wav",
    "offset": 0,
    "duration": None,
    "label": "infer",
    "text": "-",
    "num_speakers": None,  # or set if known, e.g., 3
    "rttm_filepath": None,
    "uem_filepath": None
}

manifest_path = "/tmp/nemo_manifest.json"
with open(manifest_path, "w") as f:
    f.write(json.dumps(manifest))

# Configure and run diarization
from omegaconf import OmegaConf

# Load base config
config_url = "https://raw.githubusercontent.com/NVIDIA/NeMo/main/examples/speaker_tasks/diarization/conf/inference/diar_infer_telephonic.yaml"
# Download and modify as needed, or construct programmatically:

cfg = OmegaConf.create({
    "name": "ClusterDiarizer",
    "num_workers": 1,
    "sample_rate": 16000,
    "batch_size": 16,  # reduce for CPU/MPS
    "device": "cpu",    # or "mps" to try MPS
    "verbose": True,
    "diarizer": {
        "manifest_filepath": manifest_path,
        "out_dir": "/tmp/nemo_diarization_output",
        "oracle_vad": False,
        "collar": 0.25,
        "ignore_overlap": False,  # Important: set False to handle overlapping speech
        "vad": {
            "model_path": "vad_multilingual_marblenet",
            "parameters": {
                "window_length_in_sec": 0.15,
                "shift_length_in_sec": 0.01,
                "smoothing": "median",
                "overlap": 0.875,
                "onset": 0.4,
                "offset": 0.7,
                "min_duration_on": 0.1,   # Lower than default to catch interjections
                "min_duration_off": 0.1,
                "pad_onset": 0.05,
                "pad_offset": -0.1,
            }
        },
        "speaker_embeddings": {
            "model_path": "titanet_large",
            "parameters": {
                "window_length_in_sec": [1.5, 1.25, 1.0, 0.75, 0.5],
                "shift_length_in_sec": [0.75, 0.625, 0.5, 0.375, 0.25],
                "multiscale_weights": [1, 1, 1, 1, 1],
            }
        },
        "clustering": {
            "parameters": {
                "oracle_num_speakers": False,
                "max_num_speakers": 8,
                "enhanced_count_thres": 80,
                "max_rp_threshold": 0.25,
                "sparse_search_volume": 30,
            }
        },
        "msdd_model": {
            "model_path": "diar_msdd_telephonic",
            "parameters": {
                "sigmoid_threshold": [0.7],
                "seq_eval_mode": False,
                "split_infer": True,
                "diar_window_length": 50,
                "overlap_infer_spk_limit": 5,
            }
        }
    }
})

# Run with NeMo
from nemo.collections.asr.models import ClusteringDiarizer

diarizer_model = ClusteringDiarizer(cfg=cfg)
diarizer_model.diarize()

# Output RTTM will be in /tmp/nemo_diarization_output/
```

##### NeMo ASR-based VAD for word-level diarization

NeMo has a native mechanism for using ASR word timestamps to drive diarization boundaries:

```yaml
# In the diarization config, under asr:
asr:
  model_path: stt_en_conformer_ctc_large
  parameters:
    asr_based_vad: True  # Use word timestamps for speech segmentation
    asr_based_vad_threshold: 1.0  # Gap threshold in seconds
    lenient_overlap_WDER: True  # Tolerate words in overlapped regions
```

This is the most direct path to word-level diarization in NeMo: the ASR model produces word timestamps, those timestamps define the speech regions, and the diarization system assigns speakers to those word-aligned regions.

**Performance expectation on M2 Max CPU**: For a 10-minute audio file, expect 5-15 minutes of processing. The TitaNet embedding extraction is the slowest step. Reduce batch_size to 8 or lower if memory is an issue (though with 96GB, it won't be).

#### 2.9 Hybrid pipeline: best ASR + best diarization

The ideal pipeline for your use case may be a hybrid that takes the best component from each system:

```
1. Preprocessing:  noisereduce or Demucs (speech enhancement)
2. ASR + timestamps: Parakeet-TDT v3 via MLX (native word timestamps, fast)
   - OR Cohere Transcribe (better accuracy) + wav2vec2 alignment (separate step)
3. Diarization: pyannote 4.0 community-1 (frame-level posteriors)
4. Reconciliation: Word-level assignment using frame posteriors (not segment-level)
5. Post-processing: LLM cleanup pass for contextual errors
```

The implementation of this hybrid pipeline:

```python
import numpy as np
import soundfile as sf

# ─── Step 1: Enhance audio ───
import noisereduce as nr

audio, sr = sf.read("hearing.wav")
audio_clean = nr.reduce_noise(y=audio, sr=sr)
sf.write("hearing_clean.wav", audio_clean, sr)

# ─── Step 2: Transcribe with word timestamps ───
# Option A: Parakeet (MLX native, includes timestamps)
from parakeet_mlx import from_pretrained
asr_model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")
result = asr_model.transcribe("hearing_clean.wav")
words = []
for sentence in result.sentences:
    for token in sentence.tokens:
        words.append({
            "text": token.text,
            "start": token.start,
            "end": token.end
        })

# ─── Step 3: Diarize with pyannote (frame-level) ───
from pyannote.audio import Pipeline

diar_pipeline = Pipeline.from_pretrained(
    "pyannote/speaker-diarization-community-1",
    use_auth_token="HF_TOKEN"
)
diarization = diar_pipeline("hearing_clean.wav")

# ─── Step 4: Word-level reconciliation ───
def assign_speakers_word_level(words, diarization):
    """Assign speaker to each word using diarization timeline."""
    for word in words:
        midpoint = (word["start"] + word["end"]) / 2
        # Find which speaker segment contains this word's midpoint
        speaker = "UNKNOWN"
        best_overlap = 0
        for turn, _, spk in diarization.itertracks(yield_label=True):
            # Calculate overlap between word and speaker turn
            overlap_start = max(word["start"], turn.start)
            overlap_end = min(word["end"], turn.end)
            overlap = max(0, overlap_end - overlap_start)
            if overlap > best_overlap:
                best_overlap = overlap
                speaker = spk
        word["speaker"] = speaker
    return words

attributed_words = assign_speakers_word_level(words, diarization)

# ─── Step 5: Group into speaker turns and format ───
def group_into_turns(words):
    """Group consecutive words by speaker into turns."""
    if not words:
        return []
    turns = []
    current = {
        "speaker": words[0]["speaker"],
        "start": words[0]["start"],
        "end": words[0]["end"],
        "text": words[0]["text"]
    }
    for w in words[1:]:
        if w["speaker"] == current["speaker"]:
            current["end"] = w["end"]
            current["text"] += " " + w["text"]
        else:
            turns.append(current)
            current = {
                "speaker": w["speaker"],
                "start": w["start"],
                "end": w["end"],
                "text": w["text"]
            }
    turns.append(current)
    return turns

turns = group_into_turns(attributed_words)

# ─── Step 6: LLM post-processing ───
# (See Section 2.3 above for the LLM cleanup function)
```

---

## 3. Timestamp Accuracy Deep Dive

Timestamp accuracy is the linchpin of the entire pipeline. If word timestamps are off by even 100-200ms, words near speaker turn boundaries get assigned to the wrong speaker.

### What degrades timestamp accuracy

| Factor | Effect | Mitigation |
|--------|--------|------------|
| Fast/overlapping speech | Words blur together, alignment model can't find boundaries | Speech enhancement; speech separation |
| Background noise | Acoustic features are masked, alignment confidence drops | Noise reduction preprocessing |
| Disfluencies (um, uh) | No clean phoneme boundaries to align to | Post-filter: remove disfluency tokens before reconciliation |
| Whispered/quiet speech | Low energy makes alignment unreliable | Normalize audio amplitude before alignment |
| Reverberation | Smeared spectral features | Dereverberation preprocessing |
| Attention-based ASR (Whisper) | Non-monotonic attention requires separate alignment step | Use CTC-based model (Parakeet, NeMo Conformer-CTC) |

### Recommended timestamp validation

After generating word timestamps, validate them before feeding into reconciliation:

```python
def validate_timestamps(words):
    """Flag suspicious timestamps for review."""
    issues = []
    for i, word in enumerate(words):
        duration = word["end"] - word["start"]
        
        # Flag words with implausibly short duration
        if duration < 0.05:  # 50ms minimum for any word
            issues.append((i, "too_short", duration))
        
        # Flag words with implausibly long duration
        if duration > 2.0 and len(word["text"]) < 10:
            issues.append((i, "too_long", duration))
        
        # Flag gaps between consecutive words
        if i > 0:
            gap = word["start"] - words[i-1]["end"]
            if gap < -0.05:  # Overlapping word timestamps
                issues.append((i, "overlap", gap))
            elif gap > 1.0:  # Suspiciously large gap
                issues.append((i, "large_gap", gap))
    
    return issues
```

---

## 4. Model Comparison for This Use Case

| Model | Timestamps | Diarization | MLX Native | Quality Notes |
|-------|-----------|-------------|------------|---------------|
| WhisperX (Whisper + wav2vec2) | Via forced alignment | Via pyannote | Via mlx-whisper | Good baseline; alignment step adds latency and potential error |
| Parakeet TDT v3 | Native (CTC) | No (external) | Yes (parakeet-mlx) | Best timestamp accuracy; no alignment step needed |
| Cohere Transcribe | None | None | No (PyTorch MPS/CPU) | Best raw transcription accuracy; needs separate alignment |
| Qwen3-ASR | Native | No (external) | Yes (mlx-qwen3-asr) | Strong multilingual; good timestamps |
| NeMo Conformer-CTC | Native (CTC) | Full pipeline (MSDD) | No (PyTorch CPU) | Best integrated ASR+diarization; heavy framework |

### For legal hearing transcription specifically

**Recommended primary path**: Parakeet TDT v3 (MLX, native timestamps) + pyannote community-1 (word-level reconciliation) + LLM cleanup.

**Recommended experimental path**: NeMo MSDD with ASR-based VAD on CPU, to test whether multi-scale diarization catches interjections that pyannote misses.

**For maximum transcription accuracy**: Cohere Transcribe (CPU) for text, then Parakeet or wav2vec2 for timestamps, then pyannote for diarization.

---

## 5. Quick Reference: Environment Setup

### Parakeet MLX (recommended for timestamps)
```bash
pip install parakeet-mlx
# Requires ffmpeg: brew install ffmpeg
```

### Cohere Transcribe (MPS/CPU)
```bash
pip install "transformers>=4.56" torch soundfile librosa sentencepiece protobuf
export PYTORCH_ENABLE_MPS_FALLBACK=1
```

### pyannote 4.0
```bash
pip install pyannote.audio
# Requires HuggingFace token with accepted model agreements
```

### NeMo (Mac workaround)
```bash
conda create -n nemo python=3.10 -y
conda activate nemo
pip install torch torchaudio
git clone https://github.com/NVIDIA/NeMo.git
cd NeMo
# Remove triton from requirements, then:
pip install '.[asr]'
export PYTORCH_ENABLE_MPS_FALLBACK=1
```

### Audio preprocessing
```bash
pip install noisereduce soundfile
# For Demucs: pip install demucs
# For SpeechBrain: pip install speechbrain
```

---

## 6. Testing Protocol

When comparing approaches, use consistent evaluation:

1. Select 3-5 representative audio clips (varied speakers, containing interjections)
2. Create ground-truth transcripts with speaker labels manually
3. Run each pipeline variant on the same clips
4. Measure:
   - **Word Error Rate (WER)**: transcription accuracy
   - **Diarization Error Rate (DER)**: speaker segmentation accuracy
   - **Word-level Diarization Error Rate (WDER)**: percentage of correctly-transcribed words assigned to wrong speaker
   - **Interjection capture rate**: percentage of ground-truth interjections correctly attributed
5. The interjection capture rate is the most important metric for this use case

```python
def interjection_capture_rate(ground_truth, predicted):
    """
    ground_truth: list of (word, speaker, start_time) for interjections only
    predicted: list of (word, speaker, start_time) from pipeline
    """
    captured = 0
    correctly_attributed = 0
    for gt_word, gt_speaker, gt_time in ground_truth:
        # Find nearest predicted word within 500ms
        match = min(
            predicted,
            key=lambda p: abs(p[2] - gt_time),
            default=None
        )
        if match and abs(match[2] - gt_time) < 0.5:
            captured += 1
            if match[1] == gt_speaker:
                correctly_attributed += 1
    
    total = len(ground_truth)
    return {
        "capture_rate": captured / total if total else 0,
        "attribution_accuracy": correctly_attributed / total if total else 0,
    }
```

---

## 7. Creative & Experimental Approaches

These are unconventional ideas — some speculative, some surprisingly practical. The point is to break out of the standard pipeline-tuning mindset. Any of these could be the thing that solves the interjection problem.

### 7.1 Speaker enrollment: convert unsupervised → supervised

The standard diarization approach is unsupervised: the system has no idea who the speakers are and must discover them from scratch. But in legal proceedings, you almost always know who will be speaking — judge, attorney(s), witness(es). This is an enormous advantage that the pipeline currently throws away.

**The idea**: Before processing a hearing, record or extract a 10-30 second sample of each known speaker. Use these as enrollment embeddings. Then instead of clustering (unsupervised), do speaker verification (supervised) — for each speech segment, compare its embedding to the enrolled speakers and pick the best match.

```python
from pyannote.audio import Model, Inference
import torch

# Load speaker embedding model
embedding_model = Model.from_pretrained(
    "pyannote/wespeaker-voxceleb-resnet34-LM",
    use_auth_token="HF_TOKEN"
)
inference = Inference(embedding_model, window="whole")

# Enroll known speakers from reference clips
enrolled = {}
for name, clip_path in [
    ("JUDGE", "samples/judge_sample.wav"),
    ("ATTORNEY_PLAINTIFF", "samples/atty_plaintiff.wav"),
    ("ATTORNEY_DEFENSE", "samples/atty_defense.wav"),
    ("WITNESS", "samples/witness.wav"),
]:
    enrolled[name] = inference(clip_path)

# For each detected speech segment, verify against enrolled speakers
from scipy.spatial.distance import cosine

def identify_speaker(segment_embedding, enrolled_speakers):
    best_match = None
    best_score = -1
    for name, ref_emb in enrolled_speakers.items():
        score = 1 - cosine(segment_embedding, ref_emb)
        if score > best_score:
            best_score = score
            best_match = name
    return best_match, best_score
```

**Why this might be transformative**: Clustering is the weakest link in most diarization systems — it's where speaker count estimation errors happen, where short segments get absorbed into the wrong cluster. Speaker verification against known references bypasses all of that. For interjections specifically, even a very short segment can be matched to an enrolled speaker with reasonable confidence, whereas it might be too short for clustering to handle correctly.

**Practical note**: You can extract enrollment samples from the hearing itself by identifying clear, uncontested segments (e.g., the judge's opening remarks, the attorney's first sustained questioning block) and using those as enrollment references for the rest of the file.

### 7.2 Pitch (F0) tracking as a parallel diarization signal

Speaker embeddings (TitaNet, WeSpeaker) operate on spectral features at ~1-2 second windows. Fundamental frequency (F0/pitch) operates at millisecond resolution and is highly speaker-specific — a male attorney at 110Hz vs. a female judge at 220Hz are trivially distinguishable.

**The idea**: Track F0 continuously across the audio. Use abrupt pitch shifts as an independent speaker-change detection signal. Fuse this with the embedding-based diarization output.

```python
import librosa
import numpy as np

audio, sr = librosa.load("hearing.wav", sr=16000)

# Extract F0 at high temporal resolution
f0, voiced_flag, voiced_probs = librosa.pyin(
    audio, fmin=50, fmax=500,
    sr=sr, frame_length=1024, hop_length=160  # ~10ms resolution
)

# Smooth and cluster F0 values to identify speaker-characteristic ranges
# NaN values = unvoiced frames (silence, noise, fricatives)
voiced_f0 = f0[~np.isnan(f0)]

# Simple: detect frames where F0 jumps by > 30% — likely speaker change
f0_filled = np.interp(
    np.arange(len(f0)),
    np.where(~np.isnan(f0))[0],
    f0[~np.isnan(f0)]
)
f0_diff = np.abs(np.diff(f0_filled) / (f0_filled[:-1] + 1e-6))
change_points = np.where(f0_diff > 0.3)[0]

# Convert frame indices to timestamps
change_times = librosa.frames_to_time(
    change_points, sr=sr, hop_length=160
)
```

**Why this helps for interjections**: An interjection like "objection" has a clear pitch signature. Even if the embedding model doesn't have enough audio to extract a reliable speaker vector, the pitch contour immediately reveals a different voice. This signal is available at 10ms resolution — far finer than the 500ms minimum window of typical embedding models.

### 7.3 Text-content speaker prediction (legal domain)

Legal proceedings have an extremely structured discourse pattern. The content of what's said is strongly predictive of who said it — independently of any audio analysis.

**The idea**: Train (or prompt) a classifier that predicts the likely speaker from the text content alone. Use this as a Bayesian prior to re-weight ambiguous diarization decisions.

```python
# Simple rule-based version for legal proceedings
LEGAL_SPEAKER_PATTERNS = {
    "JUDGE": [
        r"sustained",
        r"overruled",
        r"counsel.{0,20}approach",
        r"the (court|bench) (finds|rules|orders)",
        r"members of the jury",
        r"objection is (sustained|overruled|noted)",
        r"you may (proceed|step down|be seated)",
        r"court is (adjourned|in recess)",
    ],
    "EXAMINING_ATTORNEY": [
        r"^(did you|were you|can you|could you|would you|is it|isn't it)",
        r"^(please|let me|I'd like to|directing your attention)",
        r"(your honor|the court|if it please)",
        r"(move to (admit|strike|enter))",
        r"no further questions",
        r"^objection",
    ],
    "WITNESS": [
        r"^(yes|no|correct|that's (right|correct)|I don't (recall|remember|know))",
        r"^(I (was|did|am|have|had|went|saw|heard|believe|think))",
        r"^(not that I)",
        r"^(to the best of my)",
    ],
}

import re

def predict_speaker_from_text(text):
    """Return (predicted_speaker, confidence) based on text content."""
    text_lower = text.strip().lower()
    scores = {}
    for speaker, patterns in LEGAL_SPEAKER_PATTERNS.items():
        for pattern in patterns:
            if re.search(pattern, text_lower):
                scores[speaker] = scores.get(speaker, 0) + 1
    if scores:
        best = max(scores, key=scores.get)
        return best, scores[best] / sum(scores.values())
    return None, 0.0

# Use as a re-scoring signal:
def rescore_attribution(word, audio_speaker, audio_confidence):
    text_speaker, text_confidence = predict_speaker_from_text(word["text"])
    if text_speaker and text_confidence > 0.8 and audio_confidence < 0.6:
        # Text strongly predicts a different speaker and audio is ambiguous
        return text_speaker
    return audio_speaker
```

**LLM-powered version**: Instead of regex, pass the full transcript to Claude and ask it to predict speakers based purely on conversational structure — questions vs. answers, procedural language, witness testimony patterns. This can catch subtler patterns (e.g., an attorney's rhetorical style vs. opposing counsel).

### 7.4 Ensemble diarization: run multiple systems and vote

No single diarization system is best at everything. Pyannote excels at segmentation, NeMo MSDD excels at multi-scale analysis, simple clustering approaches are robust to edge cases. Running multiple systems and ensembling their outputs can outperform any individual system.

**The idea**: Run 2-3 different diarization approaches on the same audio. At each frame (or for each word), take the majority vote. Where systems disagree, flag for human review.

```python
def ensemble_diarization(diarization_outputs, word_timestamps):
    """
    diarization_outputs: list of pyannote Annotation objects from different systems
    word_timestamps: list of {text, start, end} dicts
    """
    for word in word_timestamps:
        midpoint = (word["start"] + word["end"]) / 2
        votes = {}
        for diar in diarization_outputs:
            # Find speaker at this timepoint in each system's output
            for turn, _, speaker in diar.itertracks(yield_label=True):
                if turn.start <= midpoint <= turn.end:
                    votes[speaker] = votes.get(speaker, 0) + 1
                    break

        if votes:
            winner = max(votes, key=votes.get)
            agreement = votes[winner] / len(diarization_outputs)
            word["speaker"] = winner
            word["ensemble_agreement"] = agreement
            word["needs_review"] = agreement < 0.67  # Flag if no 2/3 majority
        else:
            word["speaker"] = "UNKNOWN"
            word["needs_review"] = True

    return word_timestamps
```

**Practical ensemble**: Run pyannote community-1 with default params + pyannote community-1 with aggressive params (low min_duration) + a simple cosine-similarity clustering baseline. Three runs, majority vote.

### 7.5 Overlap-first pipeline: detect → separate → re-transcribe

Instead of trying to handle overlapping speech at the diarization level, make it a first-class preprocessing step.

**The idea**: Run overlap detection first. For non-overlapping regions, use standard diarization. For overlapping regions only, run speech separation to produce clean per-speaker audio, then re-transcribe and re-diarize just those segments.

```
FULL AUDIO
    │
    ▼
┌──────────────────┐
│ Overlap Detection │ (pyannote overlap detection model)
└──────────────────┘
    │
    ├── Non-overlapping regions → Standard pipeline
    │
    └── Overlapping regions → Speech Separation (ToTaToNet)
                                    │
                                    ├── Speaker A stream → ASR → timestamps
                                    └── Speaker B stream → ASR → timestamps
                                    │
                                    ▼
                              Merge results back
```

This avoids running speech separation on the entire file (which can introduce artifacts in clean regions) while specifically targeting the segments where diarization fails most.

### 7.6 Whisper cross-attention alignment extraction

Whisper's encoder-decoder architecture uses cross-attention between the decoder (text tokens) and encoder (audio frames). These attention weights implicitly encode which audio frames correspond to which text tokens — it's a form of soft alignment built into the model.

**The idea**: Extract Whisper's cross-attention weights during transcription and use them directly as word-timestamp alignments, instead of running a separate wav2vec2 forced alignment step. This eliminates one entire stage of the pipeline and its associated errors.

```python
import torch
from transformers import WhisperProcessor, WhisperForConditionalGeneration

model = WhisperForConditionalGeneration.from_pretrained("openai/whisper-large-v3")
processor = WhisperProcessor.from_pretrained("openai/whisper-large-v3")

# Enable output of cross-attention weights
model.config.output_attentions = True

inputs = processor(audio_array, return_tensors="pt", sampling_rate=16000)

with torch.no_grad():
    outputs = model.generate(
        **inputs,
        return_dict_in_generate=True,
        output_attentions=True,
        max_new_tokens=444,
    )

# outputs.cross_attentions contains attention weights
# Shape per layer: (batch, num_heads, decoder_seq_len, encoder_seq_len)
# Average across heads and layers, then find peak attention per token
cross_attn = torch.stack([
    layer.mean(dim=1)  # average across heads
    for step_attns in outputs.cross_attentions
    for layer in step_attns
]).mean(dim=0)  # average across layers

# For each generated token, find the encoder frame with highest attention
# This gives approximate word timestamps without forced alignment
```

**Caveat**: Attention-based alignment is noisier than CTC or forced alignment. But it's "free" — no extra model, no extra inference pass. Useful as a validation signal against forced alignment timestamps.

### 7.7 Speaking rate and prosodic fingerprinting

Different speakers have different rhythms. An attorney asks questions at a measured pace with deliberate pauses; a nervous witness speaks in bursts. These prosodic features operate at a different timescale than spectral embeddings and can catch things embeddings miss.

**The idea**: Compute per-segment speaking rate (words per second), mean pause duration, and rhythm regularity. Use these as auxiliary features for speaker identification.

```python
def compute_prosodic_features(words_in_segment):
    """Compute speaking rate and rhythm features for a speech segment."""
    if len(words_in_segment) < 2:
        return {"rate": 0, "pause_mean": 0, "rhythm_var": 0}

    total_duration = words_in_segment[-1]["end"] - words_in_segment[0]["start"]
    rate = len(words_in_segment) / total_duration if total_duration > 0 else 0

    # Inter-word gaps
    gaps = []
    for i in range(1, len(words_in_segment)):
        gap = words_in_segment[i]["start"] - words_in_segment[i-1]["end"]
        gaps.append(max(0, gap))

    pause_mean = np.mean(gaps) if gaps else 0
    rhythm_var = np.var(gaps) if len(gaps) > 1 else 0

    return {"rate": rate, "pause_mean": pause_mean, "rhythm_var": rhythm_var}

# Cluster segments by prosodic features as an auxiliary signal
# Compare to spectral-embedding-based clustering and look for disagreements
```

### 7.8 Silence pattern analysis for turn-taking prediction

The duration and pattern of silences between utterances encode turn-taking structure. A 2-second pause followed by speech is more likely a new speaker than a 200ms pause. In legal proceedings, these patterns are highly structured.

**The idea**: Build a simple model of turn-taking: after a question (rising intonation + silence > 500ms), expect a speaker change. After a statement followed by a short pause (< 300ms), expect the same speaker to continue. Use this to predict expected speaker changes and flag when diarization disagrees.

```python
def predict_turn_changes(silences, words):
    """
    silences: list of (start, end, duration) of detected silence gaps
    words: list of word dicts with timestamps and speaker labels
    
    Returns list of predicted change points.
    """
    predicted_changes = []
    for silence in silences:
        if silence["duration"] > 0.5:  # Substantial pause
            # Check if the word before the silence ends with
            # question-like intonation or content
            preceding_words = [
                w for w in words if w["end"] <= silence["start"]
            ]
            if preceding_words:
                last_word = preceding_words[-1]["text"].lower()
                # After a question mark or question word, expect speaker change
                if last_word.endswith("?") or last_word in [
                    "correct", "right", "yes", "no"
                ]:
                    predicted_changes.append(silence["end"])
    return predicted_changes
```

### 7.9 Multi-pass refinement with confidence gating

Instead of a single pass through the pipeline, run multiple passes where each pass refines the previous one's output. On the second pass, the system already has a rough transcript and can use it to improve both diarization and alignment.

**The idea**:

```
Pass 1: Standard pipeline → rough attributed transcript
Pass 2: Use Pass 1 speaker labels to extract better enrollment embeddings
         → re-run diarization with speaker verification instead of clustering
Pass 3: Use Pass 2 diarization to identify overlapping regions
         → run speech separation only on those regions → re-transcribe
Pass 4: LLM cleanup of the refined transcript
```

Each pass uses information from the previous pass that wasn't available initially. By pass 2, you have enrollment embeddings extracted from the audio itself (the highest-confidence segments from pass 1). By pass 3, you know exactly where overlaps are and can target separation precisely.

```python
def iterative_refinement(audio_path, num_passes=3):
    # Pass 1: Standard pipeline
    transcript = standard_pipeline(audio_path)
    
    for pass_num in range(2, num_passes + 1):
        # Extract high-confidence speaker segments from previous pass
        confident_segments = [
            seg for seg in transcript
            if seg.get("confidence", 0) > 0.9
            and seg["end"] - seg["start"] > 2.0  # at least 2 seconds
        ]
        
        # Build enrollment embeddings from confident segments
        enrollments = {}
        for seg in confident_segments:
            speaker = seg["speaker"]
            if speaker not in enrollments:
                # Extract audio for this segment
                audio_seg = extract_audio(audio_path, seg["start"], seg["end"])
                enrollments[speaker] = compute_embedding(audio_seg)
        
        # Re-run diarization with enrollment (supervised mode)
        transcript = supervised_pipeline(audio_path, enrollments)
    
    # Final LLM cleanup
    transcript = llm_cleanup(transcript)
    return transcript
```

### 7.10 Formant-based speaker discrimination for overlapping speech

When two speakers talk simultaneously, spectral embeddings get confused because they're averaging two voices. But formant frequencies (F1, F2, F3 — the resonant frequencies of the vocal tract) are highly speaker-specific and can be tracked independently for overlapping voices.

**The idea**: In detected overlap regions, use formant tracking to identify which speaker's vocal tract characteristics are present, rather than relying on spectral embeddings.

```python
import parselmouth  # Praat in Python

def extract_formants(audio_path, start, end):
    """Extract formant tracks for an audio segment."""
    snd = parselmouth.Sound(audio_path)
    segment = snd.extract_part(from_time=start, to_time=end)
    formant = segment.to_formant_burg(
        time_step=0.01,  # 10ms resolution
        max_number_of_formants=4,
        maximum_formant=5500,
    )
    
    # Extract F1, F2, F3 tracks
    times = formant.xs()
    f1 = [formant.get_value_at_time(1, t) for t in times]
    f2 = [formant.get_value_at_time(2, t) for t in times]
    f3 = [formant.get_value_at_time(3, t) for t in times]
    
    return {"times": times, "F1": f1, "F2": f2, "F3": f3}
```

### 7.11 Recording setup optimization (if you can influence it)

The highest-leverage improvement isn't algorithmic — it's the recording itself. If you have any ability to influence how hearings are recorded:

- **Separate lapel mics per speaker**: Eliminates 90% of the diarization problem. Each channel is a known speaker.
- **Directional microphones at the bench**: Even a cheap USB shotgun mic pointed at the judge gives you a spatial signal.
- **Stereo recording**: Even a stereo recorder placed centrally captures spatial differences between speaker positions. Left/right energy ratios are a simple but powerful speaker discrimination signal.
- **Higher sample rate**: 44.1kHz or 48kHz captures more spectral detail than 16kHz, improving both ASR and speaker embeddings.

```python
# If you have stereo audio, exploit the spatial difference
import soundfile as sf
import numpy as np

audio, sr = sf.read("hearing_stereo.wav")  # shape: (samples, 2)
left = audio[:, 0]
right = audio[:, 1]

# Compute frame-level left/right energy ratio
frame_size = int(0.025 * sr)  # 25ms frames
hop_size = int(0.010 * sr)    # 10ms hop

def frame_energy(signal, frame_size, hop_size):
    frames = librosa.util.frame(signal, frame_length=frame_size, hop_length=hop_size)
    return np.sum(frames ** 2, axis=0)

left_energy = frame_energy(left, frame_size, hop_size)
right_energy = frame_energy(right, frame_size, hop_size)

# Spatial ratio: positive = more left, negative = more right
spatial_ratio = (left_energy - right_energy) / (left_energy + right_energy + 1e-10)

# Cluster by spatial position — different speakers sit in different locations
# This is independent of voice characteristics and works even for similar voices
```

### 7.12 End-to-end speaker-attributed transcription via fine-tuned seq2seq

Instead of the pipeline approach, fine-tune an ASR model to output speaker tags inline with the transcription. The model learns to output: `<judge> Sustained. <attorney> Your honor, I must object to...`

**The idea**: Take a pre-trained Whisper or similar seq2seq model, create training data from your existing (corrected) transcripts, and fine-tune it to predict speaker labels as part of the text output.

This is a research-level idea, but it eliminates every pipeline stage into a single model. Models like Universal-1 from AssemblyAI and Rev.ai already do this commercially. For a domain-specific fine-tune on legal audio, you'd need perhaps 50-100 hours of corrected speaker-attributed transcripts as training data.

### 7.13 Breathing detection as a speaker change signal

Speakers inhale before speaking — and breath sounds have speaker-specific spectral signatures. An audible inhale in a gap between utterances is a strong signal that the next utterance will be from a different speaker than the previous one.

```python
# Detect breath sounds using spectral characteristics
# Breaths have energy concentrated in 1-4kHz range, are 200-600ms long,
# and occur at the boundaries of speech segments

def detect_breaths(audio, sr, speech_segments):
    """Find breath sounds in gaps between speech segments."""
    breaths = []
    for i in range(1, len(speech_segments)):
        gap_start = speech_segments[i-1]["end"]
        gap_end = speech_segments[i]["start"]
        gap_duration = gap_end - gap_start
        
        if 0.15 < gap_duration < 1.0:  # Plausible breath duration range
            # Extract gap audio
            start_sample = int(gap_start * sr)
            end_sample = int(gap_end * sr)
            gap_audio = audio[start_sample:end_sample]
            
            # Check for breath-like spectral characteristics
            S = np.abs(librosa.stft(gap_audio, n_fft=512))
            freqs = librosa.fft_frequencies(sr=sr, n_fft=512)
            
            # Breath energy concentrated in 1-4kHz
            breath_band = (freqs > 1000) & (freqs < 4000)
            breath_energy = S[breath_band].mean()
            total_energy = S.mean()
            
            if breath_energy / (total_energy + 1e-10) > 0.6:
                breaths.append({
                    "time": (gap_start + gap_end) / 2,
                    "before_segment": i,
                    "suggests_speaker_change": True
                })
    return breaths
```

### 7.14 Graph-based optimal assignment

Instead of naive "word falls in speaker segment → assign speaker," model the reconciliation as a graph optimization problem where both acoustic similarity and contextual coherence influence the assignment.

**The idea**: Build a graph where each word is a node, edges connect consecutive words, and the optimization minimizes total cost across: acoustic match to speaker (from diarization), contextual coherence (same speaker for contiguous natural phrases), and structural constraints (question→answer implies speaker change).

This turns the simple overlap-based assignment into a global optimization that considers the full transcript structure simultaneously rather than making greedy per-word decisions.

### 7.15 Confidence-gated human review

Rather than trying to automate everything, explicitly design the pipeline to identify and flag the 10-20% of segments it's least confident about, and present those for quick human review.

```python
def generate_review_queue(attributed_words, threshold=0.6):
    """
    Flag segments where diarization confidence is below threshold.
    Group into reviewable chunks.
    """
    review_items = []
    current_chunk = []
    
    for word in attributed_words:
        if word.get("speaker_confidence", 1.0) < threshold:
            # Include surrounding context (±5 words)
            current_chunk.append(word)
        else:
            if current_chunk:
                # Pad with context
                review_items.append({
                    "start": current_chunk[0]["start"],
                    "end": current_chunk[-1]["end"],
                    "text": " ".join(w["text"] for w in current_chunk),
                    "current_speaker": current_chunk[0]["speaker"],
                    "confidence": min(w.get("speaker_confidence", 0) for w in current_chunk),
                })
                current_chunk = []
    
    return review_items

# For a 1-hour hearing, this might produce 20-40 items to review,
# each just a few seconds long. 10 minutes of human review to
# fix the hardest cases that no algorithm will get right.
```

**Why this is worth doing**: For privileged legal recordings where accuracy matters, 95% automation + 5% targeted human review is better than 98% automation with 2% undetected errors. The pipeline can be designed to make human review as efficient as possible — playing just the ambiguous 3-second clips with suggested speaker labels that the reviewer can accept or change.

### 7.16 Vocal fry / creaky voice detection

Some speakers habitually use vocal fry (creaky voice), especially at the ends of sentences. This is a highly speaker-specific trait that can be detected at very short timescales — even a single word spoken with vocal fry can identify the speaker.

### 7.17 Court audio channel exploitation

Many courtrooms record on multi-track systems (separate channels for bench mic, podium mic, witness box mic, counsel table mics). If you can obtain the multi-channel recording rather than a mixdown, each channel's gain level directly indicates speaker proximity. Even if all channels are mixed, the original channel routing metadata (if available in the WAV header) can be informative.

### 7.18 Backchanneling detection model

"Mmhmm," "right," "yes" — these backchannel responses are exactly the interjections you're missing. They have distinctive acoustic properties: short duration, falling intonation, low energy relative to the primary speaker. A dedicated backchannel detector (which can be trained or rule-based) could find these before the diarization stage and feed them in as known short-speaker events.

```python
def detect_backchannels(words, audio, sr):
    """
    Find words that are likely backchannels based on:
    - Duration < 500ms
    - Common backchannel vocabulary
    - Low energy relative to surrounding speech
    """
    backchannel_vocab = {
        "yes", "yeah", "yep", "no", "nope",
        "right", "correct", "okay", "ok",
        "mmhmm", "uh-huh", "mm", "hmm",
        "sure", "true", "understood",
    }
    
    candidates = []
    for word in words:
        duration = word["end"] - word["start"]
        text_clean = word["text"].lower().strip(".,!?")
        
        if duration < 0.5 and text_clean in backchannel_vocab:
            # Compute energy ratio vs surrounding 2 seconds
            word_energy = compute_rms(audio, sr, word["start"], word["end"])
            context_energy = compute_rms(
                audio, sr,
                max(0, word["start"] - 1.0),
                word["end"] + 1.0
            )
            energy_ratio = word_energy / (context_energy + 1e-10)
            
            candidates.append({
                **word,
                "is_backchannel": True,
                "energy_ratio": energy_ratio,
                # Low energy ratio suggests different speaker
                # (further from mic, or quieter voice)
                "likely_different_speaker": energy_ratio < 0.7,
            })
    
    return candidates
```

### 7.19 Use the court reporter's transcript as ground truth for calibration

If a court reporter transcript exists (even an imperfect one), it can be used to calibrate and evaluate your diarization system. Court reporters mark speaker changes explicitly. Align the reporter's transcript with your automated transcript and you instantly have labeled training/evaluation data specific to this exact audio environment.

### 7.20 Acoustic room fingerprinting across hearings

If you process multiple hearings from the same courtroom, the room acoustics create consistent spatial signatures. The judge always sits in the same position, attorneys at the same tables. Over multiple hearings, you can build a model of the acoustic transfer function from each position, then use that to identify speaker position (and therefore role) in new hearings from the same room.

---

## 8. Architecture Decision Record

**Decision**: Pursue word-level diarization via frame-level pyannote posteriors as primary path, with NeMo MSDD as experimental comparison.

**Context**: Segment-level diarization misses short interjections common in legal proceedings. Pyannote 4.0 community-1 is already in use and produces frame-level posteriors internally but exposes only segment-level output by default.

**Rationale**: Accessing frame-level posteriors is the lowest-effort change with highest expected impact. NeMo MSDD's multi-scale approach is theoretically better for interjections but requires significant setup effort on Apple Silicon. Speech separation is promising but may degrade ASR quality.

**Status**: In progress. This document should be updated as approaches are tested.
