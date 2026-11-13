# insert_dylib.py <thin arm64 macho in> <out> <dylib path as the app will see it>
# Appends an LC_LOAD_DYLIB command into the header padding. An existing LC_CODE_SIGNATURE command is left as it is,
# now stale; the build's codesign -f replaces the signature afterwards.
import struct,sys
src,dst,path=sys.argv[1],sys.argv[2],sys.argv[3].encode()
d=bytearray(open(src,'rb').read())
magic,cpu,sub,ft,ncmds,sizeofcmds,flags,res=struct.unpack_from('<IiiIIIII',d,0)
assert magic==0xfeedfacf, 'need a thin 64-bit Mach-O'
name=path+b'\0'; cs=(24+len(name)+7)//8*8
lc=struct.pack('<IIIIII',0xC,cs,24,2,0x10000,0x10000)+name; lc+=b'\0'*(cs-len(lc))
end=32+sizeofcmds
assert path not in d[32:end], 'already inserted'
assert all(b==0 for b in d[end:end+cs]), 'no free header space'
d[end:end+cs]=lc
struct.pack_into('<II',d,16,ncmds+1,sizeofcmds+cs)
open(dst,'wb').write(d); print('inserted',path.decode(),'(',cs,'bytes )')
