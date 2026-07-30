#!/bin/bash
# Consensus local engine — installer for a fresh Apple Silicon Mac.
#
# Installs the `consensus` binary, the VibeVoice sidecar, a Python environment,
# and the 4-bit MLX model, then writes ~/.consensus/config.toml pointing at them.
# Re-runnable: existing pieces are left alone unless --reinstall is given.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
# Overridable so the environment can live on external storage — and so the
# installer itself can be tested without touching a working setup.
CONSENSUS_HOME="${CONSENSUS_HOME:-$HOME/.consensus}"
MODEL_REPO="mlx-community/VibeVoice-ASR-4bit"
REINSTALL=false
SKIP_MODEL=false

for arg in "$@"; do
  case "$arg" in
    --reinstall) REINSTALL=true ;;
    --skip-model) SKIP_MODEL=true ;;
    -h|--help)
      echo "usage: ./install.sh [--reinstall] [--skip-model]"
      echo "  PREFIX=<dir>   where to install the binary (default: ~/.local/bin)"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n==> %s\n' "$1"; }

# --- Preconditions --------------------------------------------------------
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: Consensus requires Apple Silicon (found $(uname -m))." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found. Install Xcode command line tools: xcode-select --install" >&2
  exit 1
fi

say "Installing binary to $PREFIX"
mkdir -p "$PREFIX"
cp "$SOURCE_DIR/consensus" "$PREFIX/consensus"
chmod +x "$PREFIX/consensus"
# Downloads carry a quarantine flag; without this macOS refuses to run it.
xattr -d com.apple.quarantine "$PREFIX/consensus" 2>/dev/null || true

say "Installing sidecar to $CONSENSUS_HOME/sidecar"
mkdir -p "$CONSENSUS_HOME/sidecar"
cp "$SOURCE_DIR/VibeVoiceSidecar/run.py" "$CONSENSUS_HOME/sidecar/run.py"

# --- Python environment ---------------------------------------------------
VENV="$CONSENSUS_HOME/venv"
if [[ -x "$VENV/bin/python" && "$REINSTALL" == false ]]; then
  say "Python environment already present (use --reinstall to rebuild)"
else
  say "Creating Python environment (this pulls ~700 MB of wheels)"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  "$VENV/bin/python" -m pip install --quiet -r "$SOURCE_DIR/requirements.txt"
fi

# --- Model ----------------------------------------------------------------
MODEL_DIR="$CONSENSUS_HOME/models/vibevoice-asr-4bit"
if [[ "$SKIP_MODEL" == true ]]; then
  say "Skipping model download (--skip-model); set CONSENSUS_MODEL or edit config.toml"
elif [[ -d "$MODEL_DIR" && "$REINSTALL" == false ]]; then
  say "Model already present at $MODEL_DIR"
else
  say "Downloading model $MODEL_REPO (~5.3 GB — this takes a while)"
  mkdir -p "$(dirname "$MODEL_DIR")"
  "$VENV/bin/python" -m pip install --quiet "huggingface_hub[cli]"
  "$VENV/bin/hf" download "$MODEL_REPO" --local-dir "$MODEL_DIR"
fi

# --- Config ---------------------------------------------------------------
CONFIG="$CONSENSUS_HOME/config.toml"
if [[ -f "$CONFIG" && "$REINSTALL" == false ]]; then
  say "Keeping existing $CONFIG"
else
  say "Writing $CONFIG"
  cat > "$CONFIG" <<CONFIG_EOF
# Consensus local-engine configuration (written by install.sh).
# Environment variables CONSENSUS_PYTHON / CONSENSUS_SIDECAR / CONSENSUS_MODEL
# override anything set here.

[paths]
python  = "$VENV/bin/python"
sidecar = "$CONSENSUS_HOME/sidecar/run.py"
model   = "$MODEL_DIR"
CONFIG_EOF
fi

say "Verifying"
if ! CONSENSUS_CONFIG="$CONFIG" "$PREFIX/consensus" doctor; then
  echo ""
  if [[ "$SKIP_MODEL" == true ]]; then
    # Expected: --skip-model means the caller is supplying the model themselves.
    echo "Install complete. Point CONSENSUS_MODEL (or config.toml) at your model copy."
  else
    echo "Install finished but the environment check failed — see the items above." >&2
    exit 1
  fi
fi

cat <<DONE

Installed. If '$PREFIX' is not on your PATH, add it:
    echo 'export PATH="$PREFIX:\$PATH"' >> ~/.zshrc

Then:
    consensus transcribe /path/to/recording.m4a
DONE
