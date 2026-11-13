#!/usr/bin/env python3
"""Puts replaced game files' real sizes into the app's file tables (IPhoneTOC*.txt: "size 0 0 path 0" per file), so
the game reads a changed file in full. Usage: toc_update.py <app folder> <file inside the app> [...]
A file that no table lists is reported on stderr (its size can't be updated, so the game would read it at the old one)."""
import sys, os, glob
app = sys.argv[1]
tocs = glob.glob(os.path.join(app, 'IPhoneTOC*.txt'))
for rel in sys.argv[2:]:
    size = os.path.getsize(os.path.join(app, rel)); key = '..\\SwordGame\\' + rel.replace('/', '\\')
    total = 0
    for toc in tocs:
        lines = open(toc, 'rb').read().decode('latin-1').split('\n'); n = 0
        for i, l in enumerate(lines):
            parts = l.rstrip('\r').split(' ')
            # "size 0 0 <path> 0": the path may hold spaces, so it is everything between the third field and the last
            if len(parts) >= 5 and ' '.join(parts[3:-1]).lower() == key.lower():
                parts[0] = str(size); lines[i] = ' '.join(parts) + ('\r' if l.endswith('\r') else ''); n += 1
        if n: open(toc, 'wb').write('\n'.join(lines).encode('latin-1'))
        total += n
    if not total:
        print('toc_update: %s is in none of the %d file table(s): its size was not updated' % (rel, len(tocs)), file=sys.stderr)
