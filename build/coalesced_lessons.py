#!/usr/bin/env python3
"""coalesced_lessons.py <CookedIPhone folder> [--check]: puts our layouts of lesson pages (tools/lessons/<Tag>.txt, the
page's lines as in SwordTutorial.ini: its Tutorial= line, then its Element= lines) into every settings file
(Coalesced_*.bin, all 26, both the game's and the _full copies) in that folder, in place of the devs' lines for that page
in [SwordGame.SwordTutorialPopup] of SwordTutorial.ini. A lesson page is a run of keys in order (Tutorial=, then
Element=, Translate=, Alpha= ...), which tools/coalesced_patch.py (one value per key name) can't express.
Each file is read and rebuilt byte for byte first (a check of the reader), and the page it replaces must be exactly the
devs' (tools/lessons/<Tag>.devs.txt, saved the first time), so a second run or a changed game is caught. With --check,
nothing is written: it says what each file holds now. Written 25 October 2026 for Info2 (FIXES.md 65): the devs never
shipped that page and it was never fitted to the finished screen, so on the iPhone 17 its labels sat on the HUD's numbers,
the enemy's name and the potion count.
Run on assets-cooked/CookedIPhone (already holding the graphics settings, FIXES.md 32); build.sh copies those files into
every build and fixes their sizes in the file tables."""
import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coalesced_patch import read, write

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lessons')
SEC = 'SwordGame.SwordTutorialPopup'

def lines_of(path):
    out = []
    for l in open(path, encoding='latin-1'):
        l = l.rstrip('\r\n')
        if l and '=' in l: k, v = l.split('=', 1); out.append((k, v))
    return out

def page_span(keys, tag):
    start = next((i for i, ((k, _), (v, _)) in enumerate(keys) if k == 'Tutorial' and v.replace(' ', '').startswith('(Tag=%s,' % tag)), None)
    if start is None: return None
    end = next((i for i in range(start + 1, len(keys)) if keys[i][0][0] == 'Tutorial'), len(keys))
    return start, end

def main():
    folder = sys.argv[1]; check = '--check' in sys.argv
    tags = [os.path.basename(p)[:-4] for p in sorted(glob.glob(os.path.join(D, '*.txt'))) if not p.endswith('.devs.txt')]
    for path in sorted(glob.glob(os.path.join(folder, 'Coalesced_*.bin'))):
        raw = open(path, 'rb').read(); files = read(path)
        assert write(files) == raw, 'reader does not rebuild ' + path
        f = [x for x in files if x[0][0].replace('/', '\\').lower().endswith('swordtutorial.ini')]
        if not f: print('%s: no SwordTutorial.ini' % os.path.basename(path)); continue
        sec = [s for s in f[0][1] if s[0][0] == SEC]
        if not sec: print('%s: no [%s]' % (os.path.basename(path), SEC)); continue
        keys = sec[0][1]; notes = []
        for tag in tags:
            span = page_span(keys, tag)
            if not span: notes.append('%s missing' % tag); continue
            now = [(k[0], v[0]) for k, v in keys[span[0]:span[1]]]
            ours = lines_of(os.path.join(D, tag + '.txt'))
            devs_path = os.path.join(D, tag + '.devs.txt')
            if not os.path.exists(devs_path) and now != ours:
                open(devs_path, 'w', encoding='latin-1').write(''.join('%s=%s\n' % kv for kv in now))
            devs = lines_of(devs_path)
            if now == ours: notes.append('%s already ours' % tag); continue
            if now != devs: notes.append('%s NOT the devs\' page: left alone' % tag); continue
            notes.append('%s replaced (%d -> %d lines)' % (tag, len(now), len(ours)))
            keys[span[0]:span[1]] = [((k, 1), (v, 1)) for k, v in ours]
        if not check and any('replaced' in n for n in notes):
            out = write(files); open(path, 'wb').write(out); assert read(path) is not None
        print('%-26s %s' % (os.path.basename(path), '; '.join(notes)))

if __name__ == '__main__':
    main()
