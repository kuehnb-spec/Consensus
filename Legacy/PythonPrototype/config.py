"""
Transcribo - Persistent configuration management.
Stores settings in ~/.transcribo/config.json.
"""

import json
import os
from pathlib import Path

CONFIG_DIR = Path.home() / ".transcribo"
CONFIG_FILE = CONFIG_DIR / "config.json"

_defaults = {
    "hf_token": "",
}


def _ensure_dir():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_config() -> dict:
    """Load config from disk, returning defaults for missing keys."""
    config = dict(_defaults)
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE) as f:
                stored = json.load(f)
            config.update(stored)
        except (json.JSONDecodeError, OSError):
            pass
    return config


def save_config(config: dict):
    """Write config to disk."""
    _ensure_dir()
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


def get_hf_token() -> str:
    """Get HuggingFace token from config or environment."""
    env_token = os.environ.get("HF_TOKEN", "")
    if env_token:
        return env_token
    return load_config().get("hf_token", "")


def save_hf_token(token: str):
    """Persist HuggingFace token to config."""
    config = load_config()
    config["hf_token"] = token
    save_config(config)
