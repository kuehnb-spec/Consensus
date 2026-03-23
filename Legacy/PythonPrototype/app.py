#!/usr/bin/env python3
"""
Transcribo - Web UI
Drag-and-drop audio files for local transcription with speaker diarization.
Two-phase workflow: transcribe, then name speakers and export.
"""

import json
import tempfile
from pathlib import Path

import gradio as gr

from config import get_hf_token, save_hf_token
from transcribe import (
    transcribe_audio,
    format_transcript_text,
    format_transcript_markdown,
    format_transcript_srt,
    format_transcript_rtf,
    save_transcript_docx,
    format_timestamp,
    save_outputs,
)

# Maximum number of speaker rename fields we pre-create in the UI.
MAX_SPEAKERS = 12


def _get_speaker_samples(result: dict) -> dict[str, str]:
    """Extract a short sample quote for each detected speaker."""
    samples = {}
    for seg in result.get("segments", []):
        spk = seg.get("speaker", "UNKNOWN")
        text = seg.get("text", "").strip()
        if spk not in samples and text:
            # Take first ~120 chars as a sample
            samples[spk] = text[:120] + ("..." if len(text) > 120 else "")
    return samples


def run_transcription(
    audio_file,
    model_size,
    min_speakers,
    max_speakers,
    hf_token,
    save_token,
    progress=gr.Progress(),
):
    """Run transcription pipeline. Returns data for phase 2."""
    if audio_file is None:
        raise gr.Error("No audio file provided.")

    # Resolve token
    token = hf_token.strip() if hf_token else get_hf_token()
    if not token:
        raise gr.Error(
            "No HuggingFace token provided. "
            "Get one free at https://huggingface.co/settings/tokens"
        )

    # Persist token if requested
    if save_token and token:
        save_hf_token(token)

    min_spk = int(min_speakers) if min_speakers and int(min_speakers) > 0 else None
    max_spk = int(max_speakers) if max_speakers and int(max_speakers) > 0 else None

    progress(0.1, desc="Loading audio...")

    try:
        progress(0.2, desc="Transcribing with Whisper...")
        result = transcribe_audio(
            audio_path=audio_file,
            model_size=model_size,
            hf_token=token,
            min_speakers=min_spk,
            max_speakers=max_spk,
            language="en",
        )

        progress(0.95, desc="Preparing results...")

        # Detect speakers and collect samples
        speakers = sorted(set(
            seg.get("speaker", "UNKNOWN") for seg in result["segments"]
        ))
        samples = _get_speaker_samples(result)
        duration = format_timestamp(result["duration"])

        # Build status header
        header = (
            f"Transcription complete  |  "
            f"Duration: {duration}  |  "
            f"Speakers: {len(speakers)}  |  "
            f"Model: {model_size}"
        )

        # Preview transcript
        preview = format_transcript_text(result)

        # Store result as JSON in a hidden state
        result_json = json.dumps(result, default=str)

        # Build speaker rename field updates: show detected speakers, hide the rest
        speaker_updates = []
        for i in range(MAX_SPEAKERS):
            if i < len(speakers):
                spk = speakers[i]
                sample = samples.get(spk, "")
                speaker_updates.append(gr.update(
                    visible=True,
                    value=spk,
                    label=f"{spk}",
                    info=f'Sample: "{sample}"',
                ))
            else:
                speaker_updates.append(gr.update(visible=False, value=""))

        progress(1.0, desc="Done!")

        return [
            header,               # status_text
            preview,              # transcript_preview
            result_json,          # result_state
            gr.update(visible=True),   # speaker_section visibility
            gr.update(visible=True),   # export_section visibility
        ] + speaker_updates

    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        print(f"\n{'='*60}\nERROR TRACEBACK:\n{'='*60}\n{tb}\n{'='*60}")
        error_msg = str(e)
        if "pyannote" in error_msg.lower() or "401" in error_msg:
            error_msg += (
                "\n\nLikely cause: invalid token or missing PyAnnote license. "
                "Accept at: https://huggingface.co/pyannote/segmentation-3.0 "
                "and https://huggingface.co/pyannote/speaker-diarization-3.1"
            )
        # Include traceback snippet in the UI error for debugging
        error_msg += f"\n\nFull traceback (check terminal for details):\n{tb[-500:]}"
        raise gr.Error(error_msg)


def apply_speaker_names(result_json, *speaker_fields):
    """Apply renamed speakers and update transcript preview."""
    if not result_json:
        raise gr.Error("No transcription data. Run a transcription first.")

    result = json.loads(result_json)
    speakers = sorted(set(
        seg.get("speaker", "UNKNOWN") for seg in result["segments"]
    ))

    # Build name mapping from the filled-in fields
    speaker_names = {}
    for i, spk in enumerate(speakers):
        if i < len(speaker_fields) and speaker_fields[i].strip():
            new_name = speaker_fields[i].strip()
            if new_name != spk:
                speaker_names[spk] = new_name

    preview = format_transcript_text(result, speaker_names=speaker_names)

    # Store the mapping as JSON alongside result
    names_json = json.dumps(speaker_names)

    return preview, names_json


