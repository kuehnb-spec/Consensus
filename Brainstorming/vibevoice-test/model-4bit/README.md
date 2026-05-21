---
language:
- en
- zh
license: mit
pipeline_tag: automatic-speech-recognition
tags:
- ASR
- Transcriptoin
- Diarization
- Speech-to-Text
- mlx
- speech-to-text
- speech
- transcription
- asr
- stt
- mlx-audio
library_name: mlx-audio
---
# mlx-community/VibeVoice-ASR-4bit

This model was converted to MLX format from [`microsoft/VibeVoice-ASR`](https://huggingface.co/microsoft/VibeVoice-ASR) using mlx-audio version **0.3.0**.

Refer to the [original model card](https://huggingface.co/microsoft/VibeVoice-ASR) for more details on the model.

## Use with mlx-audio

```bash
pip install -U mlx-audio
```

### CLI Example:
```bash
python -m mlx_audio.stt.generate --model mlx-community/VibeVoice-ASR-4bit --audio "audio.wav"
```

### Python Example:
```python        
from mlx_audio.stt.utils import load_model
from mlx_audio.stt.generate import generate_transcription

model = load_model("mlx-community/VibeVoice-ASR-4bit")
transcription = generate_transcription(
    model=model,
    audio_path="path_to_audio.wav",
    output_path="path_to_output.txt",
    format="txt",
    verbose=True,
)
print(transcription.text)

```
