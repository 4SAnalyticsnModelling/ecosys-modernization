"""Keep fixtures and subprocess caches inside the repository."""
import os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]

def pytest_configure(config):
    if not config.option.basetemp:
        config.option.basetemp=str(ROOT/'.tmp/pytest-workflow')
