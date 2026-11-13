# set_sdk.py <thin arm64 macho> <sdk like 14.0>: rewrites the SDK field of the binary's minimum-OS command, LC_VERSION_MIN_IPHONEOS
# or LC_BUILD_VERSION (iOS gives full native screen size only to apps "built with" iOS 11 SDK or later).
# Stops with an error when the binary has neither, rather than leaving it unchanged without a word.
import struct,sys
p,ver=sys.argv[1],sys.argv[2]
maj,mi=(int(x) for x in ver.split('.'))
new=(maj<<16)|(mi<<8)
d=bytearray(open(p,'rb').read())
assert struct.unpack_from('<I',d,0)[0]==0xfeedfacf, 'need a thin 64-bit Mach-O'
ncmds=struct.unpack_from('<I',d,16)[0]; off=32; done=0
for i in range(ncmds):
    cmd,cs=struct.unpack_from('<II',d,off)
    if cmd==0x25:                                  # LC_VERSION_MIN_IPHONEOS: cmd, cmdsize, version, sdk
        v,s=struct.unpack_from('<II',d,off+8)
        struct.pack_into('<I',d,off+12,new); done+=1
        print('min OS %d.%d, sdk %d.%d -> %s'%(v>>16,(v>>8)&255,s>>16,(s>>8)&255,ver))
    elif cmd==0x32:                                # LC_BUILD_VERSION: cmd, cmdsize, platform, minos, sdk, ntools
        v,s=struct.unpack_from('<II',d,off+12)
        struct.pack_into('<I',d,off+16,new); done+=1
        print('min OS %d.%d, sdk %d.%d -> %s'%(v>>16,(v>>8)&255,s>>16,(s>>8)&255,ver))
    off+=cs
if not done: sys.exit('set_sdk: no LC_VERSION_MIN_IPHONEOS or LC_BUILD_VERSION in '+p)
open(p,'wb').write(d)
