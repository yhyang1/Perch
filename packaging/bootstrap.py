"""Bundled bridge entry point; launched with Python -I -S -B -u."""
import asyncio
from pathlib import Path
import sys

# Isolated mode deliberately excludes cwd and the script directory. Admit only
# the application-controlled package next to this entry point, never PERCH_ROOT.
root = Path(__file__).resolve().parent
if not (root / 'perch' / 'bridge.py').is_file():
    raise SystemExit('The bundled Perch bridge is missing. Reinstall the application.')
sys.path.insert(0, str(root))
from perch.bridge import main

try:
    asyncio.run(main())
except asyncio.CancelledError:
    pass
