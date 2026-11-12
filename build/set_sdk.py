# set_sdk.py <thin arm64 macho> <sdk like 14.0>: rewrites the SDK field of LC_VERSION_MIN_IPHONEOS
# (iOS gives full native screen size only to apps "built with" iOS 11 SDK or later).
import struct,sys
p,ver=sys.argv[1],sys.argv[2]
maj,mi=(int(x) for x in ver.split('.'))
d=bytearray(open(p,'rb').read())
ncmds=struct.unpack_from('<I',d,16)[0]; off=32
for i in range(ncmds):
    cmd,cs=struct.unpack_from('<II',d,off)
    if cmd==0x25:
        v,s=struct.unpack_from('<II',d,off+8)
        struct.pack_into('<I',d,off+12,(maj<<16)|(mi<<8))
        print('min OS %d.%d, sdk %d.%d -> %s'%(v>>16,(v>>8)&255,s>>16,(s>>8)&255,ver))
    off+=cs
open(p,'wb').write(d)
