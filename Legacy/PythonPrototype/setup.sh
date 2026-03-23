#!/bin/bash
# Setup script for Hearing Transcriber on macOS (Apple Silicon)
set -e

echo "═══════════════════════════════════════════════════"
echo "  Hearing Transcriber — Setup"
echo "═══════════════════════════════════════════════════"
echo ""

# Check for Python 3.10+
PYTHON_CMD=""
for cmd in python3.12 python3.11 python3.10 python3; do
    if command -v $cmd &> /dev/null; then
        version=$($cmd -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        major=$(echo $version | cut -d. -f1)
        minor=$(echo $version | cut -d. -f2)
        if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
            PYTHON_CMD=$cmd
            break
        fi
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    echo "❌ Python 3.10+ is required. Install with:"
    echo "   brew install python@3.12"
    exit 1
fi
echo "✓ Found $PYTHON_CMD ($($PYTHON_CMD --version))"

# Check for ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo ""
    echo "⚠️  ffmpeg not found. Installing with Homebrew..."
    if command -v brew &> /dev/null; then
        brew install ffmpeg
    else
        echo "❌ ffmpeg is required. Install with:"
        echo "   brew install ffmpeg"
        exit 1
    fi
fi
echo "✓ Found ffmpeg"

# Create virtual environment
VENV_DIR=".venv"
if [ ! -d "$VENV_DIR" ]; then
    echo ""
    echo "Creating virtual environment..."
    $PYTHON_CMD -m venv $VENV_DIR
fi
echo "✓ Virtual environment ready"

# Activate and install
echo ""
echo "Installing dependencies (this may take a few minutes)..."
source $VENV_DIR/bin/activate

# Install PyTorch for Apple Silicon first
pip install --upgrade pip
pip install torch torchaudio

# Install whisperx (includes pyannote)
pip install git+https://github.com/m-bain/whisperX.git

# Install gradio for the web UI
pip install "gradio>=4.0"

# Install python-docx for Word export
pip install python-docx

echo ""
echo "═══════════════════════════════════════════════════"
echo "  ✅ Setup complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Before first use, you need a HuggingFace token:"
echo "  1. Sign up at https://huggingface.co"
echo "  2. Create a token at https://huggingface.co/settings/tokens"
echo "  3. Accept model licenses:"
echo "     https://huggingface.co/pyannote/segmentation-3.0"
echo "     https://huggingface.co/pyannote/speaker-diarization-3.1"
echo ""
echo "Then set your token:"
echo "  export HF_TOKEN=hf_your_token_here"
echo ""
echo "Usage:"
echo "  # Web UI (drag and drop):"
echo "  source .venv/bin/activate"
echo "  python app.py"
echo ""
echo "  # Command line:"
echo "  source .venv/bin/activate"
echo "  python transcribe.py recording.m4a --min-speakers 3 --max-speakers 6"
echo ""
