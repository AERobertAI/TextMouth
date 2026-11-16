"""testkit_path.py: importing it puts Scripts/test on the path, so a test can import testkit."""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "test"))
