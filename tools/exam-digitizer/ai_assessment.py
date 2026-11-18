"""CLI facade for the shared source-bound assessment contract."""
from pathlib import Path
import sys

ROOT = str(Path(__file__).resolve().parents[2])
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
from backend.exams.assessment_contract import *  # noqa: F401,F403,E402
