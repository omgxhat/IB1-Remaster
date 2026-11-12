#!/usr/bin/env python3
"""Changes settings inside the game's settings files (CookedIPhone/Coalesced_<language>.bin, one per language; format
in tools/coalesced.py) and writes the patched copies plus the matching lines for the file table (IPhoneTOC.txt lists
every file's size). Unchanged keys keep their order; a key given here replaces every copy of that key in the section,
or is added at its end.
Usage: coalesced_patch.py <patch.json> <CookedIPhone folder> <out folder>
patch.json: {"SwordGame\\Config\\IPhone-SwordEngine.ini": {"SystemSettingsIPhone3GS": {"MaxAnisotropy": "16", ...}}}
(an ini is matched by the end of its stored name; a section that doesn't exist is added)"""
import sys, os, glob, struct, json

def read(path):
    d = open(path, 'rb').read(); p = 0
    def i32():
        nonlocal p; v, = struct.unpack_from('<i', d, p); p += 4; return v
    def fstr():
        nonlocal p; n = i32()
        if n == 0: return ('', 0)
        if n > 0: s = d[p:p+n]; p += n; return (s[:-1].decode('latin-1'), 1)
        s = d[p:p-2*n]; p += -2*n; return (s[:-2].decode('utf-16-le'), 2)
    files = []
    for _ in range(i32()):
        name = fstr(); secs = []
        for _ in range(i32()):
            sec = fstr(); keys = [(fstr(), fstr()) for _ in range(i32())]
            secs.append([sec, keys])
        files.append([name, secs])
    assert p == len(d), (p, len(d))
    return files

def write(files):
    out = bytearray()
    def i32(v): out.extend(struct.pack('<i', v))
    def fstr(s):
        text, kind = s
        if kind == 0 and not text: i32(0)
        elif kind == 2 or any(ord(c) > 255 for c in text):
            b = (text + '\0').encode('utf-16-le'); i32(-(len(b) // 2)); out.extend(b)
        else:
            b = (text + '\0').encode('latin-1'); i32(len(b)); out.extend(b)
    i32(len(files))
    for name, secs in files:
        fstr(name); i32(len(secs))
        for sec, keys in secs:
            fstr(sec); i32(len(keys))
            for k, v in keys: fstr(k); fstr(v)
    return bytes(out)

def patch(files, spec):
    for ini, sections in spec.items():
        f = [x for x in files if x[0][0].replace('/', '\\').lower().endswith(ini.replace('/', '\\').lower())]
        if not f: raise SystemExit('no ' + ini)
        secs = f[0][1]
        for sec, keys in sections.items():
            s = [x for x in secs if x[0][0] == sec]
            if not s: secs.append([(sec, 1), []]); s = [secs[-1]]
            kv = s[0][1]
            for k, v in keys.items():
                at = [i for i, (kk, _) in enumerate(kv) if kk[0] == k]
                if at:
                    kv[at[0]] = ((k, 1), (v, 1))
                    for i in reversed(at[1:]): del kv[i]
                else: kv.append(((k, 1), (v, 1)))

if __name__ == '__main__':
    spec = json.load(open(sys.argv[1])); src, out = sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True); toc = []
    for path in sorted(glob.glob(os.path.join(src, 'Coalesced_*.bin'))):
        files = read(path)
        assert write(files) == open(path, 'rb').read(), 'round trip differs: ' + path    # the writer is exact
        patch(files, spec)
        data = write(files); name = os.path.basename(path)
        open(os.path.join(out, name), 'wb').write(data)
        toc.append('%d 0 0 ..\\SwordGame\\CookedIPhone\\%s 0' % (len(data), name))
    open(os.path.join(out, 'toc-lines.txt'), 'w').write('\n'.join(toc) + '\n')
    print('patched', len(toc), 'files')
