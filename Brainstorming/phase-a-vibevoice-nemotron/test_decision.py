"""Unit tests for the standard-of-proof decision logic.

These don't exercise the model — just the decision function and the trivial-diff
filter. Run before we test on real audio so we know the principle is encoded
correctly.
"""

from __future__ import annotations
import sys
sys.path.insert(0, ".")
from run_phase_a import is_trivial_diff, decide, normalize_for_comparison


def test_trivial_diff_punctuation():
    assert is_trivial_diff("Hello, world.", "Hello world")
    assert is_trivial_diff("It's me!", "Its me")


def test_trivial_diff_case():
    assert is_trivial_diff("john smith", "John Smith")


def test_trivial_diff_fillers():
    # Only narrow non-content fillers ("uh", "um", etc.) and phrases ("you know",
    # "i mean") get stripped. Words like "well", "like", "right", "so" can carry
    # meaning, so they are NOT in the filler set — and that's deliberate.
    assert is_trivial_diff(
        "Uh, I think we should go.",
        "I think we should go.",
    )
    assert is_trivial_diff(
        "You know, I mean, this is fine.",
        "This is fine.",
    )
    # Negative case: "well" is not a filler in our list because it can mean
    # "in good condition." So removing it MUST count as a substantive change
    # the threshold has to clear.
    assert not is_trivial_diff(
        "It went well.",
        "It went.",
    )


def test_trivial_diff_contractions():
    assert is_trivial_diff("I won't be there.", "I will not be there.")
    assert is_trivial_diff("You're correct.", "You are correct.")


def test_trivial_diff_numbers():
    assert is_trivial_diff("It's 100% done.", "It's hundred percent done")


def test_substantive_diff_wrong_word():
    # "Branickin" vs "Brant Kuehn" — clearly different, NOT trivial
    assert not is_trivial_diff(
        "Hello, this is Branickin.",
        "Hello, this is Brant Kuehn.",
    )


def test_substantive_diff_missing_phrase():
    assert not is_trivial_diff(
        "I'll see you at the meeting.",
        "I'll see you at the meeting next Tuesday.",
    )


def test_substantive_diff_wrong_name():
    assert not is_trivial_diff("Hi Maria.", "Hi Marie.")


def test_decide_keep_when_trivial_even_high_conf():
    """The trivial filter must override even high-confidence Nemotron verdicts."""
    parsed = {
        "correct": False,
        "confidence_wrong": 0.99,
        "corrected": "Hello world",  # only punctuation diff
        "evidence": "I hear it without a comma after Hello",
    }
    apply, reason = decide("Hello, world", parsed, threshold=0.75)
    assert apply is False
    assert "trivial_diff" in reason


def test_decide_keep_when_below_threshold():
    parsed = {
        "correct": False,
        "confidence_wrong": 0.50,
        "corrected": "Hello, this is Brant Kuehn.",
        "evidence": "Speaker clearly enunciates 'Brant Kuehn' as two words.",
    }
    apply, reason = decide("Hello, this is Branickin.", parsed, threshold=0.75)
    assert apply is False
    assert "below_threshold" in reason


def test_decide_keep_when_no_evidence():
    parsed = {
        "correct": False,
        "confidence_wrong": 0.95,
        "corrected": "Hello, this is Brant Kuehn.",
        "evidence": "",
    }
    apply, reason = decide("Hello, this is Branickin.", parsed, threshold=0.75)
    assert apply is False
    assert reason == "missing_evidence"


def test_decide_keep_when_evidence_too_short():
    parsed = {
        "correct": False,
        "confidence_wrong": 0.95,
        "corrected": "Hello, this is Brant Kuehn.",
        "evidence": "wrong",
    }
    apply, reason = decide("Hello, this is Branickin.", parsed, threshold=0.75)
    assert apply is False
    assert "evidence_too_short" in reason


def test_decide_keep_when_nemotron_says_correct():
    parsed = {
        "correct": True,
        "confidence_wrong": 0.0,
        "corrected": "",
        "evidence": "",
    }
    apply, reason = decide("anything", parsed, threshold=0.75)
    assert apply is False
    assert reason == "nemotron_says_correct"


def test_decide_apply_when_all_conditions_met():
    """The only path that overrides VibeVoice."""
    parsed = {
        "correct": False,
        "confidence_wrong": 0.92,
        "corrected": "Hello, this is Brant Kuehn.",
        "evidence": "Speaker clearly enunciates 'Brant Kuehn' as two distinct words; the candidate runs them together as 'Branickin'.",
    }
    apply, reason = decide("Hello, this is Branickin.", parsed, threshold=0.75)
    assert apply is True
    assert reason == ""


def test_decide_apply_at_exact_threshold():
    parsed = {
        "correct": False,
        "confidence_wrong": 0.75,
        "corrected": "Hi Marie",
        "evidence": "Speaker says 'Marie' not 'Maria' — the final vowel is short 'ee'.",
    }
    apply, _ = decide("Hi Maria", parsed, threshold=0.75)
    assert apply is True


# ---------------------------------------------------------------------------

def run_all():
    tests = [
        (name, fn) for name, fn in globals().items()
        if name.startswith("test_") and callable(fn)
    ]
    passed = failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"  PASS  {name}")
            passed += 1
        except AssertionError as e:
            print(f"  FAIL  {name}: {e}")
            failed += 1
        except Exception as e:
            print(f"  ERR   {name}: {type(e).__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(run_all())
