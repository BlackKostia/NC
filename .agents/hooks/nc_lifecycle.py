#!/usr/bin/env python3
"""Compatibility shim delegating to duop_lifecycle.py."""
from duop_lifecycle import main
if __name__ == "__main__":
    raise SystemExit(main())
