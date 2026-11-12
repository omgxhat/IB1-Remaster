# coalesced.py <Coalesced_XXX.bin> <out dir>: unpacks UE3 (Infinity Blade 1) Coalesced into .ini text files.
# Format: int32 file count; per file: FString path, int32 sections; per section: FString name, int32 keys;
# per key: FString key, FString value. FString = int32 length (incl. NUL; negative = UTF-16) + chars.
import struct,sys,os
d=open(sys.argv[1],'rb').read(); out=sys.argv[2]; p=0
def i32():
    global p; v=struct.unpack_from('<i',d,p)[0]; p+=4; return v
def fstr():
    global p; n=i32()
    if n==0: return ''
    if n>0: s=d[p:p+n-1].decode('latin-1'); p+=n
    else: n=-n; s=d[p:p+2*n-2].decode('utf-16le'); p+=2*n
    return s
nf=i32()
for _ in range(nf):
    path=fstr().replace('..\\..\\','').replace('\\','/'); ns=i32(); lines=[]
    for _ in range(ns):
        lines.append('[%s]'%fstr()); nk=i32()
        for _ in range(nk):
            k=fstr(); v=fstr(); lines.append('%s=%s'%(k,v))
        lines.append('')
    fp=os.path.join(out,path); os.makedirs(os.path.dirname(fp),exist_ok=True)
    open(fp,'w').write('\n'.join(lines))
print(nf,'files, ended at',p,'of',len(d))