def export_all(result_json, names_json):
    """Generate all export files and return paths for download."""
    if not result_json:
        raise gr.Error("No transcription data.")

    result = json.loads(result_json)
    speaker_names = json.loads(names_json) if names_json else {}

    base_name = Path(result.get("audio_path", "audio")).stem
    tmp_dir = tempfile.mkdtemp(prefix="transcribo_export_")

    paths = save_outputs(result, tmp_dir, base_name, speaker_names=speaker_names)

    return (
        paths.get("txt"),
        paths.get("md"),
        paths.get("json"),
        paths.get("srt"),
        paths.get("rtf"),
        paths.get("docx"),
    )


# ── Build the Gradio UI ──

with gr.Blocks(title="Transcribo") as app:

    # ── Hidden state ──
    result_state = gr.State("")
    names_state = gr.State("")

    # ── Header ──
    gr.Markdown(
        """
        # Transcribo
        **Local audio transcription with speaker diarization** — nothing leaves your machine.

        Upload an audio file, transcribe it, name the speakers, and export.
        """,
        elem_classes="header",
    )

    # ══════════════════════════════════════════════
    # PHASE 1: Transcription Settings
    # ══════════════════════════════════════════════
    with gr.Row():
        with gr.Column(scale=1):
            audio_input = gr.Audio(
                label="Audio File",
                type="filepath",
                sources=["upload"],
            )
            model_size = gr.Dropdown(
                label="Model Size",
                choices=["tiny", "base", "small", "medium", "large-v3"],
                value="large-v3",
                info="large-v3 = best accuracy, small = fastest",
            )
            with gr.Row():
                min_speakers = gr.Number(
                    label="Min Speakers", value=2, minimum=0, maximum=20, step=1,
                    info="0 = auto-detect",
                )
                max_speakers = gr.Number(
                    label="Max Speakers", value=6, minimum=0, maximum=20, step=1,
                    info="0 = auto-detect",
                )
            hf_token = gr.Textbox(
                label="HuggingFace Token",
                type="password",
                placeholder="hf_... (or set HF_TOKEN env var)",
                value=get_hf_token(),
                info="Required for speaker diarization",
            )
            save_token = gr.Checkbox(
                label="Remember token for next time",
                value=True,
            )
            transcribe_btn = gr.Button("Transcribe", variant="primary", size="lg")

        with gr.Column(scale=2):
            status_text = gr.Markdown("")
            transcript_preview = gr.Textbox(
                label="Transcript Preview",
                lines=25,
                interactive=False,
            )

    # ══════════════════════════════════════════════
    # PHASE 2: Speaker Naming
    # ══════════════════════════════════════════════
    with gr.Group(visible=False) as speaker_section:
        gr.Markdown("### Name the Speakers")
        gr.Markdown(
            "Replace the generic labels below with real names. "
            "A sample quote is shown for each speaker to help you identify them."
        )

        speaker_fields = []
        # Create fields in rows of 3
        for row_start in range(0, MAX_SPEAKERS, 3):
            with gr.Row():
                for i in range(row_start, min(row_start + 3, MAX_SPEAKERS)):
                    field = gr.Textbox(
                        label=f"Speaker {i}",
                        visible=False,
                        elem_classes="speaker-field",
                    )
                    speaker_fields.append(field)

        apply_names_btn = gr.Button("Apply Names & Update Preview", variant="secondary")

    # ══════════════════════════════════════════════
    # PHASE 2: Export
    # ══════════════════════════════════════════════
    with gr.Group(visible=False) as export_section:
        gr.Markdown("### Export Transcript")
        export_btn = gr.Button("Generate All Export Files", variant="primary")

        with gr.Row():
            dl_txt = gr.File(label="Text (.txt)")
            dl_md = gr.File(label="Markdown (.md)")
            dl_json = gr.File(label="JSON (.json)")
        with gr.Row():
            dl_srt = gr.File(label="SRT Subtitles (.srt)")
            dl_rtf = gr.File(label="Rich Text (.rtf)")
            dl_docx = gr.File(label="Word (.docx)")

    # ── Footer ──
    gr.Markdown(
        """
        ---
        **Tips:**
        Set min/max speakers if you know the count for better accuracy.
        `large-v3` is best for legal/technical terminology.
        `small` is ~10x faster for quick drafts.
        First-time? Get a free [HuggingFace token](https://huggingface.co/settings/tokens)
        and accept the [segmentation](https://huggingface.co/pyannote/segmentation-3.0)
        and [diarization](https://huggingface.co/pyannote/speaker-diarization-3.1) model licenses.
        """
    )

    # ── Wire up events ──

    transcribe_btn.click(
        fn=run_transcription,
        inputs=[audio_input, model_size, min_speakers, max_speakers, hf_token, save_token],
        outputs=[
            status_text,
            transcript_preview,
            result_state,
            speaker_section,
            export_section,
        ] + speaker_fields,
    )

    apply_names_btn.click(
        fn=apply_speaker_names,
        inputs=[result_state] + speaker_fields,
        outputs=[transcript_preview, names_state],
    )

    export_btn.click(
        fn=export_all,
        inputs=[result_state, names_state],
        outputs=[dl_txt, dl_md, dl_json, dl_srt, dl_rtf, dl_docx],
    )


if __name__ == "__main__":
    app.launch(
        server_name="127.0.0.1",
        server_port=7860,
        share=False,
        inbrowser=True,
        theme=gr.themes.Soft(),
        css="""
        .transcript-box textarea {
            font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
            font-size: 13px;
            line-height: 1.6;
        }
        .header { text-align: center; margin-bottom: 1em; }
        """,
    )
