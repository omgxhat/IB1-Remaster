#!/usr/bin/env python3
"""Puts replaced game files' real sizes into the app's file tables (IPhoneTOC*.txt: "size 0 0 path 0" per file), so
the game reads a changed file in full. Usage: toc_update.py <app folder> <file inside the app> [...]"""
import sys, os, glob
app = sys.argv[1]
for rel in sys.argv[2:]:
    size = os.path.getsize(os.path.join(app, rel)); key = '..\\SwordGame\\' + rel.replace('/', '\\')
    for toc in glob.glob(os.path.join(app, 'IPhoneTOC*.txt')):
        lines = open(toc, 'rb').read().decode('latin-1').split('\n'); n = 0
        for i, l in enumerate(lines):
            parts = l.rstrip('\r').split(' ')
            if len(parts) >= 5 and parts[3].lower() == key.lower():
                parts[0] = str(size); lines[i] = ' '.join(parts) + ('\r' if l.endswith('\r') else ''); n += 1
        if n: open(toc, 'wb').write('\n'.join(lines).encode('latin-1'))
