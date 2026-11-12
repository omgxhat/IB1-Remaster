// game.m: the fixes that change how the game behaves. Every build has them; the parts only test builds have are inside
// #ifdef IBFIX_SNAPS, IBFIX_TEST_TOOLS, IBFIX_BLOOD or IBFIX_BLOODCAP (IBFIX_FILMTIMING: a diagnosis, set by hand).
// Each fix is a numbered section, "// ---- <number>. <what it does> (FIXES.md <entry>) ----": grep -n '^// ---- '
// lists them. FIXES.md holds each fix's full story (the cause, how it was found, how to check it); PLAYBOOK.md maps them.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreHaptics/CoreHaptics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <string.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/sysctl.h>
#define CLS(o) (*(void **)((uint8_t *)(o) + 0x50))   // an object's class (UObject::Class)


#include "ibfix.h"

// ---- 1. "Other audio" means another app --------------------------------------------------
// The start-up film asks whether other audio is playing, to decide if the player has their own music on; today's
// iOS counts the game's own film, so its music stayed off. Answer "no" while that film can be playing (FIXES.md 2).

static CFAbsoluteTime gLaunchTime;

static OSStatus my_AudioSessionGetProperty(AudioSessionPropertyID p, UInt32 *size, void *data) {
    if (p == kAudioSessionProperty_OtherAudioIsPlaying && size && *size >= sizeof(UInt32) && data) {
        // iOS counts the game's own start-up film as other audio, so while the film can be playing (the first 20 s, or
        // while the game's MoviePlayer exists) the game isn't given iOS's answer. The player's own music counts too: the
        // game's first question (~50 ms after loading, before its film exists) gets iOS's honest answer, which is kept
        // for the rest of the film's window (FIXES.md 73).
        id del = [UIApplication sharedApplication].delegate;
        SEL ms = NSSelectorFromString(@"MoviePlayer");
        BOOL filmExists = [del respondsToSelector:ms] && ((id (*)(id, SEL))objc_msgSend)(del, ms) != nil;
        BOOL film = (CFAbsoluteTimeGetCurrent() - gLaunchTime < 20) || filmExists;
        UInt32 real = 0; UInt32 sz = sizeof real;
        AudioSessionGetProperty(p, &sz, &real);
        static int musicAtLaunch = -1;                                  // the player's own music, before the film
        if (musicAtLaunch < 0 && !filmExists) musicAtLaunch = real ? 1 : 0;
        UInt32 other = film ? (musicAtLaunch > 0 ? 1 : 0) : ([AVAudioSession sharedInstance].secondaryAudioShouldBeSilencedHint ? 1 : 0);
        *(UInt32 *)data = other; *size = sizeof(UInt32);
        LOG(@"other audio playing? iOS says %u, film %d, the player's music at launch %d -> game told %u", (unsigned)real, film, musicAtLaunch, (unsigned)other);
        return noErr;
    }
    return AudioSessionGetProperty(p, size, data);
}

INTERPOSE(game_interposers) = {
    { (const void *)my_AudioSessionGetProperty, (const void *)AudioSessionGetProperty },
};

// ---- 2. Subtitle scale --------------------------------------------------------------------
// GetSubtitleRegion takes any screen over 640 px tall for an iPad (scale 1.1): on an iPhone the scale becomes
// 1.4 * height / 640, the iPhone 4's proportion (FIXES.md 7).

#define IB1_NATIVE_SUBSCALE_ENTRY 0x100bea3b0ULL   // {name*, func*, adj} entry: func pointer slot
#define IB1_VTABLE_SETSUBSCALE    0x350            // virtual SetSubtitleFontScale(float)
static const char *kSubScaleName = "USwordGameViewportClientexecSetSubtitleFontScale";

typedef void (*NativeFn)(void *self, void *stack, void *result);
static NativeFn gOrigSubScale;
static volatile float gViewportHeight;   // render height in pixels, refreshed on the main thread
static volatile int gRegionPx[4];     // the HUD region on the screen, in pixels: x, y, width, height (4e)
static volatile float gSafeSideFrac;    // larger side safe-area inset as a fraction of the screen width (main thread)
static BOOL gIsIPad;                    // 3g: an iPad (its model code, read at start)
static volatile float gViewportAspect;  // the game's view, width / height (main thread)
static BOOL gIPadFill;                  // 3g: the iPad fills its screen (HUD region and 3D view), as chosen (FIXES.md 77)

static void my_execSetSubtitleFontScale(void *self, void *stack, void *result) {
    // Peek at the argument before it is consumed: FFrame.Code (+0x28) points at the expression;
    // a float constant is token 0x1E followed by the value.
    const uint8_t *code = *(const uint8_t **)((uint8_t *)stack + 0x28);
    float requested = -1; if (code && code[0] == 0x1E) memcpy(&requested, code + 1, 4);
    gOrigSubScale(self, stack, result);
    float h = gViewportHeight;
    // iPads too (FIXES.md 77): the same proportion of the screen's height as on the iPhone.
    BOOL pad = gIsIPad && requested > 1.05f && requested < 1.15f && h > 640;
    if ((pad || (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone && requested > 1.05f && requested < 1.15f && h > 640))) {
        float scale = 1.4f * h / 640.0f;
        void (**vt)(void *, float) = *(void (***)(void *, float))self;
        vt[IB1_VTABLE_SETSUBSCALE / sizeof(void *)](self, scale);
        static float logged; if (logged != scale) { logged = scale; LOG(@"subtitles: game asked %.2f (iPad size), set %.2f for %.0f px%@", requested, scale, h, pad ? @" (iPad: the iPhone's proportion)" : @""); }
    }
}

static void hookSubtitleScale(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **entry = (void **)(IB1_NATIVE_SUBSCALE_ENTRY + slide);
    const char *name = (const char *)entry[-1];
    if (!name || strcmp(name, kSubScaleName) != 0) { LOG(@"subtitles fix OFF: native table not where expected"); return; }
    gOrigSubScale = (NativeFn)entry[0];
    entry[0] = (void *)my_execSetSubtitleFontScale;
    LOG(@"subtitles fix ON");
}

// ---- 3. HUD region -----------------------------------------------------------------------
// AdjustHUDRenderSize gives any screen it doesn't know a 3:2 band, taller than a wide iPhone: the HUD region and
// touch zones are set to the screen's safe width instead, never narrower than 16:9 (FIXES.md 4).

#define IB1_NATIVE_ZONES_ENTRY 0x100be5970ULL   // func pointer slot; name pointer just before it
static const char *kZonesName = "UMobilePlayerInputexecConditionalUpdateInputZones";
// UE3 FFrame (64-bit): Node +0x18, Object +0x20, Code +0x28, Locals +0x30, PreviousFrame +0x38,
// OutParms +0x40. FOutParmRec: Property +0, PropAddr +8, Next +16. EX_LocalOutVariable = 0x48.
#define FFRAME_CODE     0x28
#define FFRAME_OUTPARMS 0x40
#define EX_LocalOutVariable 0x48

static NativeFn gOrigZones;

static int *outParmAddr(void *stack, const uint8_t *code) {
    if (code[0] != EX_LocalOutVariable) return NULL;
    void *prop; memcpy(&prop, code + 1, sizeof prop);
    for (uint8_t *rec = *(uint8_t **)((uint8_t *)stack + FFRAME_OUTPARMS); rec; rec = *(uint8_t **)(rec + 16))
        if (*(void **)rec == prop) return *(int **)(rec + 8);
    return NULL;
}

static void my_execConditionalUpdateInputZones(void *self, void *stack, void *result) {
    // The four arguments are the caller's out-variables X, Y, SizeX, SizeY, each encoded as
    // EX_LocalOutVariable + an 8-byte property pointer.
    const uint8_t *code = *(const uint8_t **)((uint8_t *)stack + FFRAME_CODE);
    int *v[4] = {0};
    for (int i = 0; i < 4 && code; i++, code += 9) v[i] = outParmAddr(stack, code);
    if (v[0] && v[1] && v[2] && v[3]) {
        int x = *v[0], y = *v[1], w0 = *v[2], h0 = *v[3];
        int W = 2 * x + w0, H = 2 * y + h0;          // full screen size, whichever branch ran
        if (H > 0 && (float)W / H > 1.8f) {
            // The safe width: full width minus iOS's side insets (Dynamic Island, rounded corners). Before the inset is
            // read (the region is set ~0.45 s after launch), the iPhone 17's 62 pt of 874 pt, scaled to this width.
            int inset = (int)lrintf(W * (gSafeSideFrac > 0 ? gSafeSideFrac : 62.0f / 874.0f));
            int sx = W - 2 * inset;
            if (sx < (int)lrintf(H * 16.0f / 9.0f)) { sx = (int)lrintf(H * 16.0f / 9.0f); inset = (W - sx) / 2; }
            *v[0] = inset; *v[1] = 0; *v[2] = sx; *v[3] = H;
            gRegionPx[0] = inset; gRegionPx[1] = 0; gRegionPx[2] = sx; gRegionPx[3] = H;
            static int lastW, lastH;
            if (W != lastW || H != lastH) { lastW = W; lastH = H;
                LOG(@"HUD region: game chose %d,%d %dx%d for %dx%d screen -> safe-width region %d,0 %dx%d (%.3f:1)", x, y, w0, h0, W, H, inset, sx, H, (float)sx / H); }
        } else if (gIPadFill && H > 0 && (float)W / H > 1.3f && (float)W / H < 1.49f) {
            // The iPad, filling the screen (3g): the whole screen is the HUD region. Its height is the screen's own
            // (2 x Y + SizeY is a pixel short when the margin is odd: 1639 of 1640).
            int Hs = gViewportAspect > 1 ? (int)lrintf(W / gViewportAspect) : (int)lrintf(gViewportHeight);   // the screen's shape
            if (abs(Hs - H) > 2) Hs = H;
            *v[0] = 0; *v[1] = 0; *v[2] = W; *v[3] = Hs;
            gRegionPx[0] = 0; gRegionPx[1] = 0; gRegionPx[2] = W; gRegionPx[3] = Hs;
            static int lastW, lastH;
            if (W != lastW || Hs != lastH) { lastW = W; lastH = Hs;
                LOG(@"HUD region: game chose %d,%d %dx%d for %dx%d screen -> the iPad's whole screen 0,0 %dx%d", x, y, w0, h0, W, Hs, W, Hs); }
        } else {
            // Any other screen keeps the game's own region (the iPad: the devs' 3:2 band); recorded for the circles and the
            // bottom-edge gate, which need its offsets.
            gRegionPx[0] = x; gRegionPx[1] = y; gRegionPx[2] = w0; gRegionPx[3] = h0;
            static int lastX = -1, lastY = -1, lastW0, lastH0;
            if (x != lastX || y != lastY || w0 != lastW0 || h0 != lastH0) { lastX = x; lastY = y; lastW0 = w0; lastH0 = h0;
                LOG(@"HUD region: the game's own %d,%d %dx%d for a %dx%d screen (kept)", x, y, w0, h0, W, H); }
        }
    } else {
        static BOOL warned; if (!warned) { warned = YES; LOG(@"HUD region fix: arguments not as expected, left alone"); }
    }
    gOrigZones(self, stack, result);
}

static void hookHUDRegion(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **entry = (void **)(IB1_NATIVE_ZONES_ENTRY + slide);
    const char *name = (const char *)entry[-1];
    if (!name || strcmp(name, kZonesName) != 0) { LOG(@"HUD region fix OFF: native table not where expected"); return; }
    gOrigZones = (NativeFn)entry[0];
    entry[0] = (void *)my_execConditionalUpdateInputZones;
    LOG(@"HUD region fix ON");
}

// ---- 3b. Full-width backgrounds ------------------------------------------------------------
// The HUD region stops at the safe-area edges, so region-wide tiles (cutscene bars, flashes) left bright strips at the
// sides: all are widened except the band behind the health bars (FIXES.md 5). (The tutorial pop-ups draw with
// DrawRotatedTile instead: widened further down, FIXES.md 11.) execDrawTile's first three
// arguments (texture, width, height) are evaluated with the engine's own interpreter and the code pointer rewound; a tile
// spanning the region is drawn inside a transform stretching the region to the full screen width.
// UCanvas: OrgX +0x68, OrgY +0x6c, ClipX +0x70, ClipY +0x74, CurX +0x78, CurY +0x7c, FCanvas* +0x98.

#define IB1_NATIVE_DRAWTILE_ENTRY 0x100bcd590ULL
#define IB1_NATIVE_POPXFORM_ENTRY 0x100bcd458ULL
#define IB1_GNATIVES              0x100c092c8ULL
#define IB1_FCANVAS_PUSHRELATIVE  0x10065c1b8ULL
static const char *kDrawTileName = "UCanvasexecDrawTile";
static const char *kPopXformName = "UCanvasexecPopTransform";

typedef struct { void *fn; intptr_t adj; } MemberFn;
static MemberFn *gNatives;
static NativeFn gOrigDrawTile, gPopTransform;
static void (*gPushRelative)(void *fcanvas, const float *matrix);
#define POP_XFORM(canvas) do { uint8_t dummy[2] = {0}, frame[0x48] = {0}; *(uint8_t **)(frame + FFRAME_CODE) = dummy; gPopTransform(canvas, frame, NULL); } while (0)   // PopTransform only steps past one byte
static volatile float gViewportWidth;

// Evaluate one script expression at Stack.Code into result (as the engine does for arguments).
static void stepExpr(void *stack, void *result) {
    uint8_t **code = (uint8_t **)((uint8_t *)stack + FFRAME_CODE);
    uint8_t tok = *(*code)++;
    void *obj = *(void **)((uint8_t *)stack + 0x20);
    MemberFn e = gNatives[tok];
    void *thisp = (uint8_t *)obj + (e.adj >> 1);
    void *fn = e.fn;
    if (e.adj & 1) fn = *(void **)(*(uint8_t **)thisp + (intptr_t)e.fn);
    ((NativeFn)fn)(thisp, stack, result);
}

// Options and Character Slots (SwordOptionBaseScene; also the ContentPack info pages) switch the 3D world off and frame
// themselves with B_UI.B_Options pieces: a 75-unit column at each side (texture area 867,2 and 948,2, 75x640), a top, a
// bottom and a fill. The columns are decorated, so rather than stretch them a plain strip of each column's grid is tiled
// out to the screen edge, lined up with its grid and covering its outer outline (by choice, FIXES.md 15).
// Drawn with the engine's low-level tile routine, which execDrawTile itself calls: FCanvas, X, Y, Z, SizeX, SizeY, U, V,
// SizeU, SizeV (normalised), colour, texture resource (UTexture +0x100), blend (default 2).
#define IB1_LOWDRAWTILE 0x10065ce30ULL
static const uint8_t kLowDrawTilePrologue[8] = {0xef,0x3b,0xb6,0x6d, 0xed,0x33,0x01,0x6d};
typedef void (*LowDrawTileFn)(void *fcanvas, float x, float y, float z, float sx, float sy, float u, float v,
                              float su, float sv, const float *color, void *texture, int blend);
static void extendFrameColumn(void *canvas, void *tex, float curX, float curY, float xl, float yl,
                              float u, float v, float ul, float vl, const float *color, float margin) {
    static void *optionsTex; static LowDrawTileFn lowDraw; static BOOL checked;
    if (!checked) {
        checked = YES;
        void *fn = (void *)(IB1_LOWDRAWTILE + _dyld_get_image_vmaddr_slide(0));
        if (memcmp(fn, kLowDrawTilePrologue, 8) == 0) lowDraw = (LowDrawTileFn)fn; else LOG(@"frame edges OFF: tile routine not as expected");
    }
    if (!lowDraw || !tex || ul <= 0 || vl <= 0) return;
    float clipX = *(float *)((uint8_t *)canvas + 0x70);
    if (xl > clipX * 0.12f) return;                                   // a side column, not a panel
    BOOL left = fabsf(curX) <= 2, right = fabsf(curX + xl - clipX) <= 2;
    if (!left && !right) return;
    if (!optionsTex) { if (![ibfix_objname(tex) isEqualToString:@"B_Options"]) return; optionsTex = tex; }
    if (tex != optionsTex) return;
    void **vt = *(void ***)tex;                                       // UTexture GetSurfaceWidth/Height (vtable +0x260/+0x268)
    float texW = ((float (*)(void *))vt[0x260 / 8])(tex), texH = ((float (*)(void *))vt[0x268 / 8])(tex);
    void *resource = *(void **)((uint8_t *)tex + 0x100);
    void *fcanvas = *(void **)((uint8_t *)canvas + 0x98);
    if (texW <= 0 || texH <= 0 || !resource || !fcanvas) return;
    // The grid repeats every 12 texels. Each side tiles a plain strip of its own column (left 870-882, the right's
    // mirror 1008-1020) on the column's grid, from one period inside to cover its outline (texels 867-869, 1020-1022).
    const float sliceUL = 12, sliceU = left ? 870 : 1008;
    float scale = xl / ul, sw = sliceUL * scale, z = *(float *)((uint8_t *)canvas + 0x80);
    float anchor = curX + (sliceU - u) * scale;                       // where the strip sits in the column itself
    if (left)  for (float x = anchor - sw; x + sw > -margin - 1; x -= sw)
        lowDraw(fcanvas, x, curY, z, sw, yl, sliceU / texW, v / texH, sliceUL / texW, vl / texH, color, resource, 2);
    else       for (float x = anchor + sw; x < clipX + margin + 1; x += sw)
        lowDraw(fcanvas, x, curY, z, sw, yl, sliceU / texW, v / texH, sliceUL / texW, vl / texH, color, resource, 2);
    static int logged; if (logged < 2) { logged++; LOG(@"frame edges: grid carried to the %s screen edge (%.0f px)", left ? "left" : "right", margin); }
}

// ---- 3d. Dodge buttons ----------------------------------------------------------------------
// The two dodge buttons were a chevron on a dark square panel: four pictures in the HUD sheet B_UI.B_SwordHUD (left
// 229,218 and lit 835,727; right 851,201 and lit 834,875; 172 or 188 x 146 texels). The chosen design (FIXES.md 29): no
// panel, deep black arrows with a dim white glow, lit in the game's blue when pressed. They are drawn into a copy of the
// whole sheet at twice the size (tools/dodge/make-dodge-tex.py; assets/ibfix-B_SwordHUD.rgba, 2048 x 2048 RGBA, mapped
// from the app), uploaded in place of the game's (1024 x 1024 PVRTC 4-bit, one level, recognised by its first 32 bytes
// as stored in SwordGame.xxx). The game's UVs are fractions, so everything still lines up; if anything differs, the
// devs' sheet goes up. The wide HUD region drew the buttons a quarter too wide, so they are drawn with square texels,
// each anchored at its outer edge where the devs placed them. The touch zones are the devs' own.
static const uint8_t kHudSheetHead[32] = { 0xff,0xff,0x3f,0xcf,0xe8,0x90,0xe9,0x94,0xcf,0x8b,0x8b,0xff,0x44,0x73,0x00,0x80,
                                           0xff,0xff,0x00,0xef,0xea,0x94,0x63,0x88,0x2f,0xb2,0xb1,0x0f,0x00,0x80,0x43,0x84 };
static volatile BOOL gDodgeArt;                               // the new sheet is on the graphics chip
// gltrace.m (test tools) notes every texture upload; it defines this for real when it's built in.
__attribute__((weak)) void ibfix_gl_note_compressed(GLint level, GLsizei w, GLsizei h, GLenum fmt) {}
#ifdef IBFIX_SNAPS
// Diagnostic (study/hd-texture-pack.md): which compressed formats the game's GL context accepts. Run once, at the first
// upload (the context is current then): each format gets a tiny texture, and the GL error says whether it was taken.
static void probeTextureFormats(void) {
    static BOOL done; if (done) return; done = YES;
    GLint bound = 0, maxSize = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound); glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxSize);
    LOG(@"GL: %s | %s | max texture %d", (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_RENDERER), maxSize);
    LOG(@"GL extensions: %s", (const char *)glGetString(GL_EXTENSIONS));
    struct { const char *name; GLenum fmt; int bw, bh, bytes; } f[] = {
        { "ASTC 4x4", 0x93B0, 4, 4, 16 }, { "ASTC 6x6", 0x93B4, 6, 6, 16 }, { "ASTC 8x8", 0x93B7, 8, 8, 16 },
        { "ETC2 RGB", 0x9274, 4, 4, 8 },  { "ETC2 RGBA", 0x9278, 4, 4, 16 }, { "BC1 (DXT1)", 0x83F1, 4, 4, 8 },
        { "BC3 (DXT5)", 0x83F3, 4, 4, 16 }, { "PVRTC 4-bit", GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG, 8, 8, 32 } };
    uint8_t zeros[64] = {0};
    while (glGetError() != GL_NO_ERROR) {}
    NSMutableString *res = [NSMutableString string];
    for (size_t i = 0; i < sizeof f / sizeof f[0]; i++) {
        GLuint t = 0; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t);
        glCompressedTexImage2D(GL_TEXTURE_2D, 0, f[i].fmt, f[i].bw, f[i].bh, 0, f[i].bytes, zeros);
        GLenum e = glGetError();
        [res appendFormat:@"%s %@; ", f[i].name, e == GL_NO_ERROR ? @"yes" : [NSString stringWithFormat:@"no (0x%x)", e]];
        glDeleteTextures(1, &t);
    }
    glBindTexture(GL_TEXTURE_2D, (GLuint)bound);
    LOG(@"GL compressed formats: %@", res);
}
#endif
// ---- 3e. HD textures ----------------------------------------------------------------------
// HD textures (FIXES.md 52; study/hd-texture-pack.md): ibfix-hd.pak (tools/hdpack/makepak.py) holds each as a full ASTC
// mip chain, found by the SHA-256 (first 8 bytes) of the PVRTC data the game uploads for one of its first three mips.
// When the game uploads level 0 of a texture the file has, the HD chain goes up instead and the game's smaller levels
// are skipped; UVs are fractions, so it lines up. Render thread. The knight's texture, built while the game runs: hdKnight.
typedef struct { uint64_t hash; uint32_t entry, level, gw, gh; } HDKey;
typedef struct { uint32_t fmt, w, h, mips; uint64_t off, size; } HDEntry;
typedef struct { uint64_t hash; uint32_t entry, piece; } HDPieceKey;
static NSData *gHDFile; static const HDKey *gHDKeys; static const HDEntry *gHDEntries; static uint32_t gHDNKeys, gHDNEntries;
static const HDPieceKey *gHDPieces; static uint32_t gHDNPieces;
static int gHDHits, gHDMisses;
static void hdOpen(void) {
    static BOOL tried; if (tried) return; tried = YES;
#ifdef IBFIX_SNAPS
    // A look test without the HD textures (FIXES.md 58): Documents/ibfix-look-nohd-once leaves them out for one launch
    // (the file is removed as it's read). The first test's lasting switch file is removed if it's still there.
    NSString *docs = DOCUMENTS;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm removeItemAtPath:[docs stringByAppendingPathComponent:@"ibfix-look-nohd"] error:nil]) LOG(@"HD textures: the look test's switch file removed");
    if ([fm removeItemAtPath:[docs stringByAppendingPathComponent:@"ibfix-look-nohd-once"] error:nil]) {
        LOG(@"HD textures OFF for this launch only, for a look test (Documents/ibfix-look-nohd-once)"); return;
    }
#endif
    NSString *path = [[NSBundle mainBundle] pathForResource:@"ibfix-hd" ofType:@"pak"];
    NSData *d = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:NULL] : nil;
    const uint32_t *h = d.length >= 32 ? d.bytes : NULL;    // version 1: no knight pieces
    uint32_t head = h && h[1] == 2 ? 32 : 16, pieces = h && h[1] == 2 ? h[4] : 0;
    if (!h || memcmp(h, "IBHD", 4) || (h[1] != 1 && h[1] != 2) || head + 24ull * h[3] + 32ull * h[2] + 16ull * pieces > d.length) {
        if (d) LOG(@"HD textures OFF: ibfix-hd.pak not as expected"); return;
    }
    gHDFile = d; gHDNEntries = h[2]; gHDNKeys = h[3]; gHDNPieces = pieces;
    gHDKeys = (const HDKey *)((const uint8_t *)d.bytes + head); gHDEntries = (const HDEntry *)(gHDKeys + gHDNKeys);
    gHDPieces = (const HDPieceKey *)(gHDEntries + gHDNEntries);
    LOG(@"HD textures: %u in ibfix-hd.pak (%.0f MB), %u knight piece keys", gHDNEntries, d.length / 1e6, gHDNPieces);
}
static uint64_t hdKey(const void *data, size_t size) {   // SHA-256, first 8 bytes (tools/hdpack/makepak.py)
    uint8_t dig[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data, (CC_LONG)size, dig);
    uint64_t k; memcpy(&k, dig, 8); return k;
}
#ifdef IBFIX_SNAPS
// Test builds: every picture the game uploads with no HD is logged once (with its key), so tools/hdpack/hdaudit.py
// can name each one and prove which HD textures really went up (FIXES.md 54). Render thread.
static BOOL hdFirstSight(uint64_t key) {
    enum { kSeenMax = 8192 }; static uint64_t seen[kSeenMax]; static int n;
    if (!key) return NO;
    for (uint32_t probe = 0, i = (uint32_t)(key % kSeenMax); probe < kSeenMax; probe++, i = (i + 1) % kSeenMax) {
        if (seen[i] == key) return NO;
        if (!seen[i]) { if (n >= kSeenMax * 3 / 4) return NO; seen[i] = key; n++; return YES; }
    }
    return NO;
}
#endif
static const HDEntry *hdFind(const void *data, GLsizei size, uint64_t *key) {
    if (!gHDNKeys || !data || size <= 0) return NULL;
    uint64_t want = hdKey(data, (size_t)size); *key = want;
    uint32_t lo = 0, hi = gHDNKeys;
    while (lo < hi) { uint32_t mid = (lo + hi) / 2; if (gHDKeys[mid].hash < want) lo = mid + 1; else hi = mid; }
    if (lo < gHDNKeys && gHDKeys[lo].hash == want && gHDKeys[lo].entry < gHDNEntries) return &gHDEntries[gHDKeys[lo].entry];
    return NULL;
}
// GL names of textures whose game mips are skipped (their HD chain is up). A name leaves the set when the game deletes
// the texture (post.m's glDeleteTextures hook calls ibfix_hd_note_deleted), so it never fills over a long session; if it
// did, a game mip would go up over an HD chain of another size and break the texture.
enum { kHDSkipMax = 4096 };
static GLuint gHDSkip[kHDSkipMax];
static BOOL hdSkipping(GLuint t) { for (int i = 0; i < kHDSkipMax; i++) if (gHDSkip[i] == t && t) return YES; return NO; }
static void hdSetSkip(GLuint t, BOOL on) {
    for (int i = 0; i < kHDSkipMax; i++) if (gHDSkip[i] == t) { if (!on) gHDSkip[i] = 0; return; }
    if (on) for (int i = 0; i < kHDSkipMax; i++) if (!gHDSkip[i]) { gHDSkip[i] = t; return; }
    if (on) LOG(@"HD textures: the skip list is full (%d)", kHDSkipMax);
}
void ibfix_hd_note_deleted(GLsizei n, const GLuint *t) { for (GLsizei i = 0; t && i < n; i++) if (t[i]) hdSetSkip(t[i], NO); }
// The knight (FIXES.md 54). The game draws the player with one texture it builds while it runs from the equipped
// items' textures (CustomMeshCreator, a Texture2DComposite; one for colour, one for bump maps): 1024x1024 PVRTC 2-bit,
// made of eight 32 KB pieces, each copied whole from one item's texture (PVRTC keeps blocks in Morton order, so piece k
// is the 512x256 rectangle at x = 512 * (k >> 1 & 1), y = 256 * (k & 1) + 512 * (k >> 2 & 1)). The file's piece keys
// name each piece's item; the HD texture is put together from those items' ASTC 4x4 entries (one size for all, so their
// blocks line up), one mip at a time, each block from the item whose piece holds its top-left corner. YES if it went up.
// A blank piece (few distinct byte values) is alike in many textures (the castle's mostly black lightmaps), so it is no
// evidence: only a texture with all eight pieces known, at least three of them pictures, is the knight.
static BOOL hdPicturePiece(const uint8_t *p, size_t n) {
    uint64_t seen[4] = {0}; int distinct = 0;
    for (size_t i = 0; i < n && distinct < 64; i++)
        if (!(seen[p[i] >> 6] & 1ull << (p[i] & 63))) { seen[p[i] >> 6] |= 1ull << (p[i] & 63); distinct++; }
    return distinct >= 64;
}
static BOOL hdKnight(GLenum target, const uint8_t *data, GLuint bound) {
    enum { kPiece = 32768 };
    const HDEntry *src[8]; int found = 0, noHD = 0, pictures = 0;
    for (int k = 0; k < 8; k++) {
        uint64_t want = hdKey(data + k * kPiece, kPiece);
        uint32_t lo = 0, hi = gHDNPieces;
        while (lo < hi) { uint32_t mid = (lo + hi) / 2; if (gHDPieces[mid].hash < want) lo = mid + 1; else hi = mid; }
        BOOL known = NO; src[k] = NULL;
        for (uint32_t i = lo; i < gHDNPieces && gHDPieces[i].hash == want; i++) {
            if (gHDPieces[i].piece != (uint32_t)k) continue;
            known = YES;
            if (gHDPieces[i].entry < gHDNEntries) { src[k] = &gHDEntries[gHDPieces[i].entry]; break; }
        }
        found += known; noHD += known && !src[k]; pictures += known && hdPicturePiece(data + k * kPiece, kPiece);
    }
    if (!pictures) return NO;                                  // not the knight: an ordinary texture with no HD
    if (found < 8 || noHD || pictures < 3) {
        LOG(@"HD knight: a combined texture with %d of 8 pieces known (%d pictures, %d with no HD); the game's is used", found, pictures, noHD);
#ifdef IBFIX_SNAPS
        static int dumps;                                      // for study: tools/hdpack/hdaudit.py --knight
        if (dumps < 3) {
            NSString *f = [NSString stringWithFormat:@"%@/Documents/ibfix-knight-%d.bin", NSHomeDirectory(), ++dumps];
            [[NSData dataWithBytes:data length:8 * kPiece] writeToFile:f atomically:YES];
        }
#endif
        return NO;
    }
    uint32_t S = src[0]->w, mips = src[0]->mips; GLenum fmt = src[0]->fmt;
    for (int k = 1; k < 8; k++)
        if (src[k]->w != S || src[k]->h != S || src[k]->mips != mips || src[k]->fmt != fmt) {
            LOG(@"HD knight: the pieces' HD textures differ in size or kind; the game's is used"); return NO;
        }
    if (fmt != 0x93B0 || S < 1024) { LOG(@"HD knight: pieces not in ASTC 4x4 (0x%x, %u); the game's is used", fmt, S); return NO; }
    uint32_t bpr0 = (S + 3) / 4; uint8_t *buf = malloc((size_t)bpr0 * bpr0 * 16);
    if (!buf) return NO;
    while (glGetError() != GL_NO_ERROR) {}
    uint64_t at = 0; uint32_t s = S;
    for (uint32_t m = 0; m < mips; m++) {
        uint32_t bpr = (s + 3) / 4; size_t n = (size_t)bpr * bpr * 16;
        for (int k = 0; k < 8; k++) if (at + n > src[k]->size) { free(buf); LOG(@"HD knight: an HD texture is short; the game's is used"); return NO; }
        for (uint32_t by = 0; by < bpr; by++) {
            uint32_t gy = (uint32_t)((((uint64_t)by * 4) << m) * 1024 / S);   // in the game's 1024
            for (uint32_t bx = 0; bx < bpr; bx++) {
                uint32_t gx = (uint32_t)((((uint64_t)bx * 4) << m) * 1024 / S);
                int k = (gx >= 512) << 1 | (gy >> 8 & 1) | (gy >= 512) << 2;
                size_t o = ((size_t)by * bpr + bx) * 16;
                memcpy(buf + o, (const uint8_t *)gHDFile.bytes + src[k]->off + at + o, 16);
            }
        }
        glCompressedTexImage2D(target, (GLint)m, fmt, (GLsizei)s, (GLsizei)s, 0, (GLsizei)n, buf);
        at += n; s = s > 1 ? s / 2 : 1;
    }
    free(buf);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) { LOG(@"HD knight: the %ux%u texture didn't upload (GL error 0x%x); the game's is used", S, S, err); return NO; }
    hdSetSkip(bound, YES);
    ++gHDHits;
    LOG(@"HD knight: %ux%u in place of the game's 1024x1024 (texture %u) from entries %ld %ld %ld %ld %ld %ld %ld %ld", S, S, bound,
        (long)(src[0] - gHDEntries), (long)(src[1] - gHDEntries), (long)(src[2] - gHDEntries), (long)(src[3] - gHDEntries),
        (long)(src[4] - gHDEntries), (long)(src[5] - gHDEntries), (long)(src[6] - gHDEntries), (long)(src[7] - gHDEntries));
    return YES;
}
// YES if this upload was taken care of (the HD chain went up, or it's a game level being skipped).
static BOOL hdUpload(GLenum target, GLint level, GLenum fmt, GLsizei gw, GLsizei gh, GLsizei size, const GLvoid *data) {
    if (target != GL_TEXTURE_2D) return NO;
    BOOL pvrtc = fmt == GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG || fmt == GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG ||
                 fmt == GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG || fmt == GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG;
    hdOpen();
    if (!gHDNEntries || !pvrtc) return NO;
    GLint bound = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
    if (level > 0) return hdSkipping((GLuint)bound);
    hdSetSkip((GLuint)bound, NO);                              // a new picture in this texture name
    uint64_t key = 0;
    const HDEntry *e = hdFind(data, size, &key);
    if (!e) {
        if (gHDNPieces && gw == 1024 && gh == 1024 && size == 1024 * 1024 / 4 &&
            (fmt == GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG || fmt == GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG) &&
            hdKnight(target, data, (GLuint)bound)) return YES;
        gHDMisses++;
#ifdef IBFIX_SNAPS
        if ((gw >= 64 || gh >= 64) && hdFirstSight(key))
            LOG(@"HD textures: none for %dx%d %d-bit (key %016llx)", gw, gh, size * 8 / (gw * gh), key);
#endif
        return NO;
    }
    int bw = e->fmt == 0x93B0 ? 4 : e->fmt == 0x93B2 ? 5 : e->fmt == 0x93B4 ? 6 : 8, bh = bw;
    const uint8_t *p = (const uint8_t *)gHDFile.bytes + e->off, *end = p + e->size;
    while (glGetError() != GL_NO_ERROR) {}
    uint32_t w = e->w, h = e->h;
    for (uint32_t m = 0; m < e->mips; m++) {
        GLsizei n = (GLsizei)(((w + bw - 1) / bw) * ((h + bh - 1) / bh) * 16);
        if (p + n > end) break;
        glCompressedTexImage2D(target, (GLint)m, e->fmt, (GLsizei)w, (GLsizei)h, 0, n, p);
        p += n; w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1;
    }
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) { LOG(@"HD textures: a %ux%u texture didn't upload (GL error 0x%x); the game's is used", e->w, e->h, err); return NO; }
    hdSetSkip((GLuint)bound, YES);
#ifdef IBFIX_SNAPS
    ++gHDHits; LOG(@"HD textures: #%d entry %ld %ux%u in place of the game's %dx%d (texture %d)", gHDHits, (long)(e - gHDEntries), e->w, e->h, gw, gh, bound);
#else
    if (++gHDHits <= 40 || gHDHits % 100 == 0) LOG(@"HD textures: #%d %ux%u in place of the game's %dx%d (texture %d)", gHDHits, e->w, e->h, gw, gh, bound);
#endif
    return YES;
}

__attribute__((weak)) void ibfix_bump_note_upload(GLenum target, const void *data, GLsizei size) {}   // bump.m, when built
__attribute__((weak)) void ibfix_wound_note_upload(GLenum target, const void *data, GLsizei size) {}  // wound.m, when built
static void my_glCompressedTexImage2D(GLenum target, GLint level, GLenum fmt, GLsizei w, GLsizei h, GLint border, GLsizei size, const GLvoid *data) {
#ifdef IBFIX_SNAPS
    probeTextureFormats();
#endif
    ibfix_gl_note_compressed(level, w, h, fmt);
    if (level == 0 && w == 1024 && h == 1024 && size == 1024 * 1024 / 2 && data &&
        (fmt == GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG || fmt == GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG) &&
        memcmp(data, kHudSheetHead, sizeof kHudSheetHead) == 0) {
        static NSData *art; static BOOL tried;                // render thread; the file stays mapped for re-uploads
        if (!tried) {
            tried = YES;
            NSString *path = [[NSBundle mainBundle] pathForResource:@"ibfix-B_SwordHUD" ofType:@"rgba"];
            art = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:NULL] : nil;
            if (art.length != 2048 * 2048 * 4) { LOG(@"dodge buttons OFF: new art missing or the wrong size (%lu bytes)", (unsigned long)art.length); art = nil; }
        }
        if (art) {
            while (glGetError() != GL_NO_ERROR) {}
            glTexImage2D(target, 0, GL_RGBA, 2048, 2048, 0, GL_RGBA, GL_UNSIGNED_BYTE, art.bytes);
            GLenum err = glGetError();
            if (err == GL_NO_ERROR) { gDodgeArt = YES; LOG(@"dodge buttons: new art in (HUD sheet uploaded as 2048 x 2048)"); return; }
            LOG(@"dodge buttons OFF: the new sheet didn't upload (GL error 0x%x); the devs' sheet is used", err);
        }
    }
    if (level == 0) ibfix_bump_note_upload(target, data, size);   // which colour textures have bump maps (bump.m)
    if (level == 0) ibfix_wound_note_upload(target, data, size);  // which is an enemy's skin, for blood mode's cuts (wound.m)
    if (hdUpload(target, level, fmt, w, h, size, data)) return;
    glCompressedTexImage2D(target, level, fmt, w, h, border, size, data);
}
// ---- 3f. Sharp textures at an angle -----------------------------------------------------------
// The game's settings ask for anisotropic filtering (MaxAnisotropy), but its OpenGL ES renderer never sets it, so
// surfaces seen at a slant blurred. Every mipmapped texture gets the chip's full anisotropy, at most 16 (FIXES.md 32).
static float gMaxAniso = -1;
#ifdef IBFIX_SNAPS
// Diagnostic: what the game asks of texture sampling (graphics tests): how often each minification filter and each
// anisotropy level is set, logged with the frame rate (snaps.m calls ibfix_gl_sampling_report every 5 s).
static int gMinFilter[4], gAniso[17];                    // NEAREST/LINEAR_MIPMAP_NEAREST/.._LINEAR/other; 1-16
#endif
static void my_glTexParameteri(GLenum t, GLenum p, GLint v) {
#ifdef IBFIX_SNAPS
    if (p == GL_TEXTURE_MIN_FILTER) gMinFilter[v == GL_LINEAR_MIPMAP_LINEAR ? 2 : v == GL_LINEAR_MIPMAP_NEAREST ? 1 : v == GL_LINEAR ? 0 : 3]++;
    if (p == GL_TEXTURE_MAX_ANISOTROPY_EXT) gAniso[MAX(1, MIN(16, v))]++;
#endif
    glTexParameteri(t, p, v);
    if (p == GL_TEXTURE_MIN_FILTER && (v == GL_LINEAR_MIPMAP_LINEAR || v == GL_LINEAR_MIPMAP_NEAREST || v == GL_NEAREST_MIPMAP_LINEAR || v == GL_NEAREST_MIPMAP_NEAREST)) {
        if (gMaxAniso < 0) { GLfloat m = 0; glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, &m); gMaxAniso = m > 1 ? MIN(m, 16) : 0;
                             LOG(@"angled sharpness: anisotropic filtering %.0fx for every mipmapped texture", gMaxAniso); }
        if (gMaxAniso > 1) glTexParameterf(t, GL_TEXTURE_MAX_ANISOTROPY_EXT, gMaxAniso);
#ifdef IBFIX_SNAPS
        if (gMaxAniso > 1) gAniso[(int)gMaxAniso]++;                 // (our own call isn't seen by the interposer)
#endif
    }
}
// 4ai: the achievement badges' sheet (assets/ibfix-badges.rgba, tools/badges_sheet.py: 2048 x 2048, plain RGBA) goes up in
// place of the empty picture the add-on asked the engine for (Texture2D.Create, 2048 x 2048, 32-bit; badgesMake below):
// the first 2048 x 2048 upload of a first level within 30 s of asking (UpdateResource, which we call, sends it at once), in
// as 32-bit colour whatever form the engine chose; any later fill of that GL texture is ignored. Render thread.
static volatile double gBadgeAskedAt;                           // when the picture was asked for; 0: nothing waiting
static GLuint gBadgeGL;                                         // the GL texture the sheet went into
static volatile int gBadgeUp;                                   // 1 once it has
static void *gLastCanvas, *gAnyTexture;                          // the last DrawTile's canvas; a Texture2D the menus draw (4ai)
#ifdef IBFIX_SNAPS
static void badgeTitleTest(void *canvas, void *tex);           // 4ai
#endif
static const uint8_t *badgeSheet(GLenum fmt) {
    static NSData *rgba; static uint8_t *bgra; static BOOL tried;
    if (!tried) {
        tried = YES;
        NSString *p = [[NSBundle mainBundle] pathForResource:@"ibfix-badges" ofType:@"rgba"];
        rgba = p ? [NSData dataWithContentsOfFile:p options:NSDataReadingMappedAlways error:NULL] : nil;
        if (rgba.length != 2048u * 2048u * 4u) { LOG(@"badges OFF: ibfix-badges.rgba missing or the wrong size (%lu bytes)", (unsigned long)rgba.length); rgba = nil; }
    }
    if (!rgba) return NULL;
    if (fmt == GL_RGBA) return rgba.bytes;
    if (fmt != GL_BGRA_EXT) return NULL;
    if (!bgra) {                                                // the engine's own channel order, once
        size_t n = 2048u * 2048u; const uint8_t *q = rgba.bytes; bgra = malloc(n * 4);
        for (size_t i = 0; i < n; i++) { bgra[4 * i] = q[4 * i + 2]; bgra[4 * i + 1] = q[4 * i + 1]; bgra[4 * i + 2] = q[4 * i]; bgra[4 * i + 3] = q[4 * i + 3]; }
    }
    return bgra;
}
static BOOL badgeUpload(GLenum target, GLint level, GLint ifmt, GLint x, GLint y, GLsizei w, GLsizei h, GLenum fmt, GLenum type, const void *data, BOOL sub) {
#ifdef IBFIX_SNAPS
    // the first minute after asking: every big picture sent to the chip, to see how the engine sends ours
    static int shown;
    double askedLog = gBadgeAskedAt;
    if ((w >= 1024 || h >= 1024) && askedLog && CFAbsoluteTimeGetCurrent() - askedLog < 60 && shown < 20) {
        GLint b = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &b); shown++;
        LOG(@"badges: %s %dx%d level %d at %d,%d, format 0x%x type 0x%x internal 0x%x, data %s, GL texture %d", sub ? "glTexSubImage2D" : "glTexImage2D",
            w, h, level, x, y, fmt, type, ifmt, data ? "given" : "none", b);
    }
#endif
    if (target != GL_TEXTURE_2D) return NO;
    GLint bound = 0;
    if (sub) {                                                  // the engine filling our picture after the sheet went in: ignored
        if (!gBadgeGL || !gBadgeUp) return NO;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
        return (GLuint)bound == gBadgeGL;
    }
    if (level != 0 || w != 2048 || h != 2048) return NO;
    double asked = gBadgeAskedAt; if (!asked || CFAbsoluteTimeGetCurrent() - asked > 30) return NO;
    // (not "only if empty": the engine's new picture holds whatever its memory held, not zeros; the match is the size,
    // the first level and the window after our own request, which our UpdateResource call starts)
    const uint8_t *px = badgeSheet(GL_RGBA);
    if (!px) { gBadgeAskedAt = 0; return NO; }
    // in as full 32-bit colour whatever form the engine chose (it samples it the same way)
    while (glGetError() != GL_NO_ERROR) {}
    glTexImage2D(target, 0, GL_RGBA, 2048, 2048, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) { LOG(@"badges OFF: the sheet didn't upload (GL error 0x%x)", err); gBadgeAskedAt = 0; return NO; }
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound); gBadgeGL = (GLuint)bound; gBadgeAskedAt = 0; gBadgeUp = 1;
    LOG(@"badges: the sheet went up (in place of the engine's %s, format 0x%x type 0x%x; GL texture %u)", data ? "new picture" : "storage", fmt, type, gBadgeGL);
    return YES;
}
// Test builds also log the uncompressed pictures the game uploads (the HD swap only takes PVRTC ones), once each with a key
// (SHA-256 of the data, first 8 bytes), for tools/hdpack/hdaudit.py.
static void my_glTexImage2D(GLenum target, GLint level, GLint ifmt, GLsizei w, GLsizei h, GLint border, GLenum fmt, GLenum type, const GLvoid *data) {
    if (badgeUpload(target, level, ifmt, 0, 0, w, h, fmt, type, data, NO)) return;
#ifdef IBFIX_SNAPS
    if (level == 0 && data && w >= 64 && h >= 64) {
        int bpp = type == GL_UNSIGNED_BYTE ? (fmt == GL_RGBA || fmt == GL_BGRA_EXT ? 4 : fmt == GL_RGB ? 3 : fmt == GL_LUMINANCE_ALPHA ? 2 : 1)
                : (type == GL_UNSIGNED_SHORT_4_4_4_4 || type == GL_UNSIGNED_SHORT_5_5_5_1 || type == GL_UNSIGNED_SHORT_5_6_5) ? 2 : 0;
        uint64_t key = bpp ? hdKey(data, (size_t)w * h * bpp) : 0;
        if (!bpp || hdFirstSight(key))
            LOG(@"HD textures: uncompressed %dx%d (format 0x%x, type 0x%x, key %016llx), not swapped", w, h, fmt, type, key);
    }
#endif
    glTexImage2D(target, level, ifmt, w, h, border, fmt, type, data);
}
static void my_glTexSubImage2D(GLenum target, GLint level, GLint x, GLint y, GLsizei w, GLsizei h, GLenum fmt, GLenum type, const GLvoid *data) {
    if (badgeUpload(target, level, 0, x, y, w, h, fmt, type, data, YES)) return;
    glTexSubImage2D(target, level, x, y, w, h, fmt, type, data);
}
#ifdef IBFIX_SNAPS
static void my_glTexParameterf(GLenum t, GLenum p, GLfloat v) {
    if (p == GL_TEXTURE_MAX_ANISOTROPY_EXT) gAniso[MAX(1, MIN(16, (int)v))]++;
    glTexParameterf(t, p, v);
}
void ibfix_gl_sampling_report(void) {
    NSMutableString *a = [NSMutableString string];
    for (int i = 1; i <= 16; i++) if (gAniso[i]) [a appendFormat:@" %dx:%d", i, gAniso[i]];
    LOG(@"sampling: min filter linear %d, mip nearest %d, mip linear (trilinear) %d, other %d | anisotropy%@",
        gMinFilter[0], gMinFilter[1], gMinFilter[2], gMinFilter[3], a.length ? a : @" never set");
}
#endif
INTERPOSE(kGLInterpose) = {
    { (const void *)my_glCompressedTexImage2D, (const void *)glCompressedTexImage2D },
    { (const void *)my_glTexParameteri, (const void *)glTexParameteri },
    { (const void *)my_glTexImage2D, (const void *)glTexImage2D },          // 4ai (and test builds' log)
    { (const void *)my_glTexSubImage2D, (const void *)glTexSubImage2D },    // 4ai
#ifdef IBFIX_SNAPS
    { (const void *)my_glTexParameterf, (const void *)glTexParameterf },
#endif
};
// One of the four dodge pictures, drawn with square texels from its outer edge. YES if it was drawn.
static BOOL drawDodgeTile(void *canvas, void *stack, void *result, void *tex, float xl, float yl, float u, float v, float ul, float vl, const float *color) {
    BOOL left  = (fabsf(u - 229) < 0.5f && fabsf(v - 218) < 0.5f) || (fabsf(u - 835) < 0.5f && fabsf(v - 727) < 0.5f);
    BOOL right = (fabsf(u - 851) < 0.5f && fabsf(v - 201) < 0.5f) || (fabsf(u - 834) < 0.5f && fabsf(v - 875) < 0.5f);
    if ((!left && !right) || fabsf(vl - 146) > 0.5f || xl <= 0 || yl <= 0 || ul <= 0) return NO;
    static void *hudTex;                                      // the sheet lives in SwordGame.xxx, never unloaded
    if (!hudTex) { if (![ibfix_objname(tex) isEqualToString:@"B_SwordHUD"]) return NO; hudTex = tex; }
    void *fcanvas = *(void **)((uint8_t *)canvas + 0x98);
    float a = yl * ul / vl / xl;                              // the width that makes texels square, as a factor
    if (tex != hudTex || !fcanvas || fabsf(a - 1) < 0.01f) return NO;   // (a 3:2 screen: already square)
    static LowDrawTileFn lowDraw; static BOOL checked;
    if (!checked) {
        checked = YES;
        void *fn = (void *)(IB1_LOWDRAWTILE + _dyld_get_image_vmaddr_slide(0));
        if (memcmp(fn, kLowDrawTilePrologue, 8) == 0) lowDraw = (LowDrawTileFn)fn; else LOG(@"dodge buttons: tile routine not as expected; drawn as before");
    }
    void **vt = *(void ***)tex;                               // UTexture GetSurfaceWidth/Height (vtable +0x260/+0x268)
    float texW = ((float (*)(void *))vt[0x260 / 8])(tex), texH = ((float (*)(void *))vt[0x268 / 8])(tex);
    void *resource = *(void **)((uint8_t *)tex + 0x100);
    if (!lowDraw || texW <= 0 || texH <= 0 || !resource) return NO;
    // The game's own call still runs (so it reads its arguments as usual), squeezed to zero width; then the picture is
    // drawn here half a texel in from every side, or filtering takes in the opaque neighbouring pictures (a dark line).
    float curX = *(float *)((uint8_t *)canvas + 0x78), curY = *(float *)((uint8_t *)canvas + 0x7c), z = *(float *)((uint8_t *)canvas + 0x80);
    float m[16] = { 0,0,0,0,  0,1,0,0,  0,0,1,0,  curX,0,0,1 };
    gPushRelative(fcanvas, m);
    gOrigDrawTile(canvas, stack, result);
    POP_XFORM(canvas);
    float w = xl * a, x = left ? curX : curX + xl - w;        // the outer edge stays put
    lowDraw(fcanvas, x, curY, z, w, yl, (u + 0.5f) / texW, (v + 0.5f) / texH, (ul - 1) / texW, (vl - 1) / texH, color, resource, 2);
    static int logged; if (logged < 2) { logged++; LOG(@"dodge buttons: drawn %.0f px wide instead of %.0f (square texels)", w, xl); }
    return YES;
}

static void installVolumeSliders(void *canvas);
// ---- 2c. The end screen's logo kept in memory (FIXES.md 47) ----
// After the God King (and after Zero), SwordGameWonScene asks for the Infinity Blade logo by name,
// DynamicLoadObject("B_FrontEnd.Materials.T_Title"), but on the iPhone that texture is only stored in Birthright_EstShot,
// the title scene's level, which isn't loaded then: the screen stayed black. The title screen draws the same texture at
// every start, so the first time it comes through here it is put in the engine's root set (ObjectFlags +0x10 |= RF_RootSet
// 0x4000, as UObject::AddToRoot, e.g. 0x1000d20c0) and stays loaded for the session (a 1024x512 picture).
static int nameIndex(const char *want);
static void *gTitleLogo;
static void keepTitleLogo(void *tex) {
    static int nameTitle = -2; static CFAbsoluteTime lastTry;
    if (gTitleLogo || !tex) return;
    if (nameTitle < 0) {                                        // the name exists once the title scene has loaded
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent(); if (t - lastTry < 1) return; lastTry = t;
        nameTitle = nameIndex("T_Title"); if (nameTitle < 0) return;
    }
    const uint8_t *o = tex;
    if (*(const int *)(o + 0x48) != nameTitle || *(const int *)(o + 0x4c) != 0) return;
    const uint8_t *group = *(const uint8_t **)(o + 0x40), *pkg = group ? *(const uint8_t **)(group + 0x40) : NULL;
    if (![ibfix_objname(group) isEqualToString:@"Materials"] || ![ibfix_objname(pkg) isEqualToString:@"B_FrontEnd"] || *(const void **)(pkg + 0x40)) return;
    *(uint64_t *)((uint8_t *)tex + 0x10) |= 0x4000;            // RF_RootSet
    gTitleLogo = tex;
    LOG(@"end screen logo: B_FrontEnd.Materials.T_Title kept in memory for the God King's end screen (flags now %#llx)", *(unsigned long long *)((uint8_t *)tex + 0x10));
}
#ifdef IBFIX_SNAPS
void ibfix_skip_zone_log(NSString *drawn);
void ibfix_snap(NSString *label);
BOOL ibfix_auto_photos(void);   // snaps.m: the pictures test builds take by themselves, only when switched on
#endif
// ---- 3h. The menu screen and menu object being drawn (noted by the script-call hook around RenderScene/RenderObject) ----
// Every Sword menu is laid out in the devs' 960 x 640 units, scaled per axis to the HUD region (the safe width), so on a
// wide screen its pictures come out too wide and whatever sits against the screen's edge stops short of it (FIXES.md 97).
static void *gMenuScene, *gMenuObj;
#ifdef IBFIX_SNAPS
// Test builds: a survey of every picture the menus draw, once per screen, object and picture: its sheet and patch, where
// and how big it is drawn, its drawn shape against the art's own shape, and whether it touches the region's edges.
// Where the picture is drawn (x, y in the region, clipX, clipY its size), its shape against the art's own (r), and which
// of the region's edges it touches (edges), from menuSurvey's own arguments
#define SURVEY_PLACE() uint8_t *c = canvas; \
    float orgX = *(float *)(c + 0x68), orgY = *(float *)(c + 0x6c), clipX = *(float *)(c + 0x70), clipY = *(float *)(c + 0x74); \
    float x = orgX + *(float *)(c + 0x78), y = orgY + *(float *)(c + 0x7c); \
    float r = fabsf(xl / yl) / fabsf(ul / vl); \
    NSMutableString *edges = [NSMutableString string]; \
    if (fabsf(x) <= 2) [edges appendString:@" LEFT"]; \
    if (fabsf(x + xl - clipX) <= 2 || x + xl > clipX + 2) [edges appendString:@" RIGHT"]; \
    if (fabsf(y) <= 2) [edges appendString:@" TOP"]; \
    if (fabsf(y + yl - clipY) <= 2 || y + yl > clipY + 2) [edges appendString:@" BOTTOM"]
static void menuSurvey(void *canvas, void *tex, float xl, float yl, float u, float v, float ul, float vl, const char *how) {
    if (!gMenuScene && tex && ul != 0 && vl != 0 && yl != 0 && xl != 0) {
        // the same, outside the menus: the HUD (fights, the castle view), once per picture and size
        static NSMutableSet *hseen; if (!hseen) hseen = [NSMutableSet set];
        if (hseen.count > 3000) return;
        NSString *key = [NSString stringWithFormat:@"%p|%.0f,%.0f,%.0f,%.0f|%.0fx%.0f", tex, u, v, ul, vl, xl, yl];
        if ([hseen containsObject:key]) return;
        [hseen addObject:key];
        SURVEY_PLACE();
        LOG(@"hud survey: %@ UV %.0f,%.0f %.0fx%.0f | %s at %.0f,%.0f size %.0fx%.0f of %.0fx%.0f | %.3f x the art's shape |%@",
            ibfix_objname(tex), u, v, ul, vl, how, x, y, xl, yl, clipX, clipY, r, edges.length ? edges : @" -");
        return;
    }
    if (!gMenuScene || !tex || ul == 0 || vl == 0 || yl == 0 || xl == 0) return;
    static NSMutableSet *seen; if (!seen) seen = [NSMutableSet set];
    if (seen.count > 4000) return;
    NSString *scene = ibfix_objname(CLS(gMenuScene));
    NSString *obj = gMenuObj ? [NSString stringWithFormat:@"%@ %@", ibfix_objname(CLS(gMenuObj)), ibfix_objname(gMenuObj)] : @"(the screen itself)";
    NSString *key = [NSString stringWithFormat:@"%@|%@|%p|%.0f,%.0f,%.0f,%.0f|%.0fx%.0f", scene, obj, tex, u, v, ul, vl, xl, yl];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    SURVEY_PLACE();
    LOG(@"menu survey: %@ | %@ | %@ UV %.0f,%.0f %.0fx%.0f | %s at %.0f,%.0f size %.0fx%.0f of %.0fx%.0f | %.3f x the art's shape |%@",
        scene, obj, ibfix_objname(tex), u, v, ul, vl, how, x, y, xl, yl, clipX, clipY, r, edges.length ? edges : @" -");
    static BOOL radius;
    if (!radius) { radius = YES; dispatch_async(dispatch_get_main_queue(), ^{
        id cr = nil; @try { cr = [[UIScreen mainScreen] valueForKey:@"_displayCornerRadius"]; } @catch (id e) { cr = nil; }
        LOG(@"menu survey: the screen's corner radius %@ pt (scale %.0f)", cr ?: @"unknown", [UIScreen mainScreen].scale); }); }
}
#endif

// ---- 3i. Menus: pictures at their art's own shape, and out to the screen's edges (5 November 2026; FIXES.md 97) ----
// Every rule is keyed on the picture's own sheet and patch (the survey's list, 3h), drawn while a menu screen draws, and
// only while the region is wider than 3:2 (stretch = (ClipX/960) / (ClipY/640); an iPad's band is 3:2, so nothing changes):
//   TRUE   round and square buttons, icons, the boxes' tick and cross, the x10 arrow, the heart, the potion: drawn
//          1/stretch as wide about their centre (the devs' own shape on the 3:2 screens they drew for); captions untouched
//   ENDS   the long buttons and COMPARE: the same size, their two rounded ends at the art's own shape, the plain middle
//          stretched between them (3 pieces)
//   CORNER the corner button (SwordBackBttn, every screen): at the art's own shape and the devs' size, its right side
//          carried to the screen's right edge with the art's last column, placed so its arrow clears the screen's
//          rounded corner; its touch area reaches the screen's edge (RightLeeway)
//   TAB    the pause tab: its slanted sides keep the band's stretch (they meet the band's notch); only the square icon
//          in its middle goes to its true shape, the plain grid strips beside it taking up the difference (5 pieces)
//   BAND   the pause band: drawn as it is, then its grid continued to both screen edges from an interior period of its
//          own art (12 texels; the first copy covers the thin dark line its last texel leaves), under the buttons; the
//          pause screen's mask (bClipScene) kept but reaching the screen's right edge; the left end drawn after the screen
//   HEX    the Character screen's panel: continued to the left edge from its own hex period (10.78 texels)
//   XPEND  the item screens' XP bar pieces that reach the region's right edge: their last column carried to the screen's
// and FLAT tiles (a patch at most 8 texels wide, or drawn at least 8 times its width: the item screens' list panel and its
// shading) touching the region's left or right edge are stretched out to that screen edge (Infinity Blade 2's FIXES.md 2).
enum { MA_NONE, MA_TRUE, MA_ENDS, MA_CORNER, MA_TAB, MA_BAND, MA_HEX, MA_XPEND, MA_HUDBAND };
static int poff(void *cls, const char *name);
static BOOL isClass(void *o, const char *name);
static int menuSheet(const void *tex) {                       // 1 B_Inventory, 2 B_Options, 3 B_Common, 4 B_SwordHUD, 5 B_Info
    static int ids[6] = { -2, -2, -2, -2, -2, -2 }; static CFAbsoluteTime tried;
    if (ids[1] < 0 || ids[2] < 0 || ids[3] < 0 || ids[4] < 0 || ids[5] < 0) {
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - tried > 1) { tried = t; ids[1] = nameIndex("B_Inventory"); ids[2] = nameIndex("B_Options"); ids[3] = nameIndex("B_Common"); ids[4] = nameIndex("B_SwordHUD"); ids[5] = nameIndex("B_Info"); }
    }
    const uint8_t *o = tex;
    if (*(const int *)(o + 0x4c) != 0) return 0;              // the name's number: these sheets have none
    int id = *(const int *)(o + 0x48);
    for (int k = 1; k <= 5; k++) if (ids[k] >= 0 && id == ids[k]) return k;
    return 0;
}
static int menuArtKind(int sheet, float u, float v, float ul, float vl, float *endT) {   // endT[0], endT[1]: the ends' texels
    int U = (int)lroundf(u), V = (int)lroundf(v), UL = (int)lroundf(ul), VL = (int)lroundf(vl);
    if (sheet == 1) {
        if (U == 911 && V == 803 && UL == 103 && VL == 106) return MA_CORNER;
        if (U == 555 && V == 805 && UL == 141 && VL == 85) { endT[0] = endT[1] = 30; return MA_ENDS; }        // COMPARE
        if ((UL == 75 && VL == 75) || (UL == 134 && VL == 134)) return MA_TRUE;                   // the sheet's round buttons
        if (U == 891 && UL == 118 && VL == 50 && (V == 919 || V == 972)) return MA_TRUE;          // the boxes' cross and tick
        if (U == 795 && V == 728 && UL == 59 && VL == 74) return MA_TRUE;                         // the x10 arrow
        if (U == 677 && V == 587 && UL == 48 && VL == 51) return MA_TRUE;                         // the heart
        if (U == 0 && V == 0 && UL == 519 && VL == 640) return MA_HEX;                            // the Character panel
        if ((V == 3 || V == 164) && VL == 153 && U >= 539 && U + UL == 1023) return MA_XPEND;     // the XP bar, out to its end
    } else if (sheet == 2) {
        if (U == 2 && V == 710 && UL == 299 && VL == 113) { endT[0] = endT[1] = 40; return MA_ENDS; }         // the long blue buttons
        if (V == 453 && VL == 61 && U == 132 && UL == 61) return MA_TRUE;                         // the lists' square buttons
        if (V == 453 && VL == 60 && UL == 60 && (U == 6 || U == 69)) return MA_TRUE;              // the tick boxes
        if (U == 197 && V == 452 && UL == 29 && VL == 63) return MA_TRUE;                         // the sliders' handle
        if (U == 3 && V == 824 && UL == 960 && VL == 197) return MA_BAND;                         // the pause band
    } else if (sheet == 3) {
        if (U == 129 && V == 458 && UL == 130 && VL == 232) return MA_TRUE;                       // the health potion
    } else if (sheet == 4) {
        if (U == 856 && (V == 151 || V == 101) && UL == 134 && VL == 48) return MA_TAB;           // the swords tab (menu, HUD)
        if (U == 615 && V == 808 && UL == 135 && VL == 135) return MA_TRUE;                       // the castle view's "!"
        if (U == 644 && V == 976 && UL == 68 && VL == 42) return MA_TRUE;                         // the skip (fast-forward) arrows
        // (the block shield, 226x149, stays as it was by choice, FIXES.md 97)
        if (U == 88 && V == 596 && UL == 133 && VL == 68) return MA_TRUE;                         // the stunned stars
        if (U == 0 && V == 0 && UL == 960 && VL == 100) return MA_HUDBAND;                        // the fight's health band
    } else if (sheet == 5) {                                                                      // the arena's screens
        if (U == 12 && V == 449 && UL == 219 && VL == 155) { endT[0] = 16; endT[1] = 62; return MA_ENDS; }   // UPGRADE: end, arrowhead
        if (U == 259 && (V == 495 || V == 548) && UL == 43 && VL == 41) return MA_TRUE;           // its arrows
        if (U == 8 && V == 612 && UL == 320 && VL == 54) { endT[0] = endT[1] = 58; return MA_ENDS; }         // the gold banner's slants
        if (U == 18 && V == 249 && UL == 296 && VL == 111) { endT[0] = endT[1] = 40; return MA_ENDS; }       // READY
    }
    return MA_NONE;
}
static LowDrawTileFn menuLowDraw(void) {
    static LowDrawTileFn fn; static BOOL checked;
    if (!checked) {
        checked = YES;
        void *f = (void *)(IB1_LOWDRAWTILE + _dyld_get_image_vmaddr_slide(0));
        if (memcmp(f, kLowDrawTilePrologue, 8) == 0) fn = (LowDrawTileFn)f; else LOG(@"menu shapes OFF: tile routine not as expected");
    }
    return fn;
}
// One piece of a sheet drawn with the engine's low-level tile routine (no clipping to the region): x, y in the canvas's
// own space (origin included), u, v, ul, vl in the sheet's texels
static void menuPiece(void *canvas, void *tex, float x, float y, float w, float h, float u, float v, float ul, float vl, const float *color, int blend) {
    LowDrawTileFn f = menuLowDraw();
    if (!f || !tex || w <= 0 || h <= 0) return;
    void **vt = *(void ***)tex;
    float texW = ((float (*)(void *))vt[0x260 / 8])(tex), texH = ((float (*)(void *))vt[0x268 / 8])(tex);
    void *resource = *(void **)((uint8_t *)tex + 0x100), *fcanvas = *(void **)((uint8_t *)canvas + 0x98);
    if (texW <= 0 || texH <= 0 || !resource || !fcanvas) return;
    f(fcanvas, x, y, *(float *)((uint8_t *)canvas + 0x80), w, h, u / texW, v / texH, ul / texW, vl / texH, color, resource, blend);
}
// The game's own DrawTile, but cut at the screen's right edge instead of the region's: the engine cuts a tile at the
// canvas's ClipX (UCanvas::DrawTile: w = MyClipX - X), so a picture sliding in from the right (the results screen's glow,
// ARENA MODE's panel, the achievement pop-up) was cut by a straight line in the margin. Only while the clip is the
// region's own (not a list's SetClip) and the canvas has no origin; the left needs nothing (the engine doesn't cut there).
// absRight: where the tile ends.
static void origDrawTileScreenClip(void *canvas, void *stack, void *result, float absRight) {
    static int oSizeX = -2; if (oSizeX == -2) oSizeX = poff(CLS(canvas), "SizeX");
    float *pClipX = (float *)((uint8_t *)canvas + 0x70), clipX = *pClipX, orgX = *(float *)((uint8_t *)canvas + 0x68);
    int sizeX = oSizeX > 0 ? *(int *)((uint8_t *)canvas + oSizeX) : 0;
    float W = gViewportWidth;
    BOOL widen = W > clipX + 1 && sizeX > 0 && fabsf(clipX - sizeX) < 1 && fabsf(orgX) < 0.5f && absRight > clipX + 0.5f;
    if (widen) *pClipX = clipX + (W - clipX) / 2;
    gOrigDrawTile(canvas, stack, result);
    if (widen) {
        *pClipX = clipX;
        static int logged; if (logged < 3) { logged++; LOG(@"backgrounds: a tile crossing the region's right edge (to %.0f) cut at the screen's edge instead", absRight); }
    }
}
// The game's own call run under x' = a x + b (it reads its arguments and draws as usual, reshaped)
static float gXformRight;                                       // where the tile being reshaped ends (for its clip)
static void menuDrawXformed(void *canvas, void *stack, void *result, float a, float b) {
    void *fcanvas = *(void **)((uint8_t *)canvas + 0x98);
    float m[16] = { a,0,0,0,  0,1,0,0,  0,0,1,0,  b,0,0,1 };
    gPushRelative(fcanvas, m);
    origDrawTileScreenClip(canvas, stack, result, gXformRight);
    POP_XFORM(canvas);
}
static float gCornerRadiusPx;                                   // the screen's corner radius in render px (0: not known yet)
static void menuCornerRadius(float W) {
    static BOOL asked;
    if (asked) return;
    asked = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        float pt = 0; @try { pt = [[[UIScreen mainScreen] valueForKey:@"_displayCornerRadius"] floatValue]; } @catch (id e) { pt = 0; }
        CGSize s = [UIScreen mainScreen].bounds.size; float wide = MAX(s.width, s.height);
        gCornerRadiusPx = pt > 0 && wide > 0 ? pt * W / wide : 0;
        LOG(@"menu shapes: the screen's corner radius %.0f pt, %.0f px in the picture", pt, gCornerRadiusPx);
    });
}
// The corner button: where its right side goes so that its arrow (art texels: its left side x 80, y 67 to 98; its tip
// 97, 83) sits inside the screen's rounded corner with 14 px (at 2622 px wide) to spare. A circle of the corner radius
// cuts a little more at the diagonal than the screen's own continuous curve, so this errs on the safe side.
static float menuCornerGap(float s, float W) {
    float R = gCornerRadiusPx > 0 ? gCornerRadiusPx : 186 * W / 2622, spare = 14 * W / 2622;
    static const float pts[][2] = { {80, 98}, {80, 67}, {97, 83}, {88, 90}, {88, 75} };
    for (float gap = 0; gap < 600; gap += 1) {
        BOOL ok = YES;
        for (int i = 0; i < 5 && ok; i++) {
            float dx = gap + (103 - pts[i][0]) * s, dy = (106 - pts[i][1]) * s;
            if (dx < R && dy < R && hypotf(R - dx, R - dy) > R - spare) ok = NO;
        }
        if (ok) return gap;
    }
    return 0;
}
// The pause band's left end, drawn just after the pause screen (outside its mask), period by period from the margin's
// edge up to 2 px into the band (covering the thin dark line its first texel leaves; the buttons start 11 px in).
static struct { void *scene, *canvas, *tex; float x, y, xl, yl, u, v, ul, vl, margin, color[4]; } gBandLater;
static void menuBandLeft(void *scene) {
    if (!gBandLater.scene || gBandLater.scene != scene) return;
    float x = gBandLater.x, sx = gBandLater.xl / gBandLater.ul, period = 12 * sx, stop = x + 2;
    for (float px = x + 9 * sx - period; px + period > x - gBandLater.margin - 1; px -= period) {
        float w = fminf(period, stop - px);
        if (w > 0) menuPiece(gBandLater.canvas, gBandLater.tex, px, gBandLater.y, w, gBandLater.yl, gBandLater.u + 9, gBandLater.v, w / sx, gBandLater.vl, gBandLater.color, 2);
    }
    gBandLater.scene = NULL;
}
// Returns YES when it drew (or reshaped) the tile itself.
static BOOL menuShapes(void *canvas, void *stack, void *result, void *tex, float xl, float yl, float u, float v, float ul, float vl,
                       const float *color, int blend) {
    if (!tex || xl == 0 || yl == 0 || ul == 0 || vl == 0) return NO;
    uint8_t *c = canvas;
    float orgX = *(float *)(c + 0x68), orgY = *(float *)(c + 0x6c), clipX = *(float *)(c + 0x70), clipY = *(float *)(c + 0x74);
    float x = orgX + *(float *)(c + 0x78), y = orgY + *(float *)(c + 0x7c);
    float W = gViewportWidth, margin = (W - clipX) / 2;
    if (clipX <= 0 || clipY <= 0 || W <= 0) return NO;
    gXformRight = x + xl;
    float stretch = (clipX / 960) / (clipY / 640);
    if (stretch < 1.05f) return NO;                                                      // a 3:2 band (the iPad): as drawn
    int sheet = menuSheet(tex);
    // Items and rewards (FIXES.md 98): SwordDrawInventoryItem and SwordDrawReward draw an item's or a reward's picture
    // into a box set in 960 x 640 units scaled per axis, so where that box is square in the devs' units (the MASTERED
    // pop-up's item, the rewards screen's prize, the gold bag) the picture comes out too wide: drawn at its art's own
    // shape about the box's centre, like the round buttons. Their glow behind is already at its own shape.
    void *drawer = gMenuScene && stack ? *(void **)((uint8_t *)stack + 0x20) : NULL;   // FFrame Object: who is drawing
    BOOL itemDrawer = drawer && (isClass(drawer, "SwordDrawInventoryItem") || isClass(drawer, "SwordDrawReward"));
    if (itemDrawer && fabsf((fabsf(xl / yl) / fabsf(ul / vl)) / stretch - 1) < 0.03f) {
        float k = 1 / stretch, cx = x + xl / 2;
        menuDrawXformed(canvas, stack, result, k, cx * (1 - k));
        static int logged; if (logged < 6) { logged++; LOG(@"menu shapes: an item picture %@ %.0f,%.0f %.0fx%.0f drawn %.0f px wide instead of %.0f (%@)",
                                                          ibfix_objname(tex), u, v, ul, vl, xl * k, xl, ibfix_objname(CLS(gMenuScene))); }
        return YES;
    }
    // The MASTERED pop-up's glow (B_Common 512,646 358x378, or 0,753 504x271 behind a wide item) has its colour already
    // multiplied by its own see-through layer (made to be added on), but the game blends it as an ordinary see-through
    // picture, multiplying again: a grey ring on the pop-up's white sheet. Drawn here as it was made, in two passes: the
    // screen darkened by the glow's see-through layer (see-through black), then its colour added (additive blend, 3).
    // Only on the Character screen (SwordInventoryScene), whose one item drawer is the pop-up's; the darker results and
    // rewards screens keep the game's own look.
    if (itemDrawer && sheet == 3 && isClass(gMenuScene, "SwordInventoryScene")) {
        int U = (int)lroundf(u), V = (int)lroundf(v), UL = (int)lroundf(ul), VL = (int)lroundf(vl);
        if ((U == 512 && V == 646 && UL == 358 && VL == 378) || (U == 0 && V == 753 && UL == 504 && VL == 271)) {
            float A = color[3];
            const float dark[4] = { 0, 0, 0, A }, add[4] = { color[0] * A, color[1] * A, color[2] * A, 1 };
            menuDrawXformed(canvas, stack, result, 0, x);                                 // the game's call, drawing nothing
            menuPiece(canvas, tex, x, y, xl, yl, u, v, ul, vl, dark, 2);
            menuPiece(canvas, tex, x, y, xl, yl, u, v, ul, vl, add, 3);
            static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the MASTERED pop-up's glow drawn as its picture was made (at %.2f)", A); }
            return YES;
        }
    }
    float endT[2] = { 0, 0 };
    int kind = sheet ? menuArtKind(sheet, u, v, ul, vl, endT) : MA_NONE;
    // outside the menus (the HUD: fights, the castle view), only the HUD sheet's own pictures listed above
    if (!gMenuScene && (sheet != 4 || kind == MA_NONE)) return NO;
    if (gMenuScene && kind == MA_HUDBAND) kind = MA_NONE;      // (a lesson's picture of the band: as it is)
    BOOL leftEdge = fabsf(x) <= 2, rightEdge = fabsf(x + xl - clipX) <= 2;
    if (kind == MA_NONE) {
        // FLAT: a plain colour or shading strip touching the region's side, carried out to the screen's edge
        // (a patch at most 8 texels both ways, or one drawn at least 8 times its width; Infinity Blade 2's FIXES.md 2. Not
        // "8 texels wide" alone: a sliding background's piece (fix 10) is that narrow for a moment at the wrap's seam, and
        // stretched to the edge it smeared, then snapped back)
        BOOL flat = (fabsf(ul) <= 8.5f && fabsf(vl) <= 8.5f) || fabsf(xl) >= 8 * fabsf(ul) * (clipX / 960);
        if (!flat || margin < 1 || (!leftEdge && !rightEdge) || xl >= clipX * 0.97f) return NO;   // (region-wide: 3b's rule)
        // its outermost half texel is half the sheet's neighbour (the engine's filtering at the patch's edge), a paler strip
        // when stretched this far, so that half texel is carried just past the screen's edge (f px)
        float f = 0.6f * (xl + margin) / fabsf(ul), a = (xl + margin + f) / xl, b;
        if (leftEdge) b = x + xl - a * (x + xl);                                     // [x, x+xl] -> [x-margin-f, x+xl]
        else          b = x - a * x;                                                 // [x, x+xl] -> [x, x+xl+margin+f]
        menuDrawXformed(canvas, stack, result, a, b);
        static int logged; if (logged < 4) { logged++; LOG(@"menu shapes: a plain strip at the %s edge carried %.0f px out to the screen's edge", leftEdge ? "left" : "right", margin); }
        return YES;
    }
    float s = yl / vl;                                                                    // px a texel, upright
    float k = 1 / stretch;
    switch (kind) {
    case MA_TRUE: {                                                                       // the devs' own shape about its centre
        float cx = x + xl / 2;
        menuDrawXformed(canvas, stack, result, k, cx * (1 - k));
        static int logged; if (logged < 6) { logged++; LOG(@"menu shapes: %@ %.0f,%.0f %.0fx%.0f drawn %.0f px wide instead of %.0f", ibfix_objname(tex), u, v, ul, vl, xl * k, xl); }
        return YES;
    }
    case MA_ENDS: {                                                                       // the same size, true-shape ends
        float eL = endT[0] * s, eR = endT[1] * s;
        if (eL + eR >= xl) return NO;
        menuDrawXformed(canvas, stack, result, 0, x);                                     // the game's call, drawing nothing
        menuPiece(canvas, tex, x + eL - 0.5f, y, xl - eL - eR + 1, yl, u + endT[0], v + 0.5f, ul - endT[0] - endT[1], vl - 1, color, blend);
        menuPiece(canvas, tex, x, y, eL, yl, u + 0.5f, v + 0.5f, endT[0] - 0.5f, vl - 1, color, blend);
        menuPiece(canvas, tex, x + xl - eR, y, eR, yl, u + ul - endT[1], v + 0.5f, endT[1] - 0.5f, vl - 1, color, blend);
        static int logged; if (logged < 6) { logged++; LOG(@"menu shapes: %@ %.0f,%.0f %.0fx%.0f kept, its ends %.0f and %.0f px (were %.0f and %.0f)", ibfix_objname(tex), u, v, xl, yl, eL, eR, endT[0] * xl / ul, endT[1] * xl / ul); }
        return YES;
    }
    case MA_CORNER: {                                                                     // out to the screen's corner
        menuCornerRadius(W);
        float nw = ul * s, gap = menuCornerGap(s, W);
        float right = x + xl + margin - gap;                                              // follows the button as the screen slides
        int oSW = poff(CLS(gMenuScene), "Width");
        float sceneW = oSW > 0 ? *(float *)((uint8_t *)gMenuScene + oSW) : clipX;
        if (sceneW < clipX * 0.95f || margin < 1) {
            // a smaller screen's own corner (a pop-up's): the art's own shape, its right side kept
            menuDrawXformed(canvas, stack, result, k, (x + xl) * (1 - k));
            return YES;
        }
        menuDrawXformed(canvas, stack, result, 0, x);
        float ext = x + xl + margin - right;                                              // the art's last column, out to the edge
        menuPiece(canvas, tex, right - 1, y, ext + 2, yl, u + ul - 1.5f, v + 0.5f, 1, vl - 1, color, blend);
        menuPiece(canvas, tex, right - nw, y, nw, yl, u + 0.5f, v + 0.5f, ul - 1, vl - 1, color, blend);
        if (gMenuObj) {                                                                   // taps out to the screen's edge
            int oR = poff(CLS(gMenuObj), "RightLeeway");
            if (oR > 0 && *(float *)((uint8_t *)gMenuObj + oR) < margin) *(float *)((uint8_t *)gMenuObj + oR) = margin;
        }
        static int logged; if (logged < 3) { logged++; LOG(@"menu shapes: the corner button %.0fx%.0f at the screen's corner (%.0f px in from its edge for the arrow, corner radius %.0f px); taps out to the edge",
                                                         nw, yl, gap, gCornerRadiusPx); }
        return YES;
    }
    case MA_TAB: {                                                                        // slanted sides kept, icon square
        float sx = xl / ul;
        float wl = 24 * sx, wr = 24 * sx, wi = 44 * s, rest = xl - wl - wr - wi;
        if (rest <= 0) return NO;
        float ws1 = rest * 22 / 42, ws2 = rest * 20 / 42;
        menuDrawXformed(canvas, stack, result, 0, x);
        float px = x;
        const float cut[6] = { 0, 24, 46, 90, 110, 134 }; const float wd[5] = { wl, ws1, wi, ws2, wr };
        for (int i = 0; i < 5; i++) {
            menuPiece(canvas, tex, px - (i ? 0.5f : 0), y, wd[i] + (i ? 0.5f : 0) + (i < 4 ? 0.5f : 0), yl,
                      u + cut[i] + (i ? 0 : 0.5f), v + 0.5f, cut[i + 1] - cut[i] - (i == 0 || i == 4 ? 0.5f : 0), vl - 1, color, blend);
            px += wd[i];
        }
        static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the pause tab's icon %.0f px wide (was %.0f), its sides as they were", wi, 44 * sx); }
        return YES;
    }
    case MA_BAND: {                                                                       // its own grid out to both edges
        gOrigDrawTile(canvas, stack, result);
        if (margin < 1 || xl < clipX * 0.97f) return YES;
        // The pause screen masks its drawing to itself (bClipScene), which hides its main buttons parked just off the
        // region's left while ARENA MODE's panel slides in, so the mask stays. It reaches the screen's right edge (the
        // script-call hook widens the screen's Width for its RenderScene), so the right end is drawn here, under the
        // buttons and the arena panel; the left end just after the screen (gBandLater), outside the mask.
        float sx = xl / ul, period = 12 * sx;
        // an interior period at each end: relative texels 9-21 (a whole square after the line at 7-8) and its mirror
        for (float px = x + xl - 9 * sx; px < x + xl + margin + 1; px += period)
            menuPiece(canvas, tex, px, y, period, yl, u + ul - 9 - 12, v, 12, vl, color, blend);
        gBandLater.scene = gMenuScene; gBandLater.canvas = canvas; gBandLater.tex = tex;
        gBandLater.x = x; gBandLater.y = y; gBandLater.xl = xl; gBandLater.yl = yl; gBandLater.u = u; gBandLater.v = v;
        gBandLater.ul = ul; gBandLater.vl = vl; gBandLater.margin = margin; memcpy(gBandLater.color, color, sizeof gBandLater.color);
        static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the pause band's grid carried %.0f px out to both edges (its mask kept, out to the right edge)", margin); }
        return YES;
    }
    case MA_HUDBAND: {                                                                    // the fight's band, out to both edges
        gOrigDrawTile(canvas, stack, result);
        if (margin < 1 || xl < clipX * 0.97f) return YES;
        // its grid strip (rows 0-7) continued on its own repeat (7 texels, an interior period: texels 9-16 at the left,
        // 944-951 at the right), its black body and shading (rows 7-100) from its outermost column; the bars' frames
        // and the bars stay where they are (fix 5: the band was never stretched, so full health never looks short)
        float sx = xl / ul, sy = yl / vl, gp = 7 * sx, gh = 7 * sy;
        for (float px = x + 9 * sx - gp; px + gp > x - margin - 1; px -= gp) {
            float w = fminf(gp, x + 1 - px); if (w > 0) menuPiece(canvas, tex, px, y, w, gh, u + 9, v, w / sx, 7, color, blend);
        }
        for (float px = x + xl - 16 * sx; px < x + xl + margin + 1; px += gp) {
            float a = fmaxf(px, x + xl - 1), w = px + gp - a;
            if (w > 0) menuPiece(canvas, tex, a, y, w, gh, u + 944 + (a - px) / sx, v, w / sx, 7, color, blend);
        }
        menuPiece(canvas, tex, x - margin - 1, y + gh, margin + 2, yl - gh, u + 0.5f, v + 7, 0.01f, vl - 7, color, blend);
        menuPiece(canvas, tex, x + xl - 1, y + gh, margin + 2, yl - gh, u + ul - 0.5f, v + 7, 0.01f, vl - 7, color, blend);
        static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the fight's health band carried %.0f px out to both edges", margin); }
        return YES;
    }
    case MA_HEX: {                                                                        // its own hex out to the left edge
        gOrigDrawTile(canvas, stack, result);
        if (margin < 1 || !leftEdge) return YES;
        float sx = xl / ul, P = 10.78f, period = P * sx;
        for (float px = x + 1 * sx - period; px + period > x - margin - 1; px -= period)
            menuPiece(canvas, tex, px, y, period, yl, u + 1, v + 0.5f, P, vl - 1, color, blend);
        static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the Character panel carried %.0f px out to the left edge", margin); }
        return YES;
    }
    case MA_XPEND: {                                                                      // its last column out to the edge
        gOrigDrawTile(canvas, stack, result);
        if (margin < 1 || !rightEdge) return YES;
        menuPiece(canvas, tex, x + xl - 1, y, margin + 2, yl, u + ul - 1.5f, v + 0.5f, 1, vl - 1, color, blend);
        static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the XP bar carried %.0f px out to the right edge", margin); }
        return YES;
    }
    }
    return NO;
}
static void my_execDrawTile(void *canvas, void *stack, void *result) {
    installVolumeSliders(canvas);
    gLastCanvas = canvas;                                       // 4ai: the canvas a row or the box is drawing with
    uint8_t **code = (uint8_t **)((uint8_t *)stack + FFRAME_CODE);
    uint8_t *start = *code;
    // Arguments: Tex, XL, YL, U, V, UL, VL, LColor (then ClipTile, Blend; the game's code always
    // reads all ten, so the first eight are always there).
    union { void *p; float f[4]; } arg[8];
    memset(arg, 0, sizeof arg);
    for (int c = 0; c < 4; c++) arg[7].f[c] = 1;      // LColor when the script leaves it out
    uint8_t tokColour = 0;
    for (int i = 0; i < 8; i++) { if (i == 7) tokColour = **code; stepExpr(stack, &arg[i]); }
    *code = start;                                      // rewind: the original evaluates them again
    // Left out (the call's parameters end, or an empty one), the engine draws in the canvas's own DrawColor, an FColor
    // (B, G, R, A) turned into light (3i draws some pieces itself, so it needs the same colour)
    BOOL colourGiven = !(tokColour == 0x16 || tokColour == 0x4a || tokColour == 0x0b);
    float drawColour[4];
    if (colourGiven) memcpy(drawColour, arg[7].f, sizeof drawColour);
    else {
        static int oDC = -2; if (oDC == -2) oDC = poff(CLS(canvas), "DrawColor");
        const uint8_t *dc = oDC > 0 ? (const uint8_t *)canvas + oDC : NULL;
        if (dc) { drawColour[0] = powf(dc[2] / 255.0f, 2.2f); drawColour[1] = powf(dc[1] / 255.0f, 2.2f); drawColour[2] = powf(dc[0] / 255.0f, 2.2f); drawColour[3] = dc[3] / 255.0f; }
        else memcpy(drawColour, arg[7].f, sizeof drawColour);
    }
    void *tex = arg[0].p; float xl = arg[1].f[0], yl = arg[2].f[0];
    keepTitleLogo(tex);
    if (!gAnyTexture && tex && menuSheet(tex)) gAnyTexture = tex;  // 4ai: a Texture2D, to find Texture2D.Create through
#ifdef IBFIX_SNAPS
    badgeTitleTest(canvas, tex);                                // 4ai: test builds prove the badge sheet's upload on the title
#endif
#ifdef IBFIX_SNAPS
    menuSurvey(canvas, tex, xl, yl, arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0], "tile");
#endif
    // 3i: the menus' pictures at their own shape and out to the screen's edges (the game's own blend for these: translucent)
    if (menuShapes(canvas, stack, result, tex, xl, yl, arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0], drawColour, 2)) return;
#ifdef IBFIX_SNAPS
    {   // Diagnostic: every large tile (half the region wide or a third high), once per 10 s per image
        float cx = *(float *)((uint8_t *)canvas + 0x70), cy = *(float *)((uint8_t *)canvas + 0x74);
        if (cx > 0 && cy > 0 && (xl >= cx * 0.5f || yl >= cy * 0.3f)) {
            static NSMutableDictionary<NSString *, NSNumber *> *seen; if (!seen) seen = [NSMutableDictionary dictionary];
            NSString *k = [NSString stringWithFormat:@"%p %.0f %.0f %.0f %.0f", tex, arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0]];
            CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
            static CFAbsoluteTime lastShot; static int shots;                 // a few pictures of the fight HUD to check against
            if (shots < 6 && tn - lastShot > 6 && yl >= cy * 0.3f && ibfix_auto_photos()) { lastShot = tn; ibfix_snap([NSString stringWithFormat:@"hud-%d", ++shots]); }
            if (!seen[k] || tn - seen[k].doubleValue > 10) {
                seen[k] = @(tn);
                LOG(@"big tile: %@ at %.1f,%.1f size %.1fx%.1f of %.0fx%.0f | UV %.0f,%.0f %.0fx%.0f | colour %.2f %.2f %.2f %.2f",
                    tex ? ibfix_objname(tex) : @"none", *(float *)((uint8_t *)canvas + 0x78), *(float *)((uint8_t *)canvas + 0x7c), xl, yl, cx, cy,
                    arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0], arg[7].f[0], arg[7].f[1], arg[7].f[2], arg[7].f[3]);
            }
        }
    }
    if (fabsf(arg[5].f[0] - 68) < 0.5f && fabsf(arg[6].f[0] - 42) < 0.5f) {      // the skip (fast-forward) button image
        static CFAbsoluteTime lastFF; CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
        if (tn - lastFF > 2) { lastFF = tn; ibfix_skip_zone_log([NSString stringWithFormat:@"drawn at canvas %.1f,%.1f size %.1fx%.1f (UV %.0f,%.0f) | canvas origin %.1f,%.1f clip %.1fx%.1f",
            *(float *)((uint8_t *)canvas + 0x78), *(float *)((uint8_t *)canvas + 0x7c), xl, yl, arg[3].f[0], arg[4].f[0],
            *(float *)((uint8_t *)canvas + 0x68), *(float *)((uint8_t *)canvas + 0x6c), *(float *)((uint8_t *)canvas + 0x70), *(float *)((uint8_t *)canvas + 0x74)]); }
    }
#endif
    if (gDodgeArt && tex && drawDodgeTile(canvas, stack, result, tex, xl, yl, arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0], arg[7].f)) return;
    float orgX = *(float *)((uint8_t *)canvas + 0x68), clipX = *(float *)((uint8_t *)canvas + 0x70);
    float curX = *(float *)((uint8_t *)canvas + 0x78);
    float W = gViewportWidth;
    void *fcanvas = *(void **)((uint8_t *)canvas + 0x98);
    float clipY = *(float *)((uint8_t *)canvas + 0x74), curY = *(float *)((uint8_t *)canvas + 0x7c);
    // Where a tile really is: the canvas origin plus its position. Lists and inventories draw each row after
    // Canvas.SetOrigin(the row's corner), so a row's background at x 0 is not at the screen's edge (FIXES.md 89).
    float orgY = *(float *)((uint8_t *)canvas + 0x6c), absX = orgX + curX, absY = orgY + curY;
    // Every region-wide tile (cutscene black bars, flashes, shading) except the
    // health-bar band at the top (y 0, 100 of 640 design units high): that band stays the width of
    // the bars, because stretching it stretches the empty bar tracks, making full health look lost.
    BOOL healthBand = fabsf(absY) < 2 && fabsf(yl - clipY * 100.0f / 640.0f) < 3;   // y 0, 100 of 640 high
    BOOL fullWidth = fcanvas && W > clipX + 1 && clipX > 0 && xl >= clipX * 0.97f && fabsf(absX) <= clipX * 0.02f && !healthBand;
    // Sliding menu backgrounds (SwordDrawBackground with bWrap, e.g. behind the battle results) are drawn as two pieces
    // whose split moves every frame (FIXES.md 10): a texture once drawn full-width and full-height is remembered as a
    // background, and its full-height pieces touching a region edge get the same stretch, so together they fill the screen.
    BOOL fullHeight = clipY > 0 && yl >= clipY * 0.95f && fabsf(absY) <= clipY * 0.02f;
    static void *bgTex[8]; static int bgNext;
    BOOL knownBg = NO;
    for (int i = 0; i < 8 && tex; i++) if (bgTex[i] == tex) { knownBg = YES; break; }
    if (fullWidth && fullHeight && tex && !knownBg) { bgTex[bgNext++ % 8] = tex; knownBg = YES; }
    BOOL bgPiece = !fullWidth && knownBg && fullHeight && fcanvas && W > clipX + 1 &&
                   (fabsf(absX) <= clipX * 0.02f || fabsf(absX + xl - clipX) <= clipX * 0.02f);
    if (!fullWidth && !bgPiece) {
        origDrawTileScreenClip(canvas, stack, result, absX + xl);   // 3i: cut at the screen's edge, not the region's
        if (fullHeight && fcanvas && W > clipX + 1) extendFrameColumn(canvas, tex, curX, *(float *)((uint8_t *)canvas + 0x7c), xl, yl,
                                                                     arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0], arg[7].f, (W - clipX) / 2);
        return;
    }
    // The region's left offset is already in the canvas projection (the top of the transform stack), applied after this
    // matrix; so stretch about the region's left edge and shift left by the margin: x' = x * a + b. Sliding-background
    // pieces use the region's scale, x' = x * W/ClipX - margin, so they stay continuous. A full-width tile is mapped from
    // its own extent onto the whole screen: such tiles are often a pixel short of the region (the credits' black sheet),
    // and the region's scale left that pixel as a sliver at the right edge.
    float margin = (W - clipX) / 2;
    BOOL exact = fullWidth && xl > 0 && xl < clipX;          // only tiles a little short of the region
    float a = exact ? W / xl : W / clipX;
    float b = exact ? -margin - a * curX : -margin;
    float m[16] = { a,0,0,0,  0,1,0,0,  0,0,1,0,  b,0,0,1 };
    static int dumped;
    if (dumped < 1) {
        dumped++;
        // FCanvas transform stack: TArray data +0x38, Num +0x40, element 0x50 (FMatrix first).
        uint8_t *data = *(uint8_t **)((uint8_t *)fcanvas + 0x38); int num = *(int *)((uint8_t *)fcanvas + 0x40);
        float *top = (data && num > 0) ? (float *)(data + (size_t)(num - 1) * 0x50) : NULL;
        LOG(@"backgrounds: tile curX %.1f orgX %.1f clipX %.1f xl %.1f | stack %d top row0 %.3f %.3f row3 %.1f %.1f", curX, orgX, clipX, xl, num,
            top ? top[0] : 0, top ? top[1] : 0, top ? top[12] : 0, top ? top[13] : 0);
    }
    gPushRelative(fcanvas, m);
    gOrigDrawTile(canvas, stack, result);
    POP_XFORM(canvas);
    static int logged, loggedPieces;
    if (!bgPiece && logged < 3) { logged++; LOG(@"backgrounds: widened a %.0f px tile to the full %.0f px", xl, W); }
    if (bgPiece && loggedPieces < 4) { loggedPieces++; LOG(@"backgrounds: stretched a sliding background piece at x %.0f, %.0f px wide", curX, xl); }
}

// The tutorial pop-ups draw their pictures, including the dark panels and dimming laid over the screen, with
// Canvas.DrawRotatedTile (Tex, Rotation, XL, YL, U, V, UL, VL, optional AnchorX = 0.5, AnchorY = 0.5): the tile's
// top-left is at CurX/Y and it turns about the anchor. An unrotated one spanning (nearly) the region's width, centred,
// gets the same stretch as a full-width DrawTile (FIXES.md 11).
#define IB1_NATIVE_DRAWROT_ENTRY 0x100bcd548ULL
static const char *kDrawRotName = "UCanvasexecDrawRotatedTile";
static NativeFn gOrigDrawRot;

static void my_execDrawRotatedTile(void *canvas, void *stack, void *result) {
    uint8_t **code = (uint8_t **)((uint8_t *)stack + FFRAME_CODE);
    uint8_t *start = *code;
    union { void *p; int i[4]; float f[4]; } arg[10];
    memset(arg, 0, sizeof arg);
    arg[8].f[0] = arg[9].f[0] = 0.5f;                   // AnchorX/Y when the script leaves them out
    for (int i = 0; i < 10; i++) stepExpr(stack, &arg[i]);
    *code = start;                                      // rewind: the original evaluates them again
    float xl = arg[2].f[0], ax = arg[8].f[0]; (void)ax;
    int yaw = arg[1].i[1] & 0xffff;                     // Rotator: Pitch, Yaw, Roll
    float clipX = *(float *)((uint8_t *)canvas + 0x70), curX = *(float *)((uint8_t *)canvas + 0x78);
    float W = gViewportWidth;
    void *fcanvas = *(void **)((uint8_t *)canvas + 0x98);
    float orgX = *(float *)((uint8_t *)canvas + 0x68);  // where it really is: origin plus position (as in DrawTile above)
    float left = orgX + curX, right = orgX + curX + xl; // CurX/Y is the top-left; the anchor is only the pivot
    // Region-wide pictures, and the tutorials' dark panels that are a touch narrower on purpose
    // (920 of 960 units, centred: SwordTutorial.ini Block2, Dodge3): stretched about the region,
    // those keep their small margin, now measured from the screen edge.
    BOOL fullWidth = fcanvas && yaw == 0 && W > clipX + 1 && clipX > 0 && xl >= clipX * 0.95f &&
                     fabsf(left + right - clipX) <= clipX * 0.02f;
#ifdef IBFIX_SNAPS
    menuSurvey(canvas, arg[0].p, xl, arg[3].f[0], arg[4].f[0], arg[5].f[0], arg[6].f[0], arg[7].f[0], yaw ? "turned tile" : "pop-up tile");
#endif
#ifdef IBFIX_TEST_TOOLS
    static int seen;
    if (xl > clipX * 0.4f && seen < 30) { seen++;
        LOG(@"rotated tile: %@ curX %.0f curY %.0f xl %.0f yl %.0f anchor %.2f,%.2f yaw %d clipX %.0f -> %@", ibfix_objname(arg[0].p),
            curX, *(float *)((uint8_t *)canvas + 0x7c), xl, arg[3].f[0], ax, arg[9].f[0], yaw, clipX, fullWidth ? @"widen" : @"leave"); }
#endif
    // 3i: the arena's INFO pages' picture (B_Info 431,0 593x396, behind their writing): at its own shape, covering the
    // screen (the screen's width, its top and bottom trimmed equally) instead of stretched across it (FIXES.md 97)
    if (fullWidth && gMenuScene && arg[0].p && menuSheet(arg[0].p) == 5 && lroundf(arg[4].f[0]) == 431 && lroundf(arg[5].f[0]) == 0 &&
        lroundf(arg[6].f[0]) == 593 && lroundf(arg[7].f[0]) == 396 && arg[3].f[0] > 0) {
        float yl = arg[3].f[0], ty = *(float *)((uint8_t *)canvas + 0x6c) + *(float *)((uint8_t *)canvas + 0x7c);
        float d = (W * 396.0f / 593.0f) / yl, cy = ty + yl / 2, a = W / clipX, margin = (W - clipX) / 2;
        if (d > 1) {
            float m[16] = { a,0,0,0,  0,d,0,0,  0,0,1,0,  -margin,cy * (1 - d),0,1 };
            gPushRelative(fcanvas, m);
            gOrigDrawRot(canvas, stack, result);
            POP_XFORM(canvas);
            static int logged; if (logged < 2) { logged++; LOG(@"menu shapes: the arena INFO picture at its own shape, %.0f px tall (the screen %.0f), covering it", yl * d, yl); }
            return;
        }
    }
    // 3i: the lessons' and INFO pages' pictures of the HUD (its icons, drawn unturned at the devs' own shape in 960 x 640
    // units, so too wide here) at their own shape about their centre, like the HUD's own (FIXES.md 97)
    if (!fullWidth && gMenuScene && yaw == 0 && arg[0].p && menuSheet(arg[0].p) && clipX > 0 && arg[3].f[0] > 0 && arg[7].f[0] != 0) {
        float yl = arg[3].f[0], clipY = *(float *)((uint8_t *)canvas + 0x74);
        float stretch = clipY > 0 ? (clipX / 960) / (clipY / 640) : 1;
        float r = fabsf(xl / yl) / fabsf(arg[6].f[0] / arg[7].f[0]);
        BOOL blockShield = menuSheet(arg[0].p) == 4 && lroundf(arg[6].f[0]) == 226 && lroundf(arg[7].f[0]) == 149;   // kept wide, as the HUD's
        if (stretch > 1.05f && fabsf(r / stretch - 1) < 0.03f && xl < clipX * 0.5f && !blockShield) {
            float k = 1 / stretch, cx = left + xl / 2;
            float m[16] = { k,0,0,0,  0,1,0,0,  0,0,1,0,  cx * (1 - k),0,0,1 };
            gPushRelative(fcanvas, m);
            gOrigDrawRot(canvas, stack, result);
            POP_XFORM(canvas);
            static int logged; if (logged < 4) { logged++; LOG(@"menu shapes: a lesson's picture %@ %.0f,%.0f %.0fx%.0f drawn %.0f px wide instead of %.0f",
                                                              ibfix_objname(arg[0].p), arg[4].f[0], arg[5].f[0], arg[6].f[0], arg[7].f[0], xl * k, xl); }
            return;
        }
    }
    if (!fullWidth) { gOrigDrawRot(canvas, stack, result); return; }
    float a = W / clipX, margin = (W - clipX) / 2;
    float m[16] = { a,0,0,0,  0,1,0,0,  0,0,1,0,  -margin,0,0,1 };
    gPushRelative(fcanvas, m);
    gOrigDrawRot(canvas, stack, result);
    POP_XFORM(canvas);
    static int logged; if (logged < 3) { logged++; LOG(@"backgrounds: widened a %.0f px pop-up picture to the full %.0f px", xl, W); }
}

static void hookBackgrounds(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **dt = (void **)(IB1_NATIVE_DRAWTILE_ENTRY + slide), **pop = (void **)(IB1_NATIVE_POPXFORM_ENTRY + slide);
    if (!dt[-1] || strcmp((const char *)dt[-1], kDrawTileName) || !pop[-1] || strcmp((const char *)pop[-1], kPopXformName)) {
        LOG(@"backgrounds fix OFF: native table not where expected"); return;
    }
    gNatives = (MemberFn *)(IB1_GNATIVES + slide);
    gPushRelative = (void (*)(void *, const float *))(IB1_FCANVAS_PUSHRELATIVE + slide);
    gPopTransform = (NativeFn)pop[0];
    gOrigDrawTile = (NativeFn)dt[0];
    dt[0] = (void *)my_execDrawTile;
    void **dr = (void **)(IB1_NATIVE_DRAWROT_ENTRY + slide);
    if (dr[-1] && strcmp((const char *)dr[-1], kDrawRotName) == 0) { gOrigDrawRot = (NativeFn)dr[0]; dr[0] = (void *)my_execDrawRotatedTile; }
    LOG(@"backgrounds fix ON%@", gOrigDrawRot ? @" (and pop-up pictures)" : @" (pop-up pictures OFF)");
}

// ---- 3c. Things attached to the 3D scene (touch circles) ------------------------------------
// ASwordMobileTouchActor::NativePostRenderFor projects its 3D spot with the scene view (true screen pixels: view origin
// +0x58, size +0x60) but draws the circle with UCanvas::DrawTile, whose coordinates are canvas-relative, so with the HUD
// region inset the circle was drawn shifted right by the margin, off the enemy (FIXES.md 6). The engine calls it through
// the class's vtable (in the writable __DATA segment), so that slot points at a wrapper which shifts the view origin left
// by the margin while the game's own code runs; touches are region-relative too, so they still match.
// Arguments: this, PlayerController, Canvas (UCanvas+0xa0 = FSceneView*), camera position and direction (six floats).

#define IB1_TOUCHACTOR_VTABLE 0x100b8b770ULL
#define IB1_TOUCHACTOR_PRF    0x1009274e0ULL
#define VT_NATIVEPOSTRENDERFOR 0x2c0
typedef void (*PostRenderForFn)(void *self, void *pc, void *canvas, float, float, float, float, float, float);
static PostRenderForFn gOrigTouchActorPRF;
static void circleFullBox(uint8_t *a);          // 4r: the box taps are tested against, at the circle's full size
static float gTouchCircleMargin;                // the HUD region's left margin in pixels (circles' DrawPos is relative to it)
static float gTouchCircleMarginY;               // and its top margin (the iPad's 3:2 band, 3g)

// 4r2. Only a circle the game drew this frame is grown and takes taps (FIXES.md 91). The game's native drawing stores a
// circle's box (DrawPos, DrawSize) only when it draws it, so circleFullBox grew a stale box again every frame: a box the
// call left exactly as it was isn't grown or noted as drawn; my_processWorldTouch takes only circles drawn in the last
// quarter of a second and ignores boxes over half the region.
static BOOL plausibleObj(const uint8_t *p);
static struct { uint8_t *a; CFAbsoluteTime t; } gCircleDrawnAt[64];
static void circleDrawnNote(uint8_t *a) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); int old = 0;
    for (int i = 0; i < 64; i++) {
        if (gCircleDrawnAt[i].a == a) { gCircleDrawnAt[i].t = now; return; }
        if (gCircleDrawnAt[i].t < gCircleDrawnAt[old].t) old = i;
    }
    gCircleDrawnAt[old].a = a; gCircleDrawnAt[old].t = now;
}
static BOOL circleDrawnRecently(uint8_t *a) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < 64; i++) if (gCircleDrawnAt[i].a == a) return now - gCircleDrawnAt[i].t <= 0.25;
    return NO;
}
static void my_touchActorPostRenderForIn(void *self, void *pc, void *canvas, float a, float b, float c, float d, float e, float f);
static void my_touchActorPostRenderFor(void *self, void *pc, void *canvas, float a, float b, float c, float d, float e, float f) {
    float before[4] = {0}; int oP = -1, oS = -1;
    if (plausibleObj(self)) { void *cls = CLS(self); oP = poff(cls, "DrawPos"); oS = poff(cls, "DrawSize"); }
    if (oP >= 0 && oS >= 0) { memcpy(before, (uint8_t *)self + oP, 8); memcpy(before + 2, (uint8_t *)self + oS, 8); }
    my_touchActorPostRenderForIn(self, pc, canvas, a, b, c, d, e, f);
    if (oP >= 0 && oS >= 0) {
        float after[4]; memcpy(after, (uint8_t *)self + oP, 8); memcpy(after + 2, (uint8_t *)self + oS, 8);
        if (!memcmp(before, after, sizeof after)) return;          // not drawn this frame: not grown, not tappable
    }
    circleFullBox(self); circleDrawnNote(self);
}
static void my_touchActorPostRenderForIn(void *self, void *pc, void *canvas, float a, float b, float c, float d, float e, float f) {
    float W = gViewportWidth;
    float clipX = canvas ? *(float *)((uint8_t *)canvas + 0x70) : 0;
    uint8_t *view = canvas ? *(uint8_t **)((uint8_t *)canvas + 0xa0) : NULL;
    // The region's top margin: the iPad's 3:2 band sits Y pixels down (3g); the iPhone's region starts at the top.
    float marginY = gRegionPx[3] > 0 ? (float)gRegionPx[1] : 0;
    if (!view || clipX <= 0 || (W <= clipX + 1 && marginY < 0.5f)) { gOrigTouchActorPRF(self, pc, canvas, a, b, c, d, e, f); return; }
    float margin = W > clipX + 1 ? (W - clipX) / 2 : 0;
    gTouchCircleMargin = margin; gTouchCircleMarginY = marginY;
    float *originX = (float *)(view + 0x58), *originY = (float *)(view + 0x5c);
    float saved = *originX, savedY = *originY;
    static BOOL logged;
    if (!logged) { logged = YES; LOG(@"touch circles: drawn relative to the HUD region (margins %.0f, %.0f px; the view's origin %.1f, %.1f)", margin, marginY, saved, savedY); }
    // 4r3. Circles reach the screen's edges (FIXES.md 91). The native skips a circle whose box lies past the canvas's ClipX
    // or wholly before its OrgX, and UCanvas::DrawTile cuts every tile at OrgX + ClipX (the HUD region's edges), so for
    // this one call the canvas's limits are the screen's.
    float *org = (float *)((uint8_t *)canvas + 0x68), *clip = (float *)((uint8_t *)canvas + 0x70);
    float o0 = org[0], o1 = org[1], c0 = clip[0], c1 = clip[1];
    *originX = saved - margin; *originY = savedY - marginY;
    org[0] = o0 - margin; org[1] = o1 - marginY; clip[0] = c0 + 2 * margin; clip[1] = c1 + 2 * marginY;
    gOrigTouchActorPRF(self, pc, canvas, a, b, c, d, e, f);
    org[0] = o0; org[1] = o1; clip[0] = c0; clip[1] = c1;
    *originX = saved; *originY = savedY;
}

static void hookTouchActors(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **slot = (void **)(IB1_TOUCHACTOR_VTABLE + slide + VT_NATIVEPOSTRENDERFOR);
    if (*slot != (void *)(IB1_TOUCHACTOR_PRF + slide)) { LOG(@"touch circles fix OFF: vtable not as expected"); return; }
    gOrigTouchActorPRF = (PostRenderForFn)*slot;
    *slot = (void *)my_touchActorPostRenderFor;
    LOG(@"touch circles fix ON");
}

// ---- 3g. The iPad (26 October 2026; FIXES.md 77) ---------------------------------------------
// The game works out its device once (GetDeviceType 0x1009009f0, cached in 0x100be8d70, 17 = not yet). For an iPad it
// reads one digit of the model code ("iPad14,8" -> 1, the 2010 iPad, type 7), too weak for the opening film. An iPad with
// a two-digit model number is given type 14 (the devs' iPad Air 2) first; only the start-up and the settings lookup read
// it. The settings lookup (0x1008e4934) keeps its own copy (0x100cebf18, one-time guard 0x100cebf48): set to 17 and done,
// it reads SystemSettingsIPhone3GS, our graphics settings (FIXES.md 32). Each value is checked before it's written.
// Layout chosen (FIXES.md 77): the iPad fills its screen as the iPhone does (HUD region: section 3; 3D view: section 9),
// not the devs' 3:2 picture with bars; Documents/ibfix-ipad-3x2 brings theirs back for one launch, to compare.
#define IB1_DEVICETYPE_CACHE  0x100be8d70ULL
#define IB1_SETTINGS_TYPE     0x100cebf18ULL
#define IB1_SETTINGS_GUARD    0x100cebf48ULL
static void setupIPad(void) {
    char model[64] = {0}; size_t len = sizeof model - 1;
    if (sysctlbyname("hw.machine", model, &len, NULL, 0) != 0 || strncmp(model, "iPad", 4) != 0) return;
    gIsIPad = YES;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    volatile int32_t *type = (int32_t *)(IB1_DEVICETYPE_CACHE + slide), *copy = (int32_t *)(IB1_SETTINGS_TYPE + slide);
    volatile uint8_t *guard = (uint8_t *)(IB1_SETTINGS_GUARD + slide);
    BOOL twoDigits = model[4] >= '1' && model[4] <= '9' && model[5] >= '0' && model[5] <= '9';
    if (twoDigits && *type == 17) { *type = 14; LOG(@"iPad: %s counted as an iPad Air 2 for the start-up (the game's one-digit read gave the 2010 iPad): film and Start button", model); }
    else LOG(@"iPad: %s, device type left as it is (%d)", model, *type);
    if (*copy == 0 && *guard == 0) { *copy = 17; *guard = 1; LOG(@"iPad: picture settings from SystemSettingsIPhone3GS, the iPhone 17's section"); }
    else LOG(@"iPad: settings lookup not as expected (%d, %d), left alone", *copy, *guard);
    NSString *docs = DOCUMENTS;
    gIPadFill = ![[NSFileManager defaultManager] fileExistsAtPath:[docs stringByAppendingPathComponent:@"ibfix-ipad-3x2"]];
    LOG(@"iPad: layout %@", gIPadFill ? @"full screen, as the iPhone" : @"the devs' 3:2 iPad picture (comparison setting)");
}

// Settings kept on each device (FIXES.md 77), checked at every start:
// - The devs' four "NEW! CONTENT PACK" pages: once per session, at the first save point, the game shows the next one and
//   counts it in the device's profile (SwordPC.DoShowContentPackInfo, "IPhoneHome::LastTutorialContent" in NSUserDefaults,
//   up to 4), so a new device showed them one by one. All four count as seen on every device (by choice, FIXES.md 77).
// - Our own Options settings (sliders, switches, the music remembered at save points) live in each device's
//   NSUserDefaults. A file Documents/ibfix-settings.plist (put there from the Mac, e.g. the iPhone's settings for the
//   iPad) is copied in, its "ibfix..." keys only, then removed.
static void devicePrefs(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *k = @"IPhoneHome::LastTutorialContent";
    int seen = [[ud objectForKey:k] intValue];
    if (seen < 4) { [ud setObject:@"4" forKey:k]; LOG(@"content pack pages: counted as seen (were %d of 4 on this device)", seen); }
    NSString *f = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-settings.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:f];
    if (!d) return;
    int n = 0;
    for (NSString *key in d) if ([key isKindOfClass:[NSString class]] && [key hasPrefix:@"ibfix"]) { [ud setObject:d[key] forKey:key]; n++; }
    [[NSFileManager defaultManager] removeItemAtPath:f error:nil];
    LOG(@"settings: %d copied in from ibfix-settings.plist (%@)", n, [[d.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]);
}

// ---- 4. Status bar and home indicator -----------------------------------------------------
// The bottom edge is also claimed for the game (preferredScreenEdgesDeferringSystemGestures): iOS otherwise holds back
// every touch in the bottom strip (about 32 pt, where the swipe home starts) until the finger lifts, then delivers press
// and release at once, and the fast-forward button there is a hold button (FIXES.md 27). Claimed, the touches arrive at
// once; going home takes two swipes up (the first shows the home bar), as in most games.

static BOOL vc_yes(id self, SEL _cmd) { return YES; }
static UIRectEdge vc_bottomEdge(id self, SEL _cmd) { return UIRectEdgeBottom; }

static void hookViewController(void) {
    Class c = NSClassFromString(@"IPhoneViewController"); if (!c) { LOG(@"status bar fix OFF: no IPhoneViewController"); return; }
    class_replaceMethod(c, @selector(prefersStatusBarHidden), (IMP)vc_yes, "B@:");
    class_replaceMethod(c, @selector(prefersHomeIndicatorAutoHidden), (IMP)vc_yes, "B@:");
    class_replaceMethod(c, @selector(preferredScreenEdgesDeferringSystemGestures), (IMP)vc_bottomEdge, "Q@:");
    for (int s = 1; s <= 3; s += 2)                             // let iOS ask again once the window is up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)s * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            for (UIWindow *w in [UIApplication sharedApplication].windows)
                if ([w.rootViewController isKindOfClass:c]) [w.rootViewController setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        });
    LOG(@"status bar / home indicator fix ON (bottom edge claimed for the game's touches)");
}

// ---- 4b. Start button placement ------------------------------------------------------------
// The Start (play) button is a StartButtonView sized half the screen wide at 60% across; its icon (Start.png pixels
// 249-337 x 108-196 of 512x256) landed over the right edge of the start-up film's 3:2 picture. After
// ShowStartButtonWithExecCommand: the view is moved, at the same size, so the icon sits right of that picture (now over
// the film's widened stone, FIXES.md 24). kStartButtonPlacement: 'A' = 8 pt right of the 3:2 picture, 'B' = centred
// between it and the screen edge (FIXES.md 13).

static const char kStartButtonPlacement = 'B';
static IMP oShowStart;

static void m_showStart(id self, SEL _cmd, id cmd) {
    ((void (*)(id, SEL, id))oShowStart)(self, _cmd, cmd);
    UIView *b = [self respondsToSelector:NSSelectorFromString(@"StartButton")] ? [self valueForKey:@"StartButton"] : nil;
    UIView *host = b.superview; if (!b || !host) return;
    CGFloat W = host.bounds.size.width, H = host.bounds.size.height;
    if (H <= 0 || W / H < 1.8) return;                          // only on wide screens
    CGRect f = b.frame;
    CGFloat k = f.size.width / 512.0;                           // view points per image pixel
    CGFloat icon = 88 * k, filmRight = (W + 1.5 * H) / 2;
    CGFloat cx = kStartButtonPlacement == 'A' ? filmRight + 8 + icon / 2 : (filmRight + W) / 2;
    CGFloat cy = f.origin.y + 152 * k;                          // keep the icon's height on screen
    f.origin.x = cx - 293 * k; f.origin.y = cy - 152 * k;
    b.frame = f;
    LOG(@"start button: icon centre moved to %.1f,%.1f (film ends at %.1f, screen %.0f)", cx, cy, filmRight, W);
}

static void hookStartButton(void) {
    Class c = NSClassFromString(@"IPhoneAppDelegate");
    oShowStart = hookMethod(c, NSSelectorFromString(@"ShowStartButtonWithExecCommand:"), (IMP)m_showStart);
    if (!oShowStart) { LOG(@"start button fix OFF"); return; }
}

// ---- 4d. Full sharpness on any screen ------------------------------------------------------
// The game draws at MobileContentScaleFactor x the screen's size in points, a number from the device profile it picks,
// not the screen (an iPhone 17 is taken for an iPhone 6 Plus, 2.6087). FEngineLoop::PreInit loads it into the system
// settings (GSystemSettings 0x100cbbbf0 + 0x484); EAGLView's CreateFramebuffer (main thread) then sets the view's
// contentScaleFactor from it, and the game thread copies it to GlobalViewScale, which turns touch points into game
// pixels. Set to the screen's own scale (UIScreen nativeScale) just before CreateFramebuffer, the picture is as sharp as
// the screen on any iPhone or iPad, with touches still lined up (FIXES.md 22).

#define IB1_MOBILECONTENTSCALE 0x100cbc074ULL
static IMP oCreateFramebuffer;

static uintptr_t m_createFramebuffer(id self, SEL _cmd) {
    float *scale = (float *)(IB1_MOBILECONTENTSCALE + _dyld_get_image_vmaddr_slide(0));
    float native = (float)[UIScreen mainScreen].nativeScale;
    if (native >= 1 && native <= 4 && fabsf(*scale - native) > 0.001f) {
        LOG(@"sharpness: the device profile's %.4f replaced by the screen's own %.4f", *scale, native);
        *scale = native;
    }
    return ((uintptr_t (*)(id, SEL))oCreateFramebuffer)(self, _cmd);
}

static void hookSharpness(void) {
    Class c = NSClassFromString(@"EAGLView");
    oCreateFramebuffer = hookMethod(c, NSSelectorFromString(@"CreateFramebuffer"), (IMP)m_createFramebuffer);
    if (!oCreateFramebuffer) { LOG(@"sharpness fix OFF: no EAGLView CreateFramebuffer"); return; }
}

// ---- 4e. Start-up film events (log) --------------------------------------------------------
// The game plays Default.m4v with the old MPMoviePlayerController. Log what the player reports (load and playback state
// changes, and why it finished, with any error), so a film that won't play shows its reason in the log (FIXES.md 23).
// The film is widened to the iPhone 17's shape (FIXES.md 24); the game shows it aspect-fit, which leaves slivers or bars
// on other shapes. When the film is the widened one and the screen is wider than 3:2, it is shown aspect-fill, trimming
// only the new side stone; the 3:2 picture in the middle is always whole. A 3:2 film keeps the game's own aspect-fit.

void ibfix_film_appeared(void);   // ibfix.m: mixing audio mode while the film plays
static void noLiveText(void);     // 4ah: no Live Text button on the films

static void hookFilmLog(void) {
    NSArray *names = @[@"MPMoviePlayerLoadStateDidChangeNotification", @"MPMoviePlayerPlaybackStateDidChangeNotification",
                       @"MPMoviePlayerPlaybackDidFinishNotification", @"MPMoviePlayerReadyForDisplayDidChangeNotification"];
    for (NSString *n in names)
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            id mp = note.object;
            ibfix_film_appeared();
            noLiveText();                                           // 4ah
            CGSize scr = [UIScreen mainScreen].bounds.size;
            SEL sm = NSSelectorFromString(@"scalingMode"), setSm = NSSelectorFromString(@"setScalingMode:"), ns = NSSelectorFromString(@"naturalSize");
            CGSize film = [mp respondsToSelector:ns] ? ((CGSize (*)(id, SEL))objc_msgSend)(mp, ns) : CGSizeZero;
            // only the widened film (wider than 3:2; its size is known once it has loaded): a 3:2 film
            // would lose its top and bottom. On any screen narrower than it, the iPad's too (FIXES.md 77)
            if (MIN(scr.width, scr.height) > 0 && MAX(scr.width, scr.height) / MIN(scr.width, scr.height) < film.width / MAX(film.height, 1) &&
                film.height > 0 && film.width / film.height > 1.6 &&
                [mp respondsToSelector:sm] && [mp respondsToSelector:setSm] && ((NSInteger (*)(id, SEL))objc_msgSend)(mp, sm) != 2) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(mp, setSm, 2);   // MPMovieScalingModeAspectFill
                LOG(@"film: shown aspect-fill (film %.0fx%.0f, screen %.0fx%.0f pt)", film.width, film.height, scr.width, scr.height);
            }
            NSInteger state = [mp respondsToSelector:NSSelectorFromString(@"playbackState")] ? ((NSInteger (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"playbackState")) : -1;
            NSInteger load = [mp respondsToSelector:NSSelectorFromString(@"loadState")] ? ((NSInteger (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"loadState")) : -1;
            double t = [mp respondsToSelector:NSSelectorFromString(@"currentPlaybackTime")] ? ((double (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"currentPlaybackTime")) : -1;
            NSURL *url = [mp respondsToSelector:NSSelectorFromString(@"contentURL")] ? [mp valueForKey:@"contentURL"] : nil;
            LOG(@"film: %@ | playback state %ld, load state %ld, at %.1f s | %@ | %@",
                [n stringByReplacingOccurrencesOfString:@"MPMoviePlayer" withString:@""], (long)state, (long)load, t, url.lastPathComponent, note.userInfo ?: @"");
        }];
    LOG(@"film log ON");
}

// The film stopped on its first frame: as it starts, the game's audio set-up switches the shared audio session off and
// on, and the film player pauses and never carries on. On the iOS of 2010 that switch-off was refused while audio
// played; the devs meant the film to keep going (the game calls ResumeMovie on every audio route change). The cause is
// removed in ibfix.m; as a backstop, until the film has come and gone (a minute if it never shows), a paused or
// interrupted film that hasn't reached its end is started again within 0.1 s. No fixed time limit: the film runs 66 s
// and may start late (FIXES.md 33). A film the game stops itself (Start pressed: HideSplashScreen) is left alone.
static void keepFilmPlaying(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), NSEC_PER_SEC / 10, NSEC_PER_SEC / 100);
    __block int ticks = 0, restarts = 0; __block BOOL seen = NO;
    dispatch_source_set_event_handler(t, ^{
        id del = [UIApplication sharedApplication].delegate;
        SEL ms = NSSelectorFromString(@"MoviePlayer");
        id mp = [del respondsToSelector:ms] ? ((id (*)(id, SEL))objc_msgSend)(del, ms) : nil;
        if (mp) seen = YES;
        if ((seen && !mp) || (!seen && ++ticks > 600)) { dispatch_source_cancel(t); return; }   // every 0.1 s while needed
        if (!mp || ![mp respondsToSelector:NSSelectorFromString(@"playbackState")]) return;
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
        NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"playbackState"));
        double now = ((double (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"currentPlaybackTime"));
        double length = ((double (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"duration"));
        if ((state == 2 || state == 3) && !(length > 0 && now >= length - 0.5)) {   // paused or interrupted, not at the end
            ((void (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"play"));
            if (restarts++ < 10) LOG(@"film: found %@ at %.1f of %.1f s, started again", state == 2 ? @"paused" : @"interrupted", now, length);
        }
    });
    dispatch_resume(t);
    static dispatch_source_t keep; keep = t;
#ifdef IBFIX_FILMTIMING
    // Diagnosis: the film's position every 50 ms for its first 4 s, logged in groups of ten, with how
    // late each sample ran (a busy main thread shows as lateness). P = not playing.
    dispatch_source_t ft = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(ft, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, 0);
    __block int n = 0; __block CFAbsoluteTime start = 0, last = 0; NSMutableString *line = [NSMutableString string];
    dispatch_source_set_event_handler(ft, ^{
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!start) start = now;
        id del = [UIApplication sharedApplication].delegate; SEL ms = NSSelectorFromString(@"MoviePlayer");
        id mp = [del respondsToSelector:ms] ? ((id (*)(id, SEL))objc_msgSend)(del, ms) : nil;
        double pos = mp ? ((double (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"currentPlaybackTime")) : -1;
        NSInteger st = mp ? ((NSInteger (*)(id, SEL))objc_msgSend)(mp, NSSelectorFromString(@"playbackState")) : -1;
        [line appendFormat:@" %.2f@%.2f%s%@", pos, now - start, st == 1 ? "" : "P",
            last && now - last > 0.08 ? [NSString stringWithFormat:@"(late %.0f ms)", (now - last - 0.05) * 1000] : @""];
        last = now;
        if (++n % 10 == 0) { LOG(@"film timing (film s @ clock s):%@", line); [line setString:@""]; }
        if (now - start > 4) dispatch_source_cancel(ft);
    });
    dispatch_resume(ft);
    static dispatch_source_t keepT; keepT = ft;
#endif
}

// ---- 4c. Music trace (diagnosis) ----------------------------------------------------------
// USeqAct_PlayMusicTrack::Activated (0x100583414, vtable slot at 0x100b12560) is what level
// scripting runs to change music: it fetches WorldInfo (0x100619258 with GEngine-ish global at
// 0x100cc3e08) and calls AWorldInfo::UpdateMusicTrack (0x100625f10) with its track (this+0x140;
// MP3Filename FString data +0x160, length +0x168). UpdateMusicTrack skips a request when a
// MusicComp exists (WorldInfo+0x638) with the same sound cue (+0x640), or when the current MP3
// name (+0x660, length +0x668) matches. Log each request with that state.

#define IB1_PLAYMUSIC_SLOT   0x100b12560ULL
#define IB1_PLAYMUSIC_FN     0x100583414ULL
#define IB1_GETWORLDINFO     0x100619258ULL
#define IB1_GWORLD_GLOBAL    0x100cc3e08ULL
// The level's WorldInfo (GWorld->GetWorldInfo()), NULL between levels
#define WORLD_INFO() ({ intptr_t sl_ = _dyld_get_image_vmaddr_slide(0); void *w_ = *(void **)(IB1_GWORLD_GLOBAL + sl_); \
                       w_ ? ((uint8_t *(*)(void *, int))(IB1_GETWORLDINFO + sl_))(w_, 0) : NULL; })
static void (*gOrigPlayMusic)(void *self);

static NSString *wstr(const uint8_t *base, size_t dataOff, size_t numOff) {
    const uint32_t *d = *(const uint32_t **)(base + dataOff); int n = *(const int *)(base + numOff);
    if (!d || n <= 0 || n > 200) return @"";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < n - 1 && d[i]; i++) [s appendFormat:@"%C", (unichar)d[i]];
    return s;
}

// ---- 4d. Timed music handovers (FIXES.md 34) ----
// In 25 places the devs start one track from another's ending: an intro's output link starts the boss's stage 1 loop
// (Boss3Intro -> Boss3A), each dragon intro starts its loop, and the God King's death music hands over to silence. The
// link fires when the first track stops, however it stops, so when the fight had already moved on, stage 1's music came
// back over a later stage's or the God King's death music. A handover is now skipped when another track has taken over
// from the one that started it. When the music has only gone silent (a fade-out), it goes ahead as before: a late
// "battle won" silence can land just after the next boss's intro starts, and that fight must still get its music.
// The list is the devs' own wiring, from every level (tools/musichandovers.py; each target has no other input). Its
// last field, the track each opener leads to, is also what a resumed save point plays instead of an opener (6, 4g).
static const struct { const char *level, *action, *from, *to; } kHandovers[] = {   // to: what it hands over to ("" silence)
    { "Battle_10ft2Sw_Deathless", "SeqAct_PlayMusicTrack_14", "dragon-A-intro", "dragon-A-loop" },   // "Stage1" [dragon-A-loop]
    { "Battle_10ft2Sw_Deathless", "SeqAct_PlayMusicTrack_2", "dragon-B-intro", "dragon-B-loop" },   // "Stage2" [dragon-B-loop]
    { "Battle_10ft2Sw_Deathless", "SeqAct_PlayMusicTrack_3", "dragon-C-intro", "dragon-C-loop" },   // "Stage3" [dragon-C-loop]
    { "Battle_10ft_04", "SeqAct_PlayMusicTrack_1", "Boss2Intro", "Boss2A" },   // "Stage1" [Boss2A]
    { "Battle_10ft_Deathless", "SeqAct_PlayMusicTrack_14", "dragon-A-intro", "dragon-A-loop" },   // "Stage1" [dragon-A-loop]
    { "Battle_10ft_Deathless", "SeqAct_PlayMusicTrack_2", "dragon-B-intro", "dragon-B-loop" },   // "Stage2" [dragon-B-loop]
    { "Battle_10ft_Deathless", "SeqAct_PlayMusicTrack_3", "dragon-C-intro", "dragon-C-loop" },   // "Stage3" [dragon-C-loop]
    { "Battle_10ft_Scene01", "SeqAct_PlayMusicTrack_9", "intro-story-A", "Boss2A" },   // [Boss2A]
    { "Battle_15ft_01", "SeqAct_PlayMusicTrack_1", "Boss3Intro", "Boss3A" },   // "Stage1" [Boss3A]
    { "Battle_15ft_02", "SeqAct_PlayMusicTrack_1", "Boss3Intro", "Boss3A" },   // "Stage1" [Boss3A]
    { "Battle_15ft_03", "SeqAct_PlayMusicTrack_1", "Boss3Intro", "Boss3A" },   // "Stage1" [Boss3A]
    { "Battle_15ft_Cell01", "SeqAct_PlayMusicTrack_1", "Boss3Intro", "Boss3A" },   // "Stage1" [Boss3A]
    { "Battle_15ft_Deathless", "SeqAct_PlayMusicTrack_14", "dragon-A-intro", "dragon-A-loop" },   // "Stage1" [dragon-A-loop]
    { "Battle_15ft_Deathless", "SeqAct_PlayMusicTrack_2", "dragon-B-intro", "dragon-B-loop" },   // "Stage2" [dragon-B-loop]
    { "Battle_15ft_Deathless", "SeqAct_PlayMusicTrack_3", "dragon-C-intro", "dragon-C-loop" },   // "Stage3" [dragon-C-loop]
    { "Battle_6ft_GodKing", "SeqAct_PlayMusicTrack_1", "Boss4Intro", "Boss4A" },   // "Stage1" [Boss4A]
    { "Battle_6ft_GodKing", "SeqAct_PlayMusicTrack_10", "Boss4Kill", "" },   // "None" [EMPTY]
    { "Battle_6ft_GodKing", "SeqAct_PlayMusicTrack_8", "Boss4Kill", "" },   // "None" [EMPTY]
    { "Battle_6ft_Zero", "SeqAct_PlayMusicTrack_2", "dragon-B-intro", "dragon-B-loop" },   // "Stage2" [dragon-B-loop]
    { "Battle_6ft_Zero", "SeqAct_PlayMusicTrack_3", "dragon-C-intro", "dragon-C-loop" },   // "Stage3" [dragon-C-loop]
    { "Birthright_P", "SeqAct_PlayMusicTrack_0", "Cinematic Intro", "Menu-Main" },   // [Menu-Main]
    { "Birthright_P", "SeqAct_PlayMusicTrack_1", "Boss2Intro", "Boss2A" },   // "Stage1" [Boss2A]
    { "Birthright_P", "SeqAct_PlayMusicTrack_10", "ending-accept", "" },   // "NONE" [EMPTY]
    { "Birthright_P", "SeqAct_PlayMusicTrack_6", "Boss1Open", "Boss1A" },   // [Boss1A]
    { "Birthright_P", "SeqAct_PlayMusicTrack_7", "boss6Intro", "boss6A" },   // [boss6A]
};
static const char *handoverFrom(const uint8_t *op) {
    const uint8_t *o = op;                                  // the level: the outermost of the action's outers
    for (int i = 0; o && *(const uint8_t **)(o + 0x40) && i < 16; i++) o = *(const uint8_t **)(o + 0x40);
    NSString *level = ibfix_objname(o), *name = ibfix_objname(op);
    for (size_t i = 0; i < sizeof kHandovers / sizeof kHandovers[0]; i++)
        if ([name isEqualToString:@(kHandovers[i].action)] && [level isEqualToString:@(kHandovers[i].level)]) return kHandovers[i].from;
    return NULL;
}

// An opener (a piece the devs hand over from when it ends: an intro, the God King's death music) and the track it
// leads to ("" = silence); nil for any other track.
static NSString *followOn(NSString *track) {
    for (size_t i = 0; track.length && i < sizeof kHandovers / sizeof kHandovers[0]; i++)
        if ([track caseInsensitiveCompare:@(kHandovers[i].from)] == NSOrderedSame) return @(kHandovers[i].to);
    return nil;
}
// The game's own record of the current track (WorldInfo +0x660): "" after a "fade out music", and kept while the
// game has the music paused (a tutorial's message). Game thread only.
static NSString *currentTrack(void) {
    uint8_t *wi = WORLD_INFO();
    return wi ? wstr(wi, 0x660, 0x668) : @"";
}

static void *gLastMusicAction; static int gLastMusicIdx = -1; static void *gLastMusicCls;   // for 4f, 4g
static void my_playMusicActivated(void *self) {
    if (self) { gLastMusicAction = self; gLastMusicIdx = *(int *)((uint8_t *)self + 0x38); gLastMusicCls = CLS(self); }
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void *(*getWI)(void *, int) = (void *(*)(void *, int))(IB1_GETWORLDINFO + slide);
    uint8_t *wi = (uint8_t *)getWI(*(void **)(IB1_GWORLD_GLOBAL + slide), 0);
    NSString *want = wstr((const uint8_t *)self, 0x160, 0x168);
    void *cue = *(void **)((uint8_t *)self + 0x140);
    if (wi) LOG(@"music request: '%@' cue %p | before: MusicComp %p cue %p current '%@'", want, cue,
                *(void **)(wi + 0x638), *(void **)(wi + 0x640), wstr(wi, 0x660, 0x668));
    const char *from = handoverFrom((const uint8_t *)self);
    if (from && wi) {
        NSString *now = wstr(wi, 0x660, 0x668);
        if (now.length && [now caseInsensitiveCompare:@(from)] != NSOrderedSame) {
            LOG(@"music: handover to '%@' skipped: it follows '%s', and '%@' has already taken over", want, from, now);
            return;
        }
    }
    gOrigPlayMusic(self);
    if (wi) LOG(@"music request done: MusicComp %p current '%@'", *(void **)(wi + 0x638), wstr(wi, 0x660, 0x668));
}

void ibfix_follow_other_audio(NSString *why);   // 5b
static void musicOffForTrip(void);              // 5b
static void hookMusicTrace(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **slot = (void **)(IB1_PLAYMUSIC_SLOT + slide);
    if (*slot != (void *)(IB1_PLAYMUSIC_FN + slide)) { LOG(@"music trace OFF: vtable not as expected"); return; }
    gOrigPlayMusic = (void (*)(void *))*slot; *slot = (void *)my_playMusicActivated;
    // Silent switch / route diagnosis: log what iOS reports.
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *n in @[AVAudioSessionRouteChangeNotification, AVAudioSessionSilenceSecondaryAudioHintNotification,
                          AVAudioSessionMediaServicesWereLostNotification, AVAudioSessionMediaServicesWereResetNotification])
        [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
            LOG(@"audio notice: %@ %@", note.name, note.userInfo);
            if ([note.name isEqualToString:AVAudioSessionSilenceSecondaryAudioHintNotification]) ibfix_follow_other_audio(@"iOS's notice");   // 5b
        }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { musicOffForTrip(); }];                                                 // 5b
    LOG(@"music trace ON");
}

// ---- 5b. Your own music, the moment it starts or stops (26 October 2026; FIXES.md 74) ----
// The devs switch between your music and theirs only when the game comes back to the front (IPhoneAppDelegate
// applicationDidBecomeActive:; the same steps are below), so music started or stopped with headphone buttons or Siri
// went unnoticed. Now they also run the moment iOS says other music started or stopped
// (AVAudioSessionSilenceSecondaryAudioHintNotification), and once a second from the sound watchdog (ibfix.m), before it
// switches anything on: music started elsewhere while the game's own plays interrupts the game's audio instead of
// sending the notice. Never in the background, nor during the start-up film (it counts as other audio, fix 1).
// Trips to the background (FIXES.md 76): the game's music is paused (the devs' PauseSong) as the game goes and resumed
// (ResumeSong) on return only if it should still play, so it never carries on for a moment over the player's music.
void ibfix_game_music_back(NSString *why);
void ibfix_with_music_refresh(void);   // 5c
void ibfix_follow_other_audio(NSString *why) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ ibfix_follow_other_audio(why); }); return; }
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState == UIApplicationStateBackground) return;   // in front, or with Control Centre over it
    id del = app.delegate;
    SEL bg = NSSelectorFromString(@"bUsingBackgroundMusic"), setBg = NSSelectorFromString(@"setBUsingBackgroundMusic:"), ms = NSSelectorFromString(@"MoviePlayer");
    if (![del respondsToSelector:bg] || ![del respondsToSelector:setBg]) return;
    BOOL film = (CFAbsoluteTimeGetCurrent() - gLaunchTime < 20) || ([del respondsToSelector:ms] && ((id (*)(id, SEL))objc_msgSend)(del, ms) != nil);
    if (film) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    BOOL other = session.secondaryAudioShouldBeSilencedHint, was = ((BOOL (*)(id, SEL))objc_msgSend)(del, bg);
    if (other == was) { ibfix_with_music_refresh(); return; }       // 5c: also catches the devs' own switches
    ((void (*)(id, SEL, BOOL))objc_msgSend)(del, setBg, other);
    if (other) {                                                       // your music: theirs stops, effects mix in
        AVAudioPlayer *p = [del valueForKey:@"MusicPlayer"];
        if ([p isKindOfClass:[AVAudioPlayer class]]) { [p stop]; ((void (*)(id, SEL, id))objc_msgSend)(del, NSSelectorFromString(@"setMusicPlayer:"), nil); }
        [session setCategory:AVAudioSessionCategoryAmbient error:nil];
        [session setActive:YES error:nil];                              // back on after an interruption, mixing
    } else {                                                           // theirs again, the track the game wanted
        [session setActive:YES error:nil];
        [session setCategory:AVAudioSessionCategorySoloAmbient error:nil];
    }
    LOG(@"your own music: %@ (%@)%@", other ? @"started elsewhere" : @"stopped", why, other ? @": the game's music off, its sound effects mixed in" : @"");
    ibfix_with_music_refresh();
    if (!other) ibfix_game_music_back(why);
}
static BOOL gMusicPausedForTrip;
static void musicOffForTrip(void) {
    id del = [UIApplication sharedApplication].delegate;
    SEL mp = NSSelectorFromString(@"MusicPlayer");
    AVAudioPlayer *p = [del respondsToSelector:mp] ? ((id (*)(id, SEL))objc_msgSend)(del, mp) : nil;
    if (![p isKindOfClass:[AVAudioPlayer class]] || !p.playing) return;
    ((void (*)(id, SEL))objc_msgSend)(del, NSSelectorFromString(@"PauseSong"));
    gMusicPausedForTrip = YES;
    LOG(@"your own music: the game's music paused for the trip to the background");
}
void ibfix_music_after_background(void) {
    if (!gMusicPausedForTrip) return;
    gMusicPausedForTrip = NO;
    id del = [UIApplication sharedApplication].delegate;
    SEL mp = NSSelectorFromString(@"MusicPlayer"), bg = NSSelectorFromString(@"bUsingBackgroundMusic");
    AVAudioPlayer *p = [del respondsToSelector:mp] ? ((id (*)(id, SEL))objc_msgSend)(del, mp) : nil;
    BOOL own = [del respondsToSelector:bg] && ((BOOL (*)(id, SEL))objc_msgSend)(del, bg);
    if (own || ![p isKindOfClass:[AVAudioPlayer class]] || p.playing) {
        LOG(@"your own music: back from the background: %@", own ? @"your music plays, the game's stays off" : @"the game's music already sorted");
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(del, NSSelectorFromString(@"ResumeSong"));
    LOG(@"your own music: back from the background: none playing, the game's music again");
}
// The game's music again after the player's: the track noted (NextSongToPlay), or, as the game notes none while the
// player's music plays, its own record of its current track (WorldInfo, as section 6 reads it); none at a spot the devs
// left without music. Only when the game has no music player of its own.
void ibfix_game_music_back(NSString *why) {
    id del = [UIApplication sharedApplication].delegate;
    if (![del respondsToSelector:NSSelectorFromString(@"MusicPlayer")]) return;
    id p = [del valueForKey:@"MusicPlayer"];
    if (p) return;
    NSString *next = ((id (*)(id, SEL))objc_msgSend)(del, NSSelectorFromString(@"NextSongToPlay")), *rec = currentTrack();
    NSString *want = [next isKindOfClass:[NSString class]] && next.length ? next : rec;
    if (!want.length || [want isEqualToString:@"None"]) { LOG(@"your own music: back to the game's (%@): no music at this spot", why); return; }
    ((void (*)(id, SEL, id))objc_msgSend)(del, NSSelectorFromString(@"PlaySong:"), want);
    LOG(@"your own music: back to the game's (%@): '%@' (%@)", why, want, want == next ? @"the track it noted" : @"its own record of the current track");
}

// ---- 5c. The game's sound under your own music (26 October 2026; FIXES.md 75) ----------------------------------
// While the player's music plays (the devs' bUsingBackgroundMusic, set by them on coming back to the front and by 5b),
// every game sound (effects and voices, the OpenAL gains in ibfix.m) is scaled by the Options slider "Game Sound
// (My Music)" (section 7; starts at half); otherwise by 1. The game's own music is untouched. Checked on every switch,
// each second (through 5b) and on every slider move; the engine sets each playing sound's gain every frame.
extern float ibfix_with_music_volume;
static float gWithMusicSlider = 0.5f;                          // the slider; 0.5 until the player moves it
static NSString *const kWithMusicKey = @"ibfixGameWithMyMusic";
void ibfix_with_music_refresh(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ ibfix_with_music_refresh(); }); return; }
    id del = [UIApplication sharedApplication].delegate;
    SEL bg = NSSelectorFromString(@"bUsingBackgroundMusic");
    BOOL own = [del respondsToSelector:bg] && ((BOOL (*)(id, SEL))objc_msgSend)(del, bg);
    float f = own ? gWithMusicSlider : 1;
    if (f == ibfix_with_music_volume) return;
    ibfix_with_music_volume = f;
    static int lastOwn = -1; static CFAbsoluteTime lastLog;             // every switch; slider drags twice a second at most
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (own == lastOwn && now - lastLog < 0.5) return;
    lastOwn = own; lastLog = now;
    LOG(@"game sound x%.2f: %@", f, own ? @"your own music plays (Game Sound (My Music))" : @"the game's own music");
}

// ---- 5. Music log ------------------------------------------------------------------------
// Diagnosis: every PlaySong/StopSong/PauseSong/ResumeSong with the player's state, read by tools/musicreplay.py.

static IMP oPlay, oStop, oPause, oResume;
static NSString *playerState(id del) {
    AVAudioPlayer *p = [del respondsToSelector:NSSelectorFromString(@"MusicPlayer")] ? [del valueForKey:@"MusicPlayer"] : nil;
    return p ? [NSString stringWithFormat:@"%@ playing=%d vol=%.2f t=%.0f/%.0f loops=%ld", p.url.lastPathComponent, p.playing, p.volume, p.currentTime, p.duration, (long)p.numberOfLoops] : @"no player";
}
// Two music fixes live here (FIXES 16, 17):
// - An empty track name is the level designers' "fade out music" (silence), but PlaySong:nil looked up the bundle's
//   first MP3 (pathForResource:nil). It now just lets the fade finish (or starts one) and plays nothing.
// - Track names are matched to the bundle's MP3s ignoring case: iOS file lookup is case-sensitive ("menu-normal").
static NSDictionary<NSString *, NSString *> *gSongNames;   // lower case -> the bundle's own spelling

// 5b. Stage tracks carried on in step (by choice, FIXES.md 42).
// The devs' player (PlaySong: 0x1008f8854, StopSong 0x1008f8b20, UpdatePlayerVolume 0x1008f8668, all on the main
// thread) fades the old track out over about a second, then starts the new one from its beginning, so every stage change
// replayed the piece's opening bars. Where both tracks of a change are in one group below (versions of one piece, in
// step: tools/instep.py), the old player is taken off the devs (setMusicPlayer:nil, kept here), their own PlaySong:
// makes the new one and fades it in as before, the new one is set to where the old one had got to (wrapping on its own
// length: Boss4C is two thirds as long), and the old one fades out over the same second. Other tracks start from their
// beginning as the devs made them.
static const char *kInStep[][3] = {
    { "Boss1A", "Boss1B", "Boss1C" }, { "Boss2A", "Boss2B", NULL }, { "Boss3A", "Boss3B", "Boss3C" },
    { "boss6A", "boss6B", "boss6C" }, { "Boss4A", "Boss4B", "Boss4C" },
};
static int inStepGroup(NSString *t) {
    for (int g = 0; t && g < (int)(sizeof kInStep / sizeof kInStep[0]); g++)
        for (int i = 0; i < 3; i++) if (kInStep[g][i] && [t isEqualToString:@(kInStep[g][i])]) return g;
    return -1;
}
static AVAudioPlayer *gOutgoing; static dispatch_source_t gOutgoingFade;   // the old track while it fades out
static const void *kAskedVolume;
static void stopOutgoing(void) {
    if (gOutgoingFade) { dispatch_source_cancel(gOutgoingFade); gOutgoingFade = nil; }
    [gOutgoing stop]; gOutgoing = nil;
}
static void fadeOutgoing(void) {
    NSNumber *asked = objc_getAssociatedObject(gOutgoing, kAskedVolume);
    float from = asked ? asked.floatValue : 1; CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), NSEC_PER_SEC / 20, NSEC_PER_SEC / 200);
    dispatch_source_set_event_handler(t, ^{
        float k = (float)(CFAbsoluteTimeGetCurrent() - t0);   // over a second, as the devs' fades
        if (k >= 1 || !gOutgoing) { stopOutgoing(); return; }
        gOutgoing.volume = from * (1 - k);                       // through m_setVolume: scaled by Music and Master
    });
    gOutgoingFade = t; dispatch_resume(t);
}
// YES if it handled the change
static BOOL playInStep(id del, SEL cmd, NSString *name) {
    AVAudioPlayer *old = [del valueForKey:@"MusicPlayer"];
    NSString *was = [old isKindOfClass:[AVAudioPlayer class]] ? old.url.lastPathComponent.stringByDeletingPathExtension : nil;
    int g = inStepGroup(name);
    if (!old.playing || g < 0 || inStepGroup(was) != g || [was isEqualToString:name]) return NO;
    stopOutgoing();
    gOutgoing = old; old.delegate = nil;
    ((void (*)(id, SEL, id))objc_msgSend)(del, NSSelectorFromString(@"setMusicPlayer:"), nil);   // the devs let it go
    ((void (*)(id, SEL, id))oPlay)(del, cmd, name);                // their new player: from the start, fading in
    AVAudioPlayer *now = [del valueForKey:@"MusicPlayer"];
    if (![now isKindOfClass:[AVAudioPlayer class]] || now.duration <= 0) { stopOutgoing(); return YES; }
    NSTimeInterval at = old.currentTime;
    now.currentTime = fmod(at, now.duration);
    fadeOutgoing();
    LOG(@"music: '%@' -> '%@' in step at %.2f s of %.2f (the old one fades out over 1 s as the new one fades in)", was, name, now.currentTime, now.duration);
    return YES;
}

static void m_play(id self, SEL _cmd, id song) {
    NSString *name = [song isKindOfClass:[NSString class]] ? song : nil;
    if (name.length == 0) {
        AVAudioPlayer *p = [self respondsToSelector:NSSelectorFromString(@"MusicPlayer")] ? [self valueForKey:@"MusicPlayer"] : nil;
        if ([p isKindOfClass:[AVAudioPlayer class]] && p.playing) ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"StopSong"));
        LOG(@"music: empty track = silence (designers' fade out) -> %@", playerState(self));
        return;
    }
    NSString *spelt = gSongNames[name.lowercaseString];
    if (spelt && ![spelt isEqualToString:name]) { LOG(@"music: '%@' is spelt '%@' in the game's files", name, spelt); name = spelt; }
    if (playInStep(self, _cmd, name)) { LOG(@"music: PlaySong %@ -> %@", name, playerState(self)); return; }
    ((void (*)(id, SEL, id))oPlay)(self, _cmd, name);
    LOG(@"music: PlaySong %@ -> %@", name, playerState(self));
}
static void m_stop(id self, SEL _cmd)   { ((void (*)(id, SEL))oStop)(self, _cmd);   LOG(@"music: StopSong -> %@", playerState(self)); }
static void m_pause(id self, SEL _cmd)  {
    stopOutgoing();                                              // a pause silences the fading one too
    ((void (*)(id, SEL))oPause)(self, _cmd);  LOG(@"music: PauseSong -> %@", playerState(self)); }
static void m_resume(id self, SEL _cmd) { ((void (*)(id, SEL))oResume)(self, _cmd); LOG(@"music: ResumeSong -> %@", playerState(self)); }

static void hookMusic(void) {
    Class c = NSClassFromString(@"IPhoneAppDelegate"); if (!c) return;
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    for (NSString *path in [[NSBundle mainBundle] pathsForResourcesOfType:@"mp3" inDirectory:nil]) {
        NSString *n = path.lastPathComponent.stringByDeletingPathExtension;
        names[n.lowercaseString] = n;
    }
    gSongNames = names;
    oPlay   = hookMethod(c, NSSelectorFromString(@"PlaySong:"), (IMP)m_play);
    oStop   = hookMethod(c, NSSelectorFromString(@"StopSong"), (IMP)m_stop);
    oPause  = hookMethod(c, NSSelectorFromString(@"PauseSong"), (IMP)m_pause);
    oResume = hookMethod(c, NSSelectorFromString(@"ResumeSong"), (IMP)m_resume);
}

// ---- 6. Music after resuming a save ---------------------------------------------------------
// USeqAct_StartChoiceMode::Activated is C++ (0x10092b388, vtable slot 0x100b8d600: vtable
// 0x100b8d2f0 + 0x310, the same slot as PlayMusicTrack's). USequenceOp.ForceActivateInput is
// script-callable native (native table entry 0x100bd1f10), which the resume path uses.
// Object names: UObject Name is an FName at +0x48 (index, number), Class +0x50, Outer +0x40;
// the name table (FName::Names, a TArray of FNameEntry*) is at 0x100c32520, and an entry's
// string starts at +0x10, bit 0 of its first byte marking a wide (4-byte) string.

#define IB1_GNAMES               0x100c32520ULL
#define IB1_CHOICEMODE_VTABLE    0x100b8d2f0ULL
#define IB1_CHOICEMODE_SLOT      0x100b8d600ULL
#define IB1_CHOICEMODE_ACTIVATED 0x10092b388ULL
#define IB1_NATIVE_FORCEACTIVATE 0x100bd1f10ULL
static NSString *const kMusicAtSavePoint = @"ibfixMusicAtSavePoint";   // NSUserDefaults: node -> track
static NSString *const kLastAmbient = @"ibfixLastAmbientSong";         // last walking-about track

NSString *ibfix_objname(const void *obj) {
    if (!obj) return @"none";
    struct { uint8_t **data; int num, max; } *names = (void *)(IB1_GNAMES + _dyld_get_image_vmaddr_slide(0));
    const uint8_t *o = obj;
    int idx = *(const int *)(o + 0x48), num = *(const int *)(o + 0x4c);
    if (idx < 0 || idx >= names->num || !names->data[idx]) return @"?";
    const uint8_t *e = names->data[idx];
    NSString *n;
    if (e[0] & 1) {
        NSMutableString *m = [NSMutableString string];
        for (const uint32_t *w = (const uint32_t *)(e + 0x10); *w && m.length < 120; w++) [m appendFormat:@"%C", (unichar)*w];
        n = m;
    } else n = [NSString stringWithUTF8String:(const char *)(e + 0x10)] ?: @"?";
    return num > 0 ? [n stringByAppendingFormat:@"_%d", num - 1] : n;
}

static void (*gOrigChoiceActivated)(void *);
static NativeFn gOrigForceActivate;
static void *volatile gResumingNode;
static BOOL playTrack(NSString *want, NSString *why);       // 4g
static id gAppDelegate;                                     // kept at start-up, for the game thread

static void my_execForceActivateInput(void *self, void *stack, void *result) {
    if (*(void **)self == (void *)(IB1_CHOICEMODE_VTABLE + _dyld_get_image_vmaddr_slide(0))) gResumingNode = self;
    gOrigForceActivate(self, stack, result);
}

// What a save point plays, read and played on the game thread (FIXES.md 39): savePointTick runs from the camera's update,
// every frame. The record is the game's own (currentTrack, 4d), so a paused track counts, and a track is played through
// the game (4g), so its hand-overs and the stage rule see it; an opener resumes as the track it leads to (4d's table:
// Boss1Open -> Boss1A).
static NSMutableArray<NSDictionary *> *gSaveChecks;         // game thread only
static void my_choiceModeActivated(void *self) {
    BOOL resumed = (self == gResumingNode);
    if (resumed) gResumingNode = NULL;
    NSString *node = ibfix_objname(self);
    gOrigChoiceActivated(self);
    if (!gSaveChecks) gSaveChecks = [NSMutableArray array];
    // 3 s: the moment the old check (the music player, 4 s on) saw, as the player lags the game's record by its 1 s fade.
    if (gSaveChecks.count < 8) [gSaveChecks addObject:@{ @"node": node, @"resumed": @(resumed), @"due": @(CFAbsoluteTimeGetCurrent() + 3) }];
}
static void savePointReached(NSString *node) {
    NSString *now = currentTrack();
    LOG(@"save point %@ reached: music %@", node, now.length ? now : @"none");
    // Silence is remembered too (""), since the designers leave some places quiet.
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [[ud dictionaryForKey:kMusicAtSavePoint] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[node] = now; [ud setObject:d forKey:kMusicAtSavePoint];
    if ([now hasPrefix:@"Explore"] || [now hasPrefix:@"Dungeon"] || [now hasPrefix:@"Darklord"]) [ud setObject:now forKey:kLastAmbient];
}
static void savePointResumed(NSString *node) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    // A save point reached before this fix existed: the last walking-about track heard,
    // or the castle's own ("Explore-Wind", what the castle plays after each fight).
    // ("" means the save point was quiet when reached: keep it quiet.)
    NSString *want = [ud dictionaryForKey:kMusicAtSavePoint][node] ?: [ud stringForKey:kLastAmbient] ?: @"Explore-Wind";
    NSString *now = currentTrack();
    id del = gAppDelegate;
    BOOL film = [del respondsToSelector:NSSelectorFromString(@"MoviePlayer")] && [del valueForKey:@"MoviePlayer"];
    if (now.length || film || [want isEqualToString:@""]) {
        LOG(@"save point %@ resumed: music %@, remembered %@ -> nothing to do", node, now.length ? now : (film ? @"(film)" : @"none"), want);
        return;
    }
    NSString *next = followOn(want);
    if (next) {
        LOG(@"save point %@: '%@' is an opener the devs hand over from when it ends: resuming with what it leads to, %@", node, want, next.length ? [NSString stringWithFormat:@"'%@'", next] : @"silence");
        if (!next.length) return;
        want = next;
    }
    LOG(@"save point %@ resumed with no music: playing %@ again", node, want);
    if (!playTrack(want, @"resumed save point"))
        dispatch_async(dispatch_get_main_queue(), ^{ ((void (*)(id, SEL, id))objc_msgSend)(del, NSSelectorFromString(@"PlaySong:"), want); });
}
static void savePointTick(void) {
    if (!gSaveChecks.count) return;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    for (NSDictionary *c in [gSaveChecks copy]) {
        if (t < [c[@"due"] doubleValue]) continue;
        [gSaveChecks removeObject:c];
        if ([c[@"resumed"] boolValue]) savePointResumed(c[@"node"]); else savePointReached(c[@"node"]);
    }
}

static void hookResumeMusic(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **slot = (void **)(IB1_CHOICEMODE_SLOT + slide);
    void **entry = (void **)(IB1_NATIVE_FORCEACTIVATE + slide);
    if (*slot != (void *)(IB1_CHOICEMODE_ACTIVATED + slide) || !entry[-1] ||
        strcmp((const char *)entry[-1], "USequenceOpexecForceActivateInput") != 0) { LOG(@"resume music fix OFF: code not as expected"); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ gAppDelegate = [UIApplication sharedApplication].delegate; });
    gOrigChoiceActivated = (void (*)(void *))*slot; *slot = (void *)my_choiceModeActivated;
    gOrigForceActivate = (NativeFn)entry[0]; entry[0] = (void *)my_execForceActivateInput;
    LOG(@"resume music fix ON");
}

// ---- 7. Music and Master volume sliders --------------------------------------------------
// Engine pieces: UObject::FindFunction(obj, FName, global) 0x1000eaf88 (NULL if missing);
// UObject::ProcessEvent is vtable slot 0x208 (obj, function, parms, unused). Script calls of a
// virtual function go through GNatives[0x1B] (execVirtualFunction), whose operand is the FName.
// UFunction::Func (a member-function pointer: address, adjustment) is found at run time by
// looking for UCanvas.DrawTile's native (our wrapper) inside its UFunction. The handlers are also flagged native (below).

#define IB1_FINDFUNCTION   0x1000eaf88ULL
#define VT_PROCESSEVENT    0x208
#define EX_VIRTUALFUNCTION 0x1B
extern float ibfix_master_volume;                     // ibfix.m: scales OpenAL gains
static float gMusicVolume = 1;
static float gMusicDip = 1;                           // the music under speech (4j): 1, or down to 12 dB lower
static float gVoiceVolume = 1;                        // the Voice Volume slider: spoken lines only (4j)
static NSString *const kVoiceVolumeKey = @"ibfixVoiceVolume";
static NSString *const kMasterVolumeKey = @"ibfixMasterVolume", *const kMusicVolumeKey = @"ibfixMusicVolume";
static size_t gFuncOff;                               // UFunction::Func
static int propertyOffset(void *structp, const char *name);
static MemberFn gOrigVirtualFunction;
static int gNameInitMenuObject = -1;
static void *gOptionsListClass;

static int nameIndex(const char *want) {                // cached: slider drags look names up often
    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    NSString *key = @(want);
    @synchronized ([NSNumber class]) {
        if (!cache) cache = [NSMutableDictionary dictionary];
        NSNumber *hit = cache[key]; if (hit) return hit.intValue;
    }
    struct { uint8_t **data; int num, max; } *names = (void *)(IB1_GNAMES + _dyld_get_image_vmaddr_slide(0));
    int found = -1;
    for (int i = 0; i < names->num && found < 0; i++) {
        const uint8_t *e = names->data[i];
        if (e && !(e[0] & 1) && strcmp((const char *)(e + 0x10), want) == 0) found = i;
    }
    if (found >= 0) @synchronized ([NSNumber class]) { cache[key] = @(found); }
    return found;
}
#define NAME_ONCE(var, text) static int var = -2; if (var == -2) var = nameIndex(text)   // looked up on first use
static void *findFunction(void *obj, const char *name) {
    int i = nameIndex(name);
    if (!obj || i < 0) return NULL;
    return ((void *(*)(void *, uint64_t, int))(IB1_FINDFUNCTION + _dyld_get_image_vmaddr_slide(0)))(obj, (uint32_t)i, 0);
}
static void processEvent(void *obj, void *fn, void *parms) {
    void **vt = *(void ***)obj;
    ((void (*)(void *, void *, void *, void *))vt[VT_PROCESSEVENT / sizeof(void *)])(obj, fn, parms, NULL);
}

// The music player's volume as the game asked for it (its fades), scaled by Music and Master, and lowered while
// someone speaks (4j).
static IMP oSetVolume;
static const void *kAskedVolume = &kAskedVolume;
static void m_setVolume(AVAudioPlayer *self, SEL _cmd, float v) {
    objc_setAssociatedObject(self, kAskedVolume, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, float))oSetVolume)(self, _cmd, v * gMusicVolume * ibfix_master_volume * gMusicDip);
}
static void applyMusicVolume(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id del = [UIApplication sharedApplication].delegate;
        AVAudioPlayer *p = [del respondsToSelector:NSSelectorFromString(@"MusicPlayer")] ? [del valueForKey:@"MusicPlayer"] : nil;
        if (![p isKindOfClass:[AVAudioPlayer class]]) return;
        NSNumber *asked = objc_getAssociatedObject(p, kAskedVolume);
        p.volume = asked ? asked.floatValue : 1.0f;     // through m_setVolume, so scaled
    });
}

// The handlers: on bInit show the stored value, otherwise take the slider's value.
// The script interpreter calls a script function's code directly (UObject::ProcessInternal), so
// the two handler UFunctions are marked native (FUNC_Native 0x400 in FunctionFlags +0xd8, Func
// +0xf0): the interpreter then calls Func with the *caller's* frame, and the native reads its two
// arguments from the caller's code (Item, bInit) and steps past EX_EndFunctionParms, like the
// game's own natives. If one were ever called through ProcessEvent instead, the frame's Node is
// the handler itself and the arguments are already in its Locals.
#define FUNC_NATIVE 0x400
// A handler's two arguments (Item, bInit), from its caller's code or, through ProcessEvent, its own Locals.
static void *handlerArgs(void *stack, void *fn, BOOL *bInit) {
    void *item = NULL; uint32_t init[4] = {0};
    if (*(void **)((uint8_t *)stack + 0x18) == fn) {
        uint8_t *locals = *(uint8_t **)((uint8_t *)stack + 0x30);
        item = *(void **)locals; init[0] = *(uint32_t *)(locals + 8);
    } else {
        stepExpr(stack, &item);
        stepExpr(stack, init);
        (*(uint8_t **)((uint8_t *)stack + FFRAME_CODE))++;          // P_FINISH
    }
    *bInit = (init[0] & 1) != 0;
    return item;
}
// what: the log's name for it ("volume sliders: Master"); apply: run after a change (NULL: none).
static void sliderHandler(void *stack, void *fn, float *volume, NSString *key, const char *what, void (*apply)(void)) {
    BOOL bInit;
    void *item = handlerArgs(stack, fn, &bInit);
    if (!item) return;
    // SetValue(float NewValue) and GetValue() -> float: one float at offset 0 either way.
    uint8_t *f = findFunction(item, bInit ? "SetValue" : "GetValue");
    if (!f || *(uint16_t *)(f + 0xe2) != 4 || propertyOffset(f, bInit ? "NewValue" : "ReturnValue") != 0) { LOG(@"%s: slider functions not as expected", what); return; }
    float parm[2] = { bInit ? *volume : 0, 0 };
    processEvent(item, f, parm);
    if (bInit) { LOG(@"%s shows %.2f", what, *volume); return; }
    *volume = fminf(fmaxf(parm[0], 0), 1);
    [[NSUserDefaults standardUserDefaults] setFloat:*volume forKey:key];
    static CFAbsoluteTime lastLog; CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastLog > 0.5) { lastLog = now; LOG(@"%s set to %.2f", what, *volume); }
    if (apply) apply();
}
static void *gMasterFn, *gMusicFn, *gVoiceFn, *gBlockFn;
static void my_onMasterVolume(void *self, void *stack, void *result) { sliderHandler(stack, gMasterFn, &ibfix_master_volume, kMasterVolumeKey, "volume sliders: Master", applyMusicVolume); }
static void my_onMusicVolume(void *self, void *stack, void *result)  { sliderHandler(stack, gMusicFn, &gMusicVolume, kMusicVolumeKey, "volume sliders: Music", applyMusicVolume); }
// Spoken lines only (4j applies it as they play): the game's OnUpdateMemLeakCheck, a debug option never added to any list.
static void my_onVoiceVolume(void *self, void *stack, void *result)  { sliderHandler(stack, gVoiceFn, &gVoiceVolume, kVoiceVolumeKey, "volume sliders: Voice", NULL); }
// The game's sound while the player's own music plays (5c): the game's OnUpdateTestListBox, the devs' test of a left/right
// picker ("This", "Is", "Just", "A", "Test", "Longer Word Test"), never added to any list.
static void *gWithMusicFn;
static void my_onWithMusic(void *self, void *stack, void *result)    { sliderHandler(stack, gWithMusicFn, &gWithMusicSlider, kWithMusicKey, "volume sliders: Game Sound (My Music)", ibfix_with_music_refresh); }
// The block button's size (section 7b applies it): the slider's value, 0 = the devs' size.
static float gBlockSlider = 0;
static NSString *const kBlockSizeKey = @"ibfixBlockSize";
static void my_onBlockSize(void *self, void *stack, void *result)    { sliderHandler(stack, gBlockFn, &gBlockSlider, kBlockSizeKey, "block size: slider", NULL); }

static BOOL pointHandler(void *list, const char *name, void *fn, void **saveFn) {
    uint8_t *f = findFunction(list, name);
    if (!f || !gFuncOff || *(uint16_t *)(f + 0xdc) != 0) return NO;   // iNative must be 0 (Func is used)
    void **func = (void **)(f + gFuncOff);
    if (func[0] != fn) { func[0] = fn; func[1] = NULL; }
    *(uint32_t *)(f + 0xd8) |= FUNC_NATIVE;
    *saveFn = f;
    return YES;
}

// UObject/UField/UStruct/UProperty layout:
// UField::Next +0x60, UStruct::SuperField +0x68, UStruct::Children +0x70, UProperty::Offset +0x7c;
// UFunction: NumParms (byte) +0xe1, ParmsSize (word) +0xe2, Func +0xf0.
static int propertyOffset(void *structp, const char *name) {
    for (uint8_t *st = structp; st; st = *(uint8_t **)(st + 0x68))
        for (uint8_t *f = *(uint8_t **)(st + 0x70); f; f = *(uint8_t **)(f + 0x60))
            if ([ibfix_objname(f) isEqualToString:@(name)] && [ibfix_objname(CLS(f)) hasSuffix:@"Property"])
                return *(int *)(f + 0x7c);
    return -1;
}

// An FString holding plain text, UTF-32 with the terminator counted. Its buffer comes from the
// engine's own allocator (appRealloc, 0x1000639b0: ptr, size, alignment), since script code may
// resize or free a string argument; it is never freed here (a few bytes per options screen).
#define IB1_APPREALLOC 0x1000639b0ULL
typedef struct { uint32_t *data; int32_t num, max; } FStr;
static FStr makeFString(const char *text) {
    size_t n = strlen(text);
    void *(*appRealloc)(void *, uint32_t, uint32_t) = (void *(*)(void *, uint32_t, uint32_t))(IB1_APPREALLOC + _dyld_get_image_vmaddr_slide(0));
    FStr f = { appRealloc(NULL, (uint32_t)((n + 1) * sizeof(uint32_t)), 8), (int32_t)n + 1, (int32_t)n + 1 };
    for (size_t c = 0; f.data && c <= n; c++) f.data[c] = c < n ? (uint8_t)text[c] : 0;
    if (!f.data) f.num = f.max = 0;
    return f;
}

// Calls obj.SetText(text) on a SwordDrawText (SetText(string NewText) -> bool; no optional parts).
static void setText(void *drawText, const char *text) {
    uint8_t *fn = findFunction(drawText, "SetText");
    int off = fn ? propertyOffset(fn, "NewText") : -1;
    uint16_t parmsSize = fn ? *(uint16_t *)(fn + 0xe2) : 0;
    if (off < 0 || parmsSize < off + sizeof(FStr) || parmsSize > 64) { LOG(@"volume sliders: SetText not as expected"); return; }
    uint8_t parms[64] = {0};
    FStr str = makeFString(text);
    memcpy(parms + off, &str, sizeof str);
    processEvent(drawText, fn, parms);
}

// Both handler functions must take (Item @0, bInit @8) like OnUpdateSfxVolume before being replaced.
static BOOL handlerShapeOK(void *list, const char *name) {
    uint8_t *fn = findFunction(list, name);
    return fn && propertyOffset(fn, "Item") == 0 && propertyOffset(fn, "bInit") == 8 && fn[0xe1] == 2;
}

static void addVolumeSliders(uint8_t *list) {
    uint8_t *addOption = findFunction(list, "AddOption");
    // AddOption(class ItemClass @0, delegate OnUpdate @8, optional string Caption @24) -> item @40.
    BOOL shapeOK = addOption && *(uint16_t *)(addOption + 0xe2) == 0x30 && propertyOffset(addOption, "ItemClass") == 0 &&
                   propertyOffset(addOption, "OnUpdate") == 8 && propertyOffset(addOption, "Caption") == 24 &&
                   propertyOffset(addOption, "ReturnValue") == 40;
    if (!shapeOK || !handlerShapeOK(list, "OnUpdateGuiVolume") || !handlerShapeOK(list, "OnUpdateMusicVolume") || !handlerShapeOK(list, "OnUpdateToggleFps") ||
        !handlerShapeOK(list, "OnUpdateMemLeakCheck")) {
        LOG(@"volume sliders OFF: options list functions not as expected"); return;
    }
    // Find the list's items array (all SwordOptionList* objects) and the SFX slider in it.
    struct Arr { void **data; int num, max; } *items = NULL; int sfx = -1; void *sliderClass = NULL;
    int itemsOff = propertyOffset(CLS(list), "Items");
    if (itemsOff > 0) {
        struct Arr *a = (struct Arr *)(list + itemsOff);
        for (int i = 0; a->data && i < a->num; i++)
            if ([ibfix_objname(CLS(a->data[i])) isEqualToString:@"SwordOptionListSlider"]) { sfx = i; break; }
        if (sfx >= 0) { items = a; sliderClass = CLS(a->data[sfx]); }
    }
    if (!items) { LOG(@"volume sliders OFF: no SFX slider in the options list (Items at %#x)", itemsOff); return; }
    int sliders = 0;
    for (int i = 0; i < items->num; i++)
        if ([ibfix_objname(CLS(items->data[i])) isEqualToString:@"SwordOptionListSlider"]) sliders++;
    if (sliders > 2) return;                             // already added to this list (SFX and dodge size are the game's two)
    // The block size uses the game's OnUpdateToggleFps: a debug option ("stat fps") never added to any list.
    if (!pointHandler(list, "OnUpdateGuiVolume", (void *)my_onMasterVolume, &gMasterFn) ||
        !pointHandler(list, "OnUpdateMusicVolume", (void *)my_onMusicVolume, &gMusicFn) ||
        !pointHandler(list, "OnUpdateToggleFps", (void *)my_onBlockSize, &gBlockFn) ||
        !pointHandler(list, "OnUpdateMemLeakCheck", (void *)my_onVoiceVolume, &gVoiceFn)) {
        LOG(@"volume sliders OFF: handlers not replaced"); return;
    }
    // Game Sound (My Music) (5c) only if its handler is as expected; the others don't depend on it.
    BOOL withMusic = handlerShapeOK(list, "OnUpdateTestListBox") && pointHandler(list, "OnUpdateTestListBox", (void *)my_onWithMusic, &gWithMusicFn);
    if (!withMusic) LOG(@"volume sliders: Game Sound (My Music) OFF: OnUpdateTestListBox not as expected");
    // All but the last go just above the SFX slider, in this order; the last (Block Button Size) below Dodge Button Size.
    const char *labels[5] = { "Master Volume", "Music Volume", "Game Sound (My Music)", "Voice Volume", "Block Button Size" };
    const char *handlers[5] = { "OnUpdateGuiVolume", "OnUpdateMusicVolume", "OnUpdateTestListBox", "OnUpdateMemLeakCheck", "OnUpdateToggleFps" };
    void *added[5] = { NULL }; int count = 0; BOOL allAdded = YES;
    for (int k = 0; k < 5; k++) {
        if (k == 2 && !withMusic) continue;
        // The label is left empty here: AddOption's first step sets Caption to its default ("")
        // with the engine's allocator, which aborts on a buffer it didn't allocate. It's set below.
        struct { void *cls; void *delObj; int32_t delName, delNum; FStr caption; void *ret; } parms =
            { sliderClass, list, nameIndex(handlers[k]), 0, { NULL, 0, 0 }, NULL };
        processEvent(list, addOption, &parms);
        void *item = added[count++] = parms.ret;
        if (!item) allAdded = NO;
        int capOff = item ? propertyOffset(CLS(item), "Caption") : -1;
        void *caption = capOff > 0 ? *(void **)((uint8_t *)item + capOff) : NULL;
        if (caption) setText(caption, labels[k]); else LOG(@"volume sliders: no caption on the new slider");
    }
    // AddOption appended them: all but the last go just above the SFX slider, the last just below the game's Dodge
    // Button Size (found by its handler, OnUpdateDodgeSize, in the item's OnUpdate delegate: object +0, function name
    // +8; failing that, the slider straight after SFX, where the game adds it).
    int n = items->num; void **d = items->data;
    BOOL atEnd = allAdded && n >= count;
    for (int k = 0; atEnd && k < count; k++) if (d[n - count + k] != added[k]) atEnd = NO;
    if (atEnd) {
        int above = count - 1;
        n -= count;                                                               // take them off the end
        memmove(&d[sfx + above], &d[sfx], (size_t)(n - sfx) * sizeof(void *));
        for (int k = 0; k < above; k++) d[sfx + k] = added[k];
        n += above;                                                               // ..., then SFX (now at sfx + above)
        int dodge = -1, want = nameIndex("OnUpdateDodgeSize");
        for (int i = 0; i < n && dodge < 0; i++) {
            int o = propertyOffset(CLS(d[i]), "OnUpdate");
            if (o > 0 && want >= 0 && *(int *)((uint8_t *)d[i] + o + 8) == want) dodge = i;
        }
        if (dodge < 0) dodge = sfx + above + 1 < n ? sfx + above + 1 : n - 1;    // after SFX
        memmove(&d[dodge + 2], &d[dodge + 1], (size_t)(n - dodge - 1) * sizeof(void *));
        d[dodge + 1] = added[count - 1]; n += 1;
        items->num = n;
        LOG(@"volume sliders: added Master, Music%s and Voice above SFX, Block Button Size below Dodge Button Size (%d options)",
            withMusic ? ", Game Sound (My Music)" : "", items->num);
    } else LOG(@"volume sliders: added, but couldn't reorder (%d rows)", count);
}

// ---- 8. No dead App Store ------------------------------------------------------------------
// SwordPC.CanBuyGoldFromStore (and SwordBasePC's, which it calls through super) become natives that
// answer false. Patched the first time a SwordPC object makes a script call (see below).
static void *gNoStoreFns[2];
static void my_noStore(void *self, void *stack, void *result) {
    void *node = *(void **)((uint8_t *)stack + 0x18);
    if (node != gNoStoreFns[0] && node != gNoStoreFns[1]) (*(uint8_t **)((uint8_t *)stack + FFRAME_CODE))++;   // P_FINISH
    if (result) *(uint32_t *)result = 0;
}
static BOOL gNoStoreTried;
static void patchNoStore(void *pc) {
    if (gNoStoreTried) return;
    gNoStoreTried = YES;
    uint8_t *f = findFunction(pc, "CanBuyGoldFromStore");
    for (int i = 0; f && i < 2; i++, f = *(uint8_t **)(f + 0x68)) {          // SwordPC's, then its super (SwordBasePC's)
        if (!gFuncOff || f[0xe1] != 1 || *(uint16_t *)(f + 0xdc) != 0) break;  // one parameter: the return value
        void **func = (void **)(f + gFuncOff);
        func[0] = (void *)my_noStore; func[1] = NULL;
        *(uint32_t *)(f + 0xd8) |= FUNC_NATIVE;
        gNoStoreFns[i] = f;
    }
    LOG(@"App Store purchases %@", gNoStoreFns[0] ? @"switched off (no dead 'Connecting to iTunes')" : @"OFF: function not as expected");
}

// ---- 9b. Cutscene moves the engine refuses ---------------------------------------------------
// Every scene where the knight walks somewhere is a Matinee film with a "Player" group (InterpGroupAI) whose move track
// places him. Opened on the title, the game starts the "TITLE SCREEN LOOP" film (SeqAct_Interp_47, one key: his title
// spot) with the intro, and the loop overruled the intro's walk-on every frame (FIXES.md 25). So when two playing films
// want the same actor, a film that only holds him (one key) gives way to one that moves him: more than 24 units from
// where the winning film says, he is placed there (Location, then ForceUpdateComponents); more than 3 degrees from its
// keyframed rotation, he is turned to it (Rotation; FIXES.md 86). A lone film is left to the engine: our reading of a
// track could differ from the engine's (keys relative to an actor's Base, the tracks' disable switches).
// Safety and cost (FIXES.md 28): levels unload and their memory can go back to the system, so a kept film is never read
// to see whether it still exists: its GObjObjects slot must still hold it, with the same class (refLive). The films are
// found by a pass over GObjObjects spread over about 2 s of frames (in one go on the first call and after the camera
// has been still for over a second), and offsets and class tests are remembered per class (poff, isClass).

// Answers that depend only on a class (or a function) and a name: kind 0 = the property's offset
// (propertyOffset), kind 1 = whether the class has exactly that name. Classes and functions live in
// script packages that are never unloaded, so an answer stays true for the session. Game thread only.
typedef struct { void *cls; int kind, val; uint32_t hash; char name[32]; } ClassMemo;
enum { kMemoSize = 512 };                                                   // about 100 in use (diagnostic builds)
static ClassMemo gMemo[kMemoSize];
static int classMemo(void *cls, const char *name, int kind) {
    if (!cls) return kind ? 0 : -1;                                         // (an empty slot has no class)
    uint32_t h = 2166136261u;                                               // FNV-1a of the name, mixed with the class
    for (const char *c = name; *c; c++) h = (h ^ (uint8_t)*c) * 16777619u;
    h ^= (uint32_t)((uintptr_t)cls >> 4) * 2654435761u + (uint32_t)kind;
    BOOL keep = strlen(name) < sizeof gMemo[0].name;
    for (int n = 0, i = h & (kMemoSize - 1); keep && n < kMemoSize; n++, i = (i + 1) & (kMemoSize - 1)) {
        ClassMemo *m = &gMemo[i];
        if (m->cls == cls && m->kind == kind && m->hash == h && strcmp(m->name, name) == 0) return m->val;
        if (m->cls) continue;
        m->val = kind ? [ibfix_objname(cls) isEqualToString:@(name)] : propertyOffset(cls, name);
        m->kind = kind; m->hash = h; strcpy(m->name, name); m->cls = cls;
        return m->val;
    }
    return kind ? [ibfix_objname(cls) isEqualToString:@(name)] : propertyOffset(cls, name);   // table full (not expected)
}
static int poff(void *cls, const char *name) { return classMemo(cls, name, 0); }

#define IB1_GOBJOBJECTS 0x100cb29a8ULL
typedef struct { void **data; int num, max; } ObjArray;
// An object as found in GObjObjects: its slot and class are kept with it, so whether it still exists
// can be checked without reading memory that may have been given back (levels unload).
typedef struct { uint8_t *obj; int idx; void *cls; } ObjRef;
static BOOL refLive(const ObjRef *r) {
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    return r->obj && r->idx >= 0 && r->idx < objs->num && objs->data[r->idx] == r->obj   // its slot still holds it (no read of the object yet)
        && CLS(r->obj) == r->cls;                                          // and the same kind of object (an address reused)
}
static BOOL isClass(void *o, const char *name) { return o && classMemo(CLS(o), name, 1); }

// FInterpCurvePoint<FVector>: InVal, OutVal, ArriveTangent, LeaveTangent, InterpMode (44 bytes)
typedef struct { float in, out[3], arrive[3], leave[3]; uint8_t mode, pad[3]; } CurvePoint;
static BOOL evalCurve(void *track, const char *curve, float t, float pos[3]);
static BOOL evalMoveTrack(void *track, float t, float pos[3]) {
    int oFrame = poff(CLS(track), "MoveFrame");
    if (oFrame >= 0 && ((uint8_t *)track)[oFrame] != 0) return NO;                    // world frame only
    return evalCurve(track, "PosTrack", t, pos);
}
// Which way a move track turns him (FIXES.md 86): its EulerTrack (degrees: roll, pitch, yaw), when its rotations are
// keyframed (RotMode 0; 1 looks at another group, 2 leaves him as he is), as the engine's Rotation (65536 a turn).
static BOOL evalTurnTrack(void *track, float t, int rot[3]) {
    void *c = CLS(track);
    int oFrame = poff(c, "MoveFrame"), oMode = poff(c, "RotMode"); float e[3];
    if ((oFrame >= 0 && ((uint8_t *)track)[oFrame] != 0) || oMode < 0 || ((uint8_t *)track)[oMode] != 0) return NO;
    if (!evalCurve(track, "EulerTrack", t, e)) return NO;
    rot[0] = (int)lroundf(e[1] * 65536.0f / 360.0f); rot[1] = (int)lroundf(e[2] * 65536.0f / 360.0f); rot[2] = (int)lroundf(e[0] * 65536.0f / 360.0f);
    return YES;
}
static BOOL evalCurve(void *track, const char *curve, float t, float pos[3]) {
    int oPos = poff(CLS(track), curve);
    if (oPos < 0) return NO;
    struct { CurvePoint *p; int num, max; } *pts = (void *)((uint8_t *)track + oPos);
    int n = pts->num; CurvePoint *p = pts->p;
    if (n <= 0 || n > 64 || !p) return NO;
    for (int k = 0; k < n; k++) if (p[k].mode > 5 || (k && p[k].in < p[k - 1].in)) return NO;   // not as expected
    int k = 0;
    if (t <= p[0].in) { memcpy(pos, p[0].out, 12); return YES; }
    if (t >= p[n - 1].in) { memcpy(pos, p[n - 1].out, 12); return YES; }
    while (k + 1 < n && p[k + 1].in <= t) k++;
    float dt = p[k + 1].in - p[k].in, a = dt > 0 ? (t - p[k].in) / dt : 0;
    for (int c = 0; c < 3; c++) {
        float p0 = p[k].out[c], p1 = p[k + 1].out[c];
        if (p[k].mode == 2) pos[c] = p0;                                      // CIM_Constant
        else if (p[k].mode == 0) pos[c] = p0 + (p1 - p0) * a;                 // CIM_Linear
        else {                                                                // curves: cubic Hermite
            float t0 = p[k].leave[c] * dt, t1 = p[k + 1].arrive[c] * dt, a2 = a * a, a3 = a2 * a;
            pos[c] = (2 * a3 - 3 * a2 + 1) * p0 + (a3 - 2 * a2 + a) * t0 + (-2 * a3 + 3 * a2) * p1 + (a3 - a2) * t1;
        }
    }
    return YES;
}

// The skip (fast-forward) button's zone, SkipMatineeZone (every build: 4l; test builds also log it)
static uint8_t *skipZone(void) {
    static ObjRef z; static int name = -2;
    if (name == -2) name = nameIndex("SkipMatineeZone");
    if (z.obj && !refLive(&z)) z.obj = NULL;                  // gone with its level: checked by slot, not read
    static CFAbsoluteTime lastScan; CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
    if (!z.obj && name >= 0 && tn - lastScan > 2) {
        lastScan = tn;
        ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
        for (int i = 0; i < objs->num; i++) { uint8_t *o = objs->data[i]; if (o && *(int *)(o + 0x48) == name && *(int *)(o + 0x4c) == 0) { z = (ObjRef){ o, i, CLS(o) }; break; } }
    }
    return z.obj;
}
// YES while a finger is on the fast-forward button (the zone's State: 1 activating, 2 active; 0 when
// let go), or when the zone can't be read (then nothing is held back)
static BOOL skipHeld(void) {
    uint8_t *z = skipZone(); if (!z) return YES;
    int oS = poff(CLS(z), "State"); if (oS < 0) return YES;
    return z[oS] == 1 || z[oS] == 2;
}
#ifdef IBFIX_SNAPS
// Diagnostic: the skip button's zone: its own rectangle, active size and state
static NSString *skipZoneRect(void) {
    uint8_t *z = skipZone(); if (!z) return @"zone not found";
    void *c = CLS(z);
    int oX = poff(c, "X"), oY = poff(c, "Y"), oW = poff(c, "SizeX"), oH = poff(c, "SizeY"), oAW = poff(c, "ActiveSizeX"), oAH = poff(c, "ActiveSizeY"), oS = poff(c, "State");
    return [NSString stringWithFormat:@"zone %@ (%@) X %.1f Y %.1f size %.1fx%.1f active size %.1fx%.1f state %d", ibfix_objname(z), ibfix_objname(c),
            *(float *)(z + oX), *(float *)(z + oY), *(float *)(z + oW), *(float *)(z + oH), oAW >= 0 ? *(float *)(z + oAW) : -1, oAH >= 0 ? *(float *)(z + oAH) : -1, oS >= 0 ? z[oS] : -1];
}
void ibfix_skip_zone_log(NSString *drawn) { LOG(@"skip button: %@ | %@", drawn, skipZoneRect()); }
static void skipZoneStateWatch(void) {
    static CFAbsoluteTime lastT; CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
    if (tn - lastT < 0.01) return;
    lastT = tn;
    static int last = -1; uint8_t *z = skipZone(); if (!z) return;
    int oS = poff(CLS(z), "State"); if (oS < 0) return;
    if (z[oS] != last) { last = z[oS]; LOG(@"skip button state -> %d | %@", last, skipZoneRect()); }
}
#endif

// The level's films (exactly SeqAct_Interp, named SeqAct_Interp_N), sorted by slot, each with its
// Position the last time it was looked at and the world's game time then (seenAt < 0: not yet).
typedef struct { ObjRef ref; float pos; double seenAt; } Film;
static Film *gFilms; static int gNumFilms, gMaxFilms;
// In a loop over gFilms: film f's object, class, GroupInst array, play rate and position; a film gone or without them
// is skipped (continue)
#define FILM_STATE(f) if (!refLive(&gFilms[f].ref)) continue; \
    uint8_t *film = gFilms[f].ref.obj; void *cls = gFilms[f].ref.cls; \
    int oGI = poff(cls, "GroupInst"), oRate = poff(cls, "PlayRate"), oPos = poff(cls, "Position"); \
    if (oGI < 0 || oRate < 0 || oPos < 0) continue; \
    struct { uint8_t **data; int num, max; } *gi = (void *)(film + oGI); \
    float rate = *(float *)(film + oRate), pos = *(float *)(film + oPos)
// In a loop over a film's GroupInst array gi: group instance g (inst) and its TrackInst array (ti); one without is
// skipped (continue)
#define GROUP_TRACKS(gi, g) uint8_t *inst = gi->data[g]; \
    int oT = inst ? poff(CLS(inst), "TrackInst") : -1; \
    if (oT < 0) continue; \
    struct { uint8_t **data; int num, max; } *ti = (void *)(inst + oT)

// One share of the pass over GObjObjects, sized so that a whole pass takes about 2 s, or the whole
// pass at once on the first call and after the camera has been still for over a second. As the pass
// reaches a slot, that slot's entry is kept (the same film: it keeps its last Position), replaced,
// added or dropped, so the list always holds this pass's answer for the slots already looked at and
// the last pass's for the rest. NO if the object list isn't as expected (then the fix stays off).
static BOOL scanFilms(CFAbsoluteTime now) {
    static int ok = -1, nameInterp = -2, at, li;                // at: next slot; li: first entry with slot >= at
    static void *interpCls; static CFAbsoluteTime last;
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    if (ok < 0) {                                                // once: the first objects sit at their own index (+0x38)
        int seen = 0, good = 1;
        for (int i = 0; objs->data && i < objs->num && i < 64; i++)
            if (objs->data[i]) { seen++; if (*(int *)((uint8_t *)objs->data[i] + 0x38) != i) good = 0; }
        if (!seen) return NO;                                    // not filled yet: ask again next time
        ok = good;
        if (!ok) LOG(@"film moves fix OFF: object list (GObjObjects) not as expected");
    }
    if (!ok) return NO;
    if (nameInterp == -2) nameInterp = nameIndex("SeqAct_Interp");
    if (nameInterp < 0) return NO;
    int n = objs->num, end;
    double gap = now - last; last = now;
    if (gap > 1 || gap < 0) { at = li = 0; end = n; }           // the whole pass now
    else end = MIN(n, at + (int)(n * gap / 2) + 1);              // this frame's share of a 2 s pass
    for (; at < end; at++) {
        uint8_t *o = objs->data[at]; void *cls = o ? CLS(o) : NULL;
        if (cls && !interpCls && *(int *)((uint8_t *)cls + 0x48) == nameInterp && *(int *)((uint8_t *)cls + 0x4c) == 0)
            interpCls = cls;                                     // the class itself (Engine: never unloaded)
        BOOL film = cls && cls == interpCls && *(int *)(o + 0x48) == nameInterp;
        Film *e = li < gNumFilms && gFilms[li].ref.idx == at ? &gFilms[li] : NULL;
        if (film && e && e->ref.obj == o) { li++; continue; }   // the same film
        if (film && e) { *e = (Film){ { o, at, cls }, 0, -1 }; li++; continue; }   // another film in this slot
        if (film) {
            if (gNumFilms == gMaxFilms) {
                int m = gMaxFilms ? gMaxFilms * 2 : 256; Film *g = realloc(gFilms, (size_t)m * sizeof *g);
                if (!g) continue;
                gFilms = g; gMaxFilms = m;
            }
            memmove(&gFilms[li + 1], &gFilms[li], (size_t)(gNumFilms - li) * sizeof *gFilms);
            gFilms[li++] = (Film){ { o, at, cls }, 0, -1 }; gNumFilms++;
        } else if (e) {                                          // no film here any more
            memmove(&gFilms[li], &gFilms[li + 1], (size_t)(gNumFilms - li - 1) * sizeof *gFilms); gNumFilms--;
        }
    }
    if (at >= n) { gNumFilms = li; at = li = 0; }                // pass done: entries past the end go
    return YES;
}

#ifdef IBFIX_SNAPS
// Diagnostic builds: one frame a second is traced step by step, plus how many frames since then the
// knight had to be placed
static NSMutableString *gFilmTrace; static CFAbsoluteTime gFilmTraceT; static BOOL gTraceOn; static int gPlaced, gChecked;
#define FTRACE(fmt, ...) do { if (gTraceOn && gFilmTrace.length < 700) [gFilmTrace appendFormat:fmt, ##__VA_ARGS__]; } while (0)
#else
#define FTRACE(fmt, ...) do { } while (0)
#endif
static BOOL gFacingFixOff;                                      // test builds: the capture's "as before" run (FIXES.md 86)
static BOOL enemyDead(void);                                    // 7d
#ifdef IBFIX_SNAPS
static void deathCheckLog(NSString *film);                      // 7d
#endif
static float gDeathFilmPos = -1;                                // test builds: a death scene's film time, for the haptics' log

static void fixFilmMoves(void) {
#ifdef IBFIX_SNAPS
    CFAbsoluteTime tnow = CFAbsoluteTimeGetCurrent();
    gTraceOn = tnow - gFilmTraceT >= 1;
    if (gTraceOn) {
        if (gFilmTrace.length) LOG(@"film moves check:%@ | frames checked %d, placed %d", gFilmTrace, gChecked, gPlaced);
        gFilmTrace = [NSMutableString string]; gFilmTraceT = tnow; gPlaced = gChecked = 0;
    }
#endif
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!scanFilms(now)) return;                                              // the level's films, a share each frame
    FTRACE(@" %d films;", gNumFilms);
    // The world's game time (WorldInfo.TimeSeconds), to tell whether a film was last looked at one game
    // tick ago (below); the real clock if it can't be read.
    uint8_t *wi = WORLD_INFO();
    int oTS = wi ? poff(CLS(wi), "TimeSeconds") : -1;
    double gameTime = oTS >= 0 ? *(float *)(wi + oTS) : now;
    // What every playing film wants for each knight it drives. When one knight is wanted by a film that only holds him
    // (one fixed key) and one that moves him, the one that moves him wins, whatever order the films are checked in.
#ifdef IBFIX_SNAPS
    // Diagnostic builds: fast-forward and every film's timeline. Time dilation (the game's speed: the
    // fast-forward button sets 1000 while held) and the game time each frame really advanced; for each
    // film, when it starts and stops advancing, its position, the real time it took and how long
    // fast-forward was held during it.
    {
        static float lastDil = 1, maxDelta; static CFAbsoluteTime ffSince; static int ffFrames;
        if (wi) {
            void *wcls = CLS(wi);
            int oTD = poff(wcls, "TimeDilation"), oDS = poff(wcls, "DeltaSeconds");
            float dil = oTD >= 0 ? *(float *)(wi + oTD) : 1, ds = oDS >= 0 ? *(float *)(wi + oDS) : 0;
            if (dil > 1.5f) { ffFrames++; if (ds > maxDelta) maxDelta = ds; }
            if ((dil > 1.5f) != (lastDil > 1.5f)) {
                if (dil > 1.5f) { ffSince = now; ffFrames = 0; maxDelta = 0; LOG(@"fast-forward ON: time dilation %.0f", dil); }
                else LOG(@"fast-forward OFF after %.2f s held, %d frames, game time per frame up to %.3f s (%.0fx at 60 fps)", now - ffSince, ffFrames, maxDelta, maxDelta * 60);
            }
            lastDil = dil;
        }
        static NSMutableDictionary<NSValue *, NSMutableDictionary *> *tl;
        if (!tl) tl = [NSMutableDictionary dictionary];
        NSMutableSet *seen = [NSMutableSet set];
        for (int f = 0; f < gNumFilms; f++) {
            if (!refLive(&gFilms[f].ref)) continue;
            uint8_t *film = gFilms[f].ref.obj; NSValue *v = [NSValue valueWithPointer:film];
            void *cls = gFilms[f].ref.cls;
            int oGI = poff(cls, "GroupInst"), oPos = poff(cls, "Position"), oC = poff(cls, "ObjComment");
            if (oGI < 0 || oPos < 0) continue;
            int ng = *(int *)(film + oGI + 8); float t = *(float *)(film + oPos);
            NSMutableDictionary *s = tl[v];
            if (ng > 0 && !s) { tl[v] = s = [@{@"pos": @(t), @"moved": @0, @"start": @(now), @"startPos": @(t), @"lastMove": @(now), @"ff": @0} mutableCopy]; }
            if (!s) continue;
            [seen addObject:v];
            if (t != [s[@"pos"] floatValue]) {
                if (![s[@"moved"] boolValue]) {
                    s[@"moved"] = @1; s[@"start"] = @(now); s[@"startPos"] = s[@"pos"];
                    LOG(@"film start: %@ '%@' at %.2f s", ibfix_objname(film), oC >= 0 ? wstr(film, oC, oC + 8) : @"", [s[@"pos"] floatValue]);
                }
                s[@"pos"] = @(t); s[@"lastMove"] = @(now);
            }
            if (lastDil > 1.5f && [s[@"moved"] boolValue]) s[@"ff"] = @([s[@"ff"] doubleValue] + 1);
            // A boss's death scene (the arenas' "Death" film, SeqAct_Interp_24, Zero's _1, while the boss has no health): its
            // film time kept for the haptics' log, and, with kDeathPictures, the first two per launch photographed 10 times a
            // second, named with their film time (FIXES.md 84). Off by default: switch on to time a scene again.
            if ([s[@"moved"] boolValue] && [s[@"pos"] floatValue] < 0.5f && ![s[@"checked"] boolValue]) {   // a death-type film's start: what the check sees
                NSString *fn = ibfix_objname(film);
                const uint8_t *top = film; for (int k = 0; *(const uint8_t **)(top + 0x40) && k < 16; k++) top = *(const uint8_t **)(top + 0x40);
                if ([ibfix_objname((void *)top) hasPrefix:@"Battle_"] && ([fn isEqualToString:@"SeqAct_Interp_24"] || [fn isEqualToString:@"SeqAct_Interp_1"])) {
                    s[@"checked"] = @1; deathCheckLog([NSString stringWithFormat:@"%@ %@", ibfix_objname((void *)top), fn]);
                }
            }
            if ([s[@"moved"] boolValue] && enemyDead()) {
                NSString *fn = ibfix_objname(film);
                const uint8_t *top = film; for (int k = 0; *(const uint8_t **)(top + 0x40) && k < 16; k++) top = *(const uint8_t **)(top + 0x40);
                NSString *lv = ibfix_objname((void *)top);
                if ([lv hasPrefix:@"Battle_"] && ([fn isEqualToString:@"SeqAct_Interp_24"] || ([lv isEqualToString:@"Battle_6ft_Zero"] && [fn isEqualToString:@"SeqAct_Interp_1"]))) {
                    static void *shotFilm; static int scenes, shots; static CFAbsoluteTime lastShot, sceneAt;
#ifdef IBFIX_BLOODCAP
                    static const BOOL kDeathPictures = YES;     // 4ab: the blood mock-ups' frames
#else
                    static const BOOL kDeathPictures = NO;
#endif
                    if (film != shotFilm) { shotFilm = film; scenes++; shots = 0; sceneAt = now; LOG(@"death scene %d: %@ %@%@", scenes, lv, fn, kDeathPictures && scenes <= 2 ? @" (photographed 10 a second)" : @""); }
                    gDeathFilmPos = t;
                    if (kDeathPictures && scenes <= 2 && now - lastShot >= 0.1) {
                        lastShot = now;
                        ibfix_snap([NSString stringWithFormat:@"death%d-%@-%03d-film%05.2f-real%05.2f", scenes, lv, shots++, t, now - sceneAt]);
                    }
                }
            }
            BOOL stopped = [s[@"moved"] boolValue] && (ng == 0 || now - [s[@"lastMove"] doubleValue] > 0.3);
            if (stopped) {
                LOG(@"film end: %@ '%@' from %.2f to %.2f s of film in %.2f s real time (%@; %.0f frames under fast-forward)", ibfix_objname(film),
                    oC >= 0 ? wstr(film, oC, oC + 8) : @"", [s[@"startPos"] floatValue], [s[@"pos"] floatValue], [s[@"lastMove"] doubleValue] - [s[@"start"] doubleValue],
                    ng == 0 ? @"finished, groups released" : @"stopped advancing", [s[@"ff"] doubleValue]);
                [tl removeObjectForKey:v];
            } else if (ng == 0) [tl removeObjectForKey:v];
        }
        for (NSValue *k in tl.allKeys)                                         // films gone with their level: a new
            if (![seen containsObject:k]) [tl removeObjectForKey:k];           // film at the same address starts afresh
    }
#endif
    typedef struct { uint8_t *actor; float want[3]; BOOL hold; uint8_t *film; float t; int rot[3]; BOOL turns; } Want;
    enum { kMaxWants = 32 };                                                  // 2 at most seen at once
    Want wants[kMaxWants]; int nw = 0; BOOL tooMany = NO;
    static void *filmCls; static int oGI = -1, oPos = -1;                    // every film has the one class
    for (int f = 0; f < gNumFilms; f++) {
        Film *fl = &gFilms[f];
        if (!refLive(&fl->ref)) continue;                                     // unloaded: not read at all
        uint8_t *film = fl->ref.obj;
        if (fl->ref.cls != filmCls) { filmCls = fl->ref.cls; oGI = poff(filmCls, "GroupInst"); oPos = poff(filmCls, "Position"); }
        if (oGI < 0 || oPos < 0) continue;
        struct { uint8_t **data; int num, max; } *gi = (void *)(film + oGI);
        if (gi->num <= 0 || gi->num > 64) continue;                              // not started
        float t = *(float *)(film + oPos);
        // only a film that is playing: its Position moved since it was last looked at, at most one game tick before
        // (a finished film that keeps its groups, or a paused one, is left alone). After a stretch with no camera updates
        // (the results screen), or when a film is first seen, that frame only notes the new Position. In game time, not
        // camera updates or the clock: one tick is never over 0.4 s of game time (the engine's limit, even under
        // fast-forward), so a slow frame still counts; a double camera update in one tick sees no move (harmless).
        double age = gameTime - fl->seenAt;
        BOOL playing = fl->seenAt >= 0 && age >= 0 && age < 0.5 && fl->pos != t;
        fl->pos = t; fl->seenAt = gameTime;
        if (!playing) continue;
        for (int i = 0; i < gi->num; i++) {
            uint8_t *inst = gi->data[i];
            if (!inst || !isClass(inst, "InterpGroupInstAI")) continue;
            void *icls = CLS(inst);
            int oG = poff(icls, "Group"), oA = poff(icls, "GroupActor");
            uint8_t *group = oG >= 0 ? *(uint8_t **)(inst + oG) : NULL, *actor = oA >= 0 ? *(uint8_t **)(inst + oA) : NULL;
            if (!group || !actor) continue;
            int oT = poff(CLS(group), "InterpTracks");
            if (oT < 0) continue;
            struct { void **data; int num, max; } *tracks = (void *)(group + oT);
            void *move = NULL;
            for (int k = 0; k < tracks->num && k < 16; k++) if (isClass(tracks->data[k], "InterpTrackMove")) { move = tracks->data[k]; break; }
            Want w = { actor, {0, 0, 0}, NO, film, t, {0, 0, 0}, NO };
            if (!move || !evalMoveTrack(move, t, w.want)) continue;
            w.turns = evalTurnTrack(move, t, w.rot);
            struct { CurvePoint *p; int num, max; } *pts = (void *)((uint8_t *)move + poff(CLS(move), "PosTrack"));
            w.hold = YES;                                              // one key, or every key on the same spot: it only holds him
            for (int k = 1; k < pts->num && w.hold; k++)
                if (fabsf(pts->p[k].out[0] - pts->p[0].out[0]) > 1 || fabsf(pts->p[k].out[1] - pts->p[0].out[1]) > 1) w.hold = NO;
            FTRACE(@" %@ at %.2f: %@ %@ %.0f,%.0f;", ibfix_objname(film), t, ibfix_objname(actor), w.hold ? @"holds at" : @"moves to", w.want[0], w.want[1]);
            if (nw == kMaxWants) { tooMany = YES; break; }
            wants[nw++] = w;
        }
    }
    if (tooMany) {                     // a dropped want could be the moving film that beats a hold: placing now
        static CFAbsoluteTime lastWarn;  // might let the hold win, so this frame is left to the engine
        if (now - lastWarn > 30) { lastWarn = now; LOG(@"film moves: over %d film groups playing at once; left to the engine", kMaxWants); }
        return;
    }
    for (int i = 0; i < nw; i++) {
        Want *w = &wants[i];
        BOOL beaten = NO, done = NO; uint8_t *rival = NULL;
        for (int j = 0; j < nw; j++) {
            if (j == i || wants[j].actor != w->actor) continue;
            if (wants[j].film != w->film) rival = wants[j].film;                // another playing film wants him too
            if (w->hold && !wants[j].hold) beaten = YES;                         // a moving film beats a holding one
            if (j < i && wants[j].hold == w->hold) {                             // same kind: the first one decides
                done = YES;
                static int warned;                                               // never seen (the castle audit found no such case)
                if (!w->hold && warned++ < 3) LOG(@"film moves: two moving films drive %@ at once (%@, %@); the first decides", ibfix_objname(w->actor), ibfix_objname(wants[j].film), ibfix_objname(w->film));
            }
        }
        if (!rival || beaten || done) continue;                                  // one film only: the engine's own move stands
        uint8_t *actor = w->actor;
        void *acls = CLS(actor);
        int oL = poff(acls, "Location"), oP = poff(acls, "Physics"), oCyl = poff(acls, "CylinderComponent"), oR = poff(acls, "Rotation");
        if (oL < 0 || oP < 0 || actor[oP] != 7) continue;                       // only while a film moves him (PHYS_Interpolating)
        float *loc = (float *)(actor + oL);
        float dx = loc[0] - w->want[0], dy = loc[1] - w->want[1];
#ifdef IBFIX_SNAPS
        gChecked++;
#endif
        // which way he faces (FIXES.md 86): more than 3 degrees (546) off the winning film's yaw, he is turned
        int *rot = oR >= 0 ? (int *)(actor + oR) : NULL;
        int dyaw = rot && w->turns ? (int)(int16_t)(uint16_t)(rot[1] - w->rot[1]) : 0;
        if (rot && w->turns && abs(dyaw) > 546 && !gFacingFixOff) {
            rot[0] = w->rot[0]; rot[1] = w->rot[1]; rot[2] = w->rot[2];
            static void *lastTurned; static CFAbsoluteTime lastTurnLog;
            if (actor != lastTurned || now - lastTurnLog > 30) {
                lastTurned = actor; lastTurnLog = now;
                LOG(@"film %@: %@ faced %.0f degrees off at %.2f s (%@ wants him too); turned to yaw %.0f as this film says",
                    ibfix_objname(w->film), ibfix_objname(actor), dyaw * 360.0f / 65536, w->t, ibfix_objname(rival), (w->rot[1] & 65535) * 360.0f / 65536);
            }
            if (dx * dx + dy * dy <= 24.0f * 24.0f) {                            // in place already: just the turn shown
                void *fn = findFunction(actor, "ForceUpdateComponents");
                int oTO = fn ? poff(fn, "bTransformOnly") : -1;
                if (fn && oTO >= 0 && oTO < 16 && *(uint16_t *)((uint8_t *)fn + 0xe2) <= 16) { uint8_t parms[16] = {0}; parms[oTO] = 1; processEvent(actor, fn, parms); }
            }
        }
        if (dx * dx + dy * dy <= 24.0f * 24.0f) continue;                         // the engine did it
#ifdef IBFIX_SNAPS
        gPlaced++;
#endif
        // the film's track gives his feet; the actor's location is the middle of his collision cylinder
        uint8_t *cyl = oCyl >= 0 ? *(uint8_t **)(actor + oCyl) : NULL;
        int oH = cyl ? poff(CLS(cyl), "CollisionHeight") : -1;
        float half = oH >= 0 ? *(float *)(cyl + oH) : loc[2] - w->want[2];
        float from[3] = { loc[0], loc[1], loc[2] };
        loc[0] = w->want[0]; loc[1] = w->want[1]; loc[2] = w->want[2] + half;
        void *fn = findFunction(actor, "ForceUpdateComponents");              // (bCollisionUpdate false, bTransformOnly true)
        int oTO = fn ? poff(fn, "bTransformOnly") : -1;
        if (fn && oTO >= 0 && oTO < 16 && *(uint16_t *)((uint8_t *)fn + 0xe2) <= 16) { uint8_t parms[16] = {0}; parms[oTO] = 1; processEvent(actor, fn, parms); }
        static void *lastActor, *lastFilm; static CFAbsoluteTime lastLog;
        if (actor != lastActor || w->film != lastFilm || now - lastLog > 30) {
            lastActor = actor; lastFilm = w->film; lastLog = now;
            LOG(@"film %@: %@ held elsewhere at %.2f s (%@ wants him too); placed at (%.0f, %.0f, %.0f) from (%.0f, %.0f, %.0f) as this film says",
                ibfix_objname(w->film), ibfix_objname(actor), w->t, ibfix_objname(rival), loc[0], loc[1], loc[2], from[0], from[1], from[2]);
        }
    }
}

// ---- 9. Field of view on wide screens ------------------------------------------------------
// Camera.UpdateCamera calls UpdateViewTarget(ViewTarget or PendingViewTarget, DeltaTime) from
// script, so the virtual-call hook sees it. Its first argument is an instance variable (token
// EX_InstanceVariable 0x01 + UProperty*; Offset at +0x7c) holding a TViewTarget: Target @0,
// Controller @8, POV { Location @16, Rotation @28, FOV @40 }, AspectRatio @44. After SwordCamera
// has set AspectRatio to the screen's and widened FOV, the FOV is recomputed as above.
static int gNameUpdateViewTarget = -2;
static void *gSwordCameraClass, *gNotCameraClass;
static BOOL isSwordCamera(void *obj) {
    void *cls = CLS(obj);
    if (cls == gSwordCameraClass) return YES;
    if (cls == gNotCameraClass) return NO;
    for (uint8_t *c = cls; c; c = *(uint8_t **)(c + 0x68))
        if ([ibfix_objname(c) isEqualToString:@"SwordCamera"]) { gSwordCameraClass = cls; return YES; }
    gNotCameraClass = cls;
    return NO;
}
// The title's establishing shot (every title screen, including the one after the God King) shows, at the left, where
// the world was never built: a rock cut off in a straight line about 34 degrees left of centre, inside the wide
// screen's half view of 36.6 degrees (an iPhone 5's is 31). So the shot turns right just enough to keep the cut off
// screen, with a degree spare for its gentle sway (FIXES.md 20). The intro's CameraActor_5 glides back during the
// knight's monologue to exactly where the "TITLE SCREEN LOOP" camera (CameraActor_4) stands, (-40934.6, -20521.7,
// -17607.9), so the glide and the title turn by the same amount to keep the hand-over seamless. The opening shot (the
// same camera before the close-up, a hard cut) has its own, smaller amount. The scene's views are those within 3000
// units of that spot (only the title loads that scenery); the close-up (CameraActor_1) is left alone.
// Which shot of the scene a view belongs to: 0 = not the scene, 1 = the opening shot (CameraActor_5
// before the close-up), 2 = the knight close-up (CameraActor_1), 3 = the monologue glide
// (CameraActor_5 again), 4 = the title loop (CameraActor_4). Shots 1 and 3 share a camera and a
// spot (the glide starts where shot 1 stopped), so the order tells them apart.
static int titleShot(uint8_t *vt) {
    static int shot; static void *lastTarget;
    float *loc = (float *)(vt + 16);
    float dx = loc[0] + 40934.6f, dy = loc[1] + 20521.7f, dz = loc[2] + 17607.9f;
    if (dx * dx + dy * dy + dz * dz > 3000.0f * 3000.0f) { shot = 0; lastTarget = NULL; return 0; }
    void *target = *(void **)vt;
    if (target != lastTarget) {
        lastTarget = target;
        NSString *n = target ? ibfix_objname(target) : @"";
        shot = [n isEqualToString:@"CameraActor_5"] ? (shot >= 2 ? 3 : 1) : [n isEqualToString:@"CameraActor_1"] ? 2
             : [n isEqualToString:@"CameraActor_4"] ? 4 : shot;
    }
    return shot;
}
// How far each shot turns (FIXES.md 20); the camera's hand-held sway moves the view up to about 1 degree either way.
// Shots 3 and 4: the cut comes as near as 33 degrees from the centre, so they turn it a degree past the screen's edge.
// Shot 1: unbuilt black lies 2.8 degrees beyond its right edge while the cut comes 1 degree inside at its end; the
// turn (1.85 degrees on the iPhone 17) is the middle of that window.
static float titleShotTurn(int shot, float halfView) {
    float turn = shot == 1 ? halfView - 34.72f : shot >= 3 ? halfView - 33.0f + 1.0f : 0;
    return turn > 0 ? turn : 0;
}
#ifdef IBFIX_SNAPS
static void *gViewCamera;                                              // the SwordCamera of the current call
// The player's pawn (the knight in the title scene): Camera.PCOwner -> Controller.Pawn.
// The intro film as Matinee drives it (Birthright_P's SeqAct_Interp_58, "INTRO pre title screen"):
// its position, then for each group its name and actor, the actor's Location and Physics, and for a
// pawn the world position of its root bone. Found once in GObjObjects (0x100cb29a8) by its FName
// ("SeqAct_Interp", number 59) and its package.
// The root bone and the body: every bone whose name holds Root, Pelvis, Spine or Foot (the first time,
// all bone names are logged once), in world space.
static NSString *rootBone(void *actor) {
    int offMesh = poff(CLS(actor), "Mesh");
    void *mesh = offMesh >= 0 ? *(void **)((uint8_t *)actor + offMesh) : NULL;
    void *fName = mesh ? findFunction(mesh, "GetBoneName") : NULL, *fLoc = mesh ? findFunction(mesh, "GetBoneLocation") : NULL;
    if (!fName || !fLoc || *(uint16_t *)((uint8_t *)fName + 0xe2) > 64 || *(uint16_t *)((uint8_t *)fLoc + 0xe2) > 64) return @"";
    static int oi = -2, orv, on, olr;
    if (oi == -2) { oi = propertyOffset(fName, "BoneIndex"); orv = propertyOffset(fName, "ReturnValue"); on = propertyOffset(fLoc, "BoneName"); olr = propertyOffset(fLoc, "ReturnValue"); }
    if (oi < 0 || orv < 0 || on < 0 || olr < 0) return @"";
    static NSMutableArray *pick; static NSMutableArray *pickNames;
    if (!pick) {
        pick = [NSMutableArray array]; pickNames = [NSMutableArray array]; NSMutableString *all = [NSMutableString string];
        for (int b = 0; b < 120; b++) {
            uint8_t pn[64] = {0}; *(int *)(pn + oi) = b; processEvent(mesh, fName, pn);
            uint64_t nm = *(uint64_t *)(pn + orv); if (!(uint32_t)nm) break;
            struct { uint8_t pad[0x48]; uint64_t name; } fake; fake.name = nm; NSString *s = ibfix_objname(&fake);
            [all appendFormat:@" %d:%@", b, s];
            if ([s rangeOfString:@"Root"].length || [s rangeOfString:@"Pelvis"].length || [s rangeOfString:@"Spine"].length || [s rangeOfString:@"Foot"].length) { [pick addObject:@(nm)]; [pickNames addObject:s]; }
            if (pick.count >= 8) break;
        }
        LOG(@"knight bones:%@", all);
    }
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger k = 0; k < pick.count; k++) {
        uint8_t pl[64] = {0}; *(uint64_t *)(pl + on) = [pick[k] unsignedLongLongValue]; processEvent(mesh, fLoc, pl);
        float *v = (float *)(pl + olr);
        [out appendFormat:@" %@ (%.1f, %.1f, %.1f)", pickNames[k], v[0], v[1], v[2]];
    }
    return out;
}
static NSString *filmGroups(void) {
    static ObjRef ref; static int tries;
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    if (ref.obj && !refLive(&ref)) ref.obj = NULL;   // still the same live object? (levels reload after a fight; checked by slot, not read)
    if (!ref.obj && tries++ < 1200) {
        int want = nameIndex("SeqAct_Interp");
        for (int i = 0; i < objs->num && want >= 0; i++) {
            uint8_t *o = objs->data[i];
            if (!o || *(int *)(o + 0x48) != want || *(int *)(o + 0x4c) != 59) continue;
            uint8_t *top = o; for (int k = 0; *(uint8_t **)(top + 0x40) && k < 16; k++) top = *(uint8_t **)(top + 0x40);
            if ([ibfix_objname(top) isEqualToString:@"Birthright_P"]) { ref = (ObjRef){ o, i, CLS(o) }; break; }
        }
    }
    void *interp = ref.obj;
    if (!interp) return @"film: not found";
    void *cls = CLS(interp);
    int offGI = poff(cls, "GroupInst"), offPos = poff(cls, "Position");
    if (offGI < 0) return @"film: no GroupInst";
    struct { void **data; int num, max; } *gi = (void *)((uint8_t *)interp + offGI);
    NSMutableString *s = [NSMutableString stringWithFormat:@"film at %.2f s:", offPos >= 0 ? *(float *)((uint8_t *)interp + offPos) : -1];
    for (int i = 0; i < gi->num && i < 8; i++) {
        uint8_t *inst = gi->data[i]; if (!inst) continue;
        void *icls = CLS(inst);
        int oG = poff(icls, "Group"), oA = poff(icls, "GroupActor");
        uint8_t *group = oG >= 0 ? *(uint8_t **)(inst + oG) : NULL, *actor = oA >= 0 ? *(uint8_t **)(inst + oA) : NULL;
        int oN = group ? poff(CLS(group), "GroupName") : -1;
        struct { uint8_t pad[0x48]; uint64_t name; } fake; fake.name = oN >= 0 ? *(uint64_t *)(group + oN) : 0;
        [s appendFormat:@" [%@ (%@): %@", oN >= 0 ? ibfix_objname(&fake) : @"?", ibfix_objname(icls), actor ? ibfix_objname(actor) : @"no actor"];
        if (actor) {
            void *acls = CLS(actor);
            int oL = poff(acls, "Location"), oP = poff(acls, "Physics");
            if (oL >= 0) { float *l = (float *)(actor + oL); [s appendFormat:@" at (%.1f, %.1f, %.1f)", l[0], l[1], l[2]]; }
            if (oP >= 0) [s appendFormat:@" physics %d", actor[oP]];
            if ([ibfix_objname(icls) isEqualToString:@"InterpGroupInstAI"]) [s appendString:rootBone(actor)];
        }
        [s appendString:@"]"];
    }
    return s;
}

#endif

// The camera's place in the world, for the lens flares (flare.m): the view target's POV location (+16), each update.
static float gCamLoc[3]; static BOOL gCamKnown;
BOOL ibfix_camera_location(float out[3]) { if (gCamKnown) memcpy(out, gCamLoc, sizeof gCamLoc); return gCamKnown; }
static void fixViewTargetFOV(uint8_t *vt) {
    memcpy(gCamLoc, vt + 16, sizeof gCamLoc); gCamKnown = YES;
    float W = gViewportWidth, H = gViewportHeight;
    if (H <= 0) return;
    float aspect = W / H, ref = 1136.0f / 640.0f;                  // the iPhone 5's screen
    float *fov = (float *)(vt + 40), *ar = (float *)(vt + 44);
    // The iPad filling its screen (3g): the game keeps each camera's own shape there (3:2 mostly), which draws black bars
    // above and below; give the view the screen's shape and the same rule as wide screens, the iPhone 5's height of view.
    BOOL padFill = gIPadFill && aspect > 1.3f && aspect < 1.49f && *ar > 1.2f && *ar < 2.5f && *fov >= 5 && *fov <= 175;
    if (!padFill && (aspect <= ref + 0.01f || fabsf(*ar - aspect) > 0.02f || *fov < 5 || *fov > 175)) return;
    float fov5 = padFill ? *fov * ref / *ar : *fov * ref / aspect;  // what the game would give an iPhone 5
    if (padFill) *ar = aspect;
    float fixed = atanf(tanf(fov5 * (float)M_PI / 360) * aspect / ref) * 360 / (float)M_PI;   // 2 atan(...), in degrees
    static float lastIn; static void *lastTarget;
    void *target = *(void **)vt;
    if (fabsf(lastIn - *fov) > 0.5f || target != lastTarget) {
        lastIn = *fov; lastTarget = target;
        int *rot = (int *)(vt + 28); float *loc = (float *)(vt + 16);
        LOG(@"view: camera %@.%@ at (%.0f, %.0f, %.0f) yaw %d pitch %d: field of view %.1f -> %.1f degrees (iPhone 5 view %.1f)",
            target ? ibfix_objname(*(void **)((uint8_t *)target + 0x40) ? *(void **)((uint8_t *)target + 0x40) : target) : @"none",
            target ? ibfix_objname(target) : @"none", loc[0], loc[1], loc[2], rot[1], rot[0], *fov, fixed, fov5);
    }
    *fov = fixed;
    int *yaw = (int *)(vt + 32);                                      // POV.Rotation.Yaw (+ turns right)
    float shift = 0;
    int shot = titleShot(vt);
    if (shot == 1 || shot >= 3) {
        static int lastShot;
        if (shot == 4) {                                               // the title loop's sway, measured
            static int swayMin = INT_MAX, swayMax = INT_MIN; static CFAbsoluteTime swayLogged;
            BOOL wider = *yaw < swayMin || *yaw > swayMax;
            if (*yaw < swayMin) swayMin = *yaw;
            if (*yaw > swayMax) swayMax = *yaw;
            if (wider && CFAbsoluteTimeGetCurrent() - swayLogged > 10) {
                swayLogged = CFAbsoluteTimeGetCurrent();
                LOG(@"view: title camera sway so far: yaw %d to %d (%.2f degrees)", swayMin, swayMax, (swayMax - swayMin) * 360.0f / 65536);
            }
        }
        shift = titleShotTurn(shot, fixed / 2);                        // degrees to turn right
        if (shift > 0) *yaw += (int)(shift * 65536 / 360);
        if (shot != lastShot) { lastShot = shot; LOG(@"view: title scene shot %d (%@) turned right %.2f degrees", shot, ibfix_objname(target), shift); }
    }
#ifdef IBFIX_SNAPS
    {   // Diagnostic builds: while the intro film (SeqAct_Interp_58) is playing, its groups every 0.5 s
        static CFAbsoluteTime lastFilm; CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        static CFAbsoluteTime filmEnd;
        if (now - lastFilm >= 0.5) {
            lastFilm = now; NSString *g = filmGroups();
            BOOL playing = [g containsString:@"[Player"] && ![g hasPrefix:@"film at 20.00"];
            if (playing) filmEnd = now;
            if (playing || (filmEnd && now - filmEnd < 6)) {          // and 6 s into the title, for the step
                void *pc = NULL, *pawn = NULL; int oPC = gViewCamera ? poff(CLS(gViewCamera), "PCOwner") : -1;
                if (oPC >= 0) pc = *(void **)((uint8_t *)gViewCamera + oPC);
                int oPawn = pc ? poff(CLS(pc), "Pawn") : -1;
                if (oPawn >= 0) pawn = *(void **)((uint8_t *)pc + oPawn);
                LOG(@"intro film: %@ | camera %@ | pawn body:%@", g, target ? ibfix_objname(target) : @"none", pawn ? rootBone(pawn) : @" none");
            }
        }
    }
#endif
}

// ---- 7b. Block button size ----------------------------------------------------------------
// The game sizes the dodge buttons with its "Dodge Button Size" option (GameOptions.DodgeScale, 1-2x, in
// SwordHudMain.OnMobileInputZoneAdded); the block button had nothing like it. Section 7's "Block Button Size" v (0-1, in
// tenths) gives b = 1 + 0.5 v, up to 1.5x (by choice, FIXES.md 30; study/block-size-plan.md: 1.75x is the most that stays
// clear). Each time the HUD sets up its touch zones (SetInputConfig -> OnMobileInputZoneAdded, at every HUD mode change,
// so a pause-menu change shows on resume), right after the game's own code for the SwordShieldBlock zone, the zone, the
// six shield pictures (ShieldIcon) and its number (ShieldValue) are scaled by b about the button's bottom centre (x 480
// of 960 units). b = 1 writes back exactly the devs' numbers.
#define BLOCK_SCALE_MAX 1.5f
static float blockScale(void) { return 1.0f + fminf(fmaxf(gBlockSlider, 0.0f), 1.0f) * (BLOCK_SCALE_MAX - 1.0f); }

// The UProperty itself (propertyOffset gives only its Offset): ArrayDim +0x68, ElementSize +0x6c, Offset +0x7c.
static uint8_t *findProperty(void *structp, const char *name) {
    for (uint8_t *st = structp; st; st = *(uint8_t **)(st + 0x68))
        for (uint8_t *f = *(uint8_t **)(st + 0x70); f; f = *(uint8_t **)(f + 0x60))
            if ([ibfix_objname(f) isEqualToString:@(name)] && [ibfix_objname(CLS(f)) hasSuffix:@"Property"]) return f;
    return NULL;
}
// ShieldIcon[0..5] (classes/SwordHudMain.uc): all at (356,492) 226x149 units; their UVs identify them.
static const float kShieldUV[6][4] = { {1,439,226,149}, {401,213,226,149}, {455,366,226,149},
                                       {228,366,226,149}, {1,289,226,149}, {628,213,226,149} };
static void applyBlockSize(uint8_t *hud, uint8_t *zone) {
    static BOOL off, checked; static float applied = 1;
    if (off) return;
    float b = blockScale();
    if (b == 1 && applied == 1) return;                         // the devs' size, never changed: touch nothing
    // (a) The zone, in region pixels: X +0xb0, Y +0xb4, SizeX +0xb8, SizeY +0xbc. The region size is its
    //     MobilePlayerInput's MobileViewportSize (+0x498), the one the engine's own layout (0x100881d74) uses.
    void *zc = CLS(zone);
    int oX = poff(zc, "X"), oY = poff(zc, "Y"), oW = poff(zc, "SizeX"), oH = poff(zc, "SizeY"), oIn = poff(zc, "InputOwner");
    uint8_t *input = oIn > 0 ? *(uint8_t **)(zone + oIn) : NULL;
    int oVS = input ? poff(CLS(input), "MobileViewportSize") : -1;
    if (oX != 0xb0 || oY != 0xb4 || oW != 0xb8 || oH != 0xbc || oVS != 0x498) {
        off = YES; LOG(@"block size OFF: zone fields not as expected (%#x %#x %#x %#x, region %#x)", oX, oY, oW, oH, oVS); return;
    }
    float vw = *(float *)(input + oVS), vh = *(float *)(input + oVS + 4), *z = (float *)(zone + oX);
    if (vw < 100 || vh < 100 || z[2] < 2) return;               // not laid out in pixels yet (still fractions): next time
    // (b) The six pictures: each IconInfo starts DrawPos, DrawSize (units); its UV is found by matching.
    void *hc = CLS(hud);
    uint8_t *ip = findProperty(hc, "ShieldIcon");
    int dim = ip ? *(int *)(ip + 0x68) : 0, esz = ip ? *(int *)(ip + 0x6c) : 0, base = ip ? *(int *)(ip + 0x7c) : -1;
    static int uvOff = -1;
    if (uvOff < 0 && dim == 6 && esz >= 0x20 && base > 0)
        for (int o = 0x10; o + 16 <= esz && uvOff < 0; o += 4) if (!memcmp(hud + base + o, kShieldUV[0], 16)) uvOff = o;
    BOOL picsOK = uvOff >= 0;
    for (int i = 0; picsOK && i < 6; i++) picsOK = !memcmp(hud + base + i * esz + uvOff, kShieldUV[i], 16);
    if (!checked) {                                             // first sight: the devs' zone and pictures, as laid out
        float *e = picsOK ? (float *)(hud + base) : NULL;
        if (!e || e[0] != 356 || e[1] != 492 || e[2] != 226 || e[3] != 149 ||
            fabsf(z[0] / vw - 0.41f) > 0.003f || fabsf(z[1] / vh - 0.80f) > 0.003f ||
            fabsf(z[2] / vw - 0.18f) > 0.003f || fabsf(z[3] / vh - 0.21f) > 0.003f) {
            off = YES; LOG(@"block size OFF: shield not as the devs made it (zone %.0f,%.0f %.0fx%.0f of %.0fx%.0f, pictures %d x %#x)",
                           z[0], z[1], z[2], z[3], vw, vh, dim, esz); return;
        }
        checked = YES;
    }
    if (!picsOK) { off = YES; LOG(@"block size OFF: shield pictures not as expected"); return; }
    // Everything checked: write. The zone is truncated like the engine's layout, so b = 1 is the devs' zone.
    z[0] = truncf(vw * (0.50f - 0.09f * b)); z[1] = truncf(vh * (1.01f - 0.21f * b));
    z[2] = truncf(vw * 0.18f * b);           z[3] = truncf(vh * 0.21f * b);
    for (int i = 0; i < 6; i++) {
        float *e = (float *)(hud + base + i * esz);              // DrawPos.X, DrawPos.Y, DrawSize.X, DrawSize.Y
        e[0] = 480 - 124 * b; e[1] = 641 - 149 * b; e[2] = 226 * b; e[3] = 149 * b;
    }
    // (c) The number: ShieldValue (a SwordDrawText, box (459,572) 42x30) through its own UpdateBoundingBox(X, Y, W, H).
    int oSV = poff(hc, "ShieldValue");
    uint8_t *txt = oSV > 0 ? *(uint8_t **)(hud + oSV) : NULL, *ub = txt ? findFunction(txt, "UpdateBoundingBox") : NULL;
    if (ub && *(uint16_t *)(ub + 0xe2) == 16 && propertyOffset(ub, "X") == 0 && propertyOffset(ub, "Y") == 4 &&
        propertyOffset(ub, "W") == 8 && propertyOffset(ub, "H") == 12) {
        float box[4] = { 480 - 21 * b, 641 - 69 * b, 42 * b, 30 * b };
        processEvent(txt, ub, box);
    } else { static BOOL warned; if (!warned) { warned = YES; LOG(@"block size: the shield's number keeps its size (UpdateBoundingBox not as expected)"); } }
    applied = b;
    static float lastB, lastW;
    if (b != lastB || vw != lastW) { lastB = b; lastW = vw;
        LOG(@"block size %.3fx (slider %.2f): zone %.0f,%.0f %.0fx%.0f px of %.0fx%.0f | shield (%.1f,%.1f) %.1fx%.1f units",
            b, gBlockSlider, z[0], z[1], z[2], z[3], vw, vh, 480 - 124 * b, 641 - 149 * b, 226 * b, 149 * b); }
}
// SetInputConfig calls OnMobileInputZoneAdded(Zone) with Zone its own local variable: after the FName
// operand comes EX_LocalVariable (0x00) and the UProperty*, read from the caller's Locals (FFrame +0x30).
static void *localObjectArg(void *stack) {
    uint8_t *arg = *(uint8_t **)((uint8_t *)stack + FFRAME_CODE) + 8;
    if (arg[0] != 0x00) return NULL;
    uint8_t *prop; memcpy(&prop, arg + 1, sizeof prop);
    uint8_t *locals = *(uint8_t **)((uint8_t *)stack + 0x30);
    return prop && locals ? *(void **)(locals + *(int *)(prop + 0x7c)) : NULL;
}
static void blockZoneAdded(void *hud, uint8_t *zone) {
    NAME_ONCE(nameShield, "SwordShieldBlock");
    if (nameShield < 0 || *(int *)(zone + 0x48) != nameShield || *(int *)(zone + 0x4c) != 0 || !isClass(hud, "SwordHudMain")) return;
    applyBlockSize(hud, zone);
}

// ---- 4g. Our own music goes through the game (FIXES.md 39) ----
// The game keeps its own record of the current track (WorldInfo +0x660, currentTrack in 4d), and the hand-overs (4d), the
// stage rule (4f) and the save points (6) all go by it. So every track we start is asked of the game the way the devs'
// script asks: by running their music action (USeqAct_PlayMusicTrack::Activated, which only copies the action's
// MusicTrack and passes it to AWorldInfo::UpdateMusicTrack; no output link is touched): their own action for that track
// when its level is loaded, otherwise the last one their script ran, with only its MP3 name lent. Game thread only.
int ibfix_objects_of_class(const char *name, void **out, int max);
static BOOL playTrack(NSString *want, NSString *why) {
    static void *acts[512];
    int n = ibfix_objects_of_class("SeqAct_PlayMusicTrack", acts, 512);
    uint8_t *a = NULL;
    for (int i = 0; i < n && !a; i++) {
        uint8_t *o = acts[i];
        if (!*(void **)(o + 0x140) && [wstr(o, 0x160, 0x168) caseInsensitiveCompare:want] == NSOrderedSame) a = o;
    }
    if (a) {
        gOrigPlayMusic(a);
        LOG(@"music: playing '%@' through the devs' own action for it, %@ (%@)", want, ibfix_objname(a), why);
        return YES;
    }
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    a = gLastMusicAction;
    if (!a || gLastMusicIdx < 0 || gLastMusicIdx >= objs->num || objs->data[gLastMusicIdx] != (void *)a || CLS(a) != gLastMusicCls || *(void **)(a + 0x140)) {
        LOG(@"music: no music action to play '%@' through (%@)", want, why); return NO;
    }
    static uint32_t buf[64]; int len = (int)MIN(want.length, 62);
    for (int i = 0; i < len; i++) buf[i] = [want characterAtIndex:i]; buf[len] = 0;
    void *d = *(void **)(a + 0x160); int num = *(int *)(a + 0x168), max = *(int *)(a + 0x16c);   // lend it our name
    *(void **)(a + 0x160) = buf; *(int *)(a + 0x168) = len + 1; *(int *)(a + 0x16c) = len + 1;
    gOrigPlayMusic(a);
    *(void **)(a + 0x160) = d; *(int *)(a + 0x168) = num; *(int *)(a + 0x16c) = max;   // and take it back
    LOG(@"music: playing '%@' through %@, its name lent (%@)", want, ibfix_objname(a), why);
    return YES;
}

// ---- 4f. Stage music where the devs left it out (FIXES.md 38) ----
// 21 of the 24 boss arenas start the next battle track at each of the boss's stages (Stage2 -> B, Stage3 -> C,
// Death Mode Start -> Kill, tools/stagemusic.py on decomp/levels); the two listed below have none, so stage 1's track
// played through the whole fight. In them, each stage event (SwordBoss.TriggerBossEvent_Internal, eEvent = output + 1:
// 6 stage 2, 7 stage 3, 1 death mode start) steps the current boss track on within its own family (Boss1A -> Boss1B ->
// Boss1C -> Boss1Kill), played through the game (4g). An opener stands for the stage 1 track it leads to (Boss1Open
// for Boss1A): a stage reached before the opener ends steps on from there (its own hand-over is then skipped, 4d).
// (Battle_10ft_Scene01, the scripted story fight, has its own story music and is left as it is.)
static const char *kNoStageMusic[] = { "Battle_10ft_03", "Battle_10ft_MP" };
static BOOL isLiveObject(const void *p);                    // 4e
#ifdef IBFIX_SNAPS
static unsigned long gObjChecks;                            // test builds: the kernel reads isLiveObject made (FIXES.md 90)
#endif
// A boss's arena: the level of its SpawnPoint.Helper (see stageMusic); *spOut gets the spawn point (or NULL).
static const uint8_t *bossArena(void *boss, const uint8_t **spOut) {
    void *bc = CLS(boss); int oSP = poff(bc, "SpawnPoint");
    const uint8_t *sp = oSP >= 0 ? *(const uint8_t **)((uint8_t *)boss + oSP) : NULL, *h = NULL;
    if (sp && !isLiveObject(sp)) sp = NULL;
    int oH = sp ? poff(CLS(sp), "Helper") : -1;
    if (oH >= 0) h = *(const uint8_t **)(sp + oH);
    if (h && !isLiveObject(h)) h = NULL;
    const uint8_t *o = h;
    for (int i = 0; o && *(const uint8_t **)(o + 0x40) && i < 16; i++) o = *(const uint8_t **)(o + 0x40);
    if (spOut) *spOut = sp;
    return o;
}
static void stageMusic(void *boss, int eEvent) {
    // The arena: the level of the boss's SpawnPoint.Helper, the SwordBossSpawnPointHelper the boss sends its events
    // through (TriggerBossEvent_Internal: EventHelper = SpawnPoint.Helper, then its GeneratedEvents, the arena's
    // SeqEvent_BossEvents). Each of the 24 arenas holds exactly one helper. Not the boss's own level nor the spawn
    // point's: both are the castle's (Birthright_P, Birthright_P_MP; decomp/levels/*_seq/exports.txt).
    const uint8_t *sp, *o = bossArena(boss, &sp);
    int oH = sp ? poff(CLS(sp), "Helper") : -1;
    const uint8_t *h = oH >= 0 ? *(const uint8_t **)(sp + oH) : NULL;
    if (h && !isLiveObject(h)) h = NULL;
    NSString *level = o ? ibfix_objname(o) : sp ? @"(no helper)" : @"(no spawn point)"; BOOL listed = NO;
    for (size_t i = 0; i < sizeof kNoStageMusic / sizeof kNoStageMusic[0]; i++) if ([level isEqualToString:@(kNoStageMusic[i])]) listed = YES;
    const char *step = eEvent == 6 ? "B" : eEvent == 7 ? "C" : eEvent == 1 ? "Kill" : NULL;
    LOG(@"stage music: boss event %d in %@ (helper %@ of %@: %@)", eEvent, level, ibfix_objname(h), ibfix_objname(sp),
        !step ? @"not a music stage" : listed ? @"no music of its own: stepping" : @"its own music");
    if (!listed || !step) return;
    NSString *now = currentTrack(), *next = followOn(now), *track = next.length ? next : now;
    NSTextCheckingResult *m = [[NSRegularExpression regularExpressionWithPattern:@"^([Bb]oss\\d+)([ABC])$" options:0 error:NULL] firstMatchInString:track options:0 range:NSMakeRange(0, track.length)];
    if (!m) { LOG(@"stage music: %@ stage event %d, current track '%@' isn't a boss stage track: left", level, eEvent, now); return; }
    NSString *fam = [track substringWithRange:[m rangeAtIndex:1]], *at = [track substringWithRange:[m rangeAtIndex:2]];
    if (strcmp(step, "Kill") && [at compare:@(step)] != NSOrderedAscending) { LOG(@"stage music: '%@' is already at or past %s", now, step); return; }   // only ever forward
    NSString *want = [fam stringByAppendingString:@(step)];
    if (![[NSBundle mainBundle] pathForResource:want ofType:@"mp3"]) { LOG(@"stage music: no %@.mp3 in the game: left", want); return; }
    if (!playTrack(want, @"stage music")) return;
    LOG(@"stage music: %@ stage event %d: '%@' -> '%@' (the arena has no music of its own for it)", level, eEvent, now, want);
}
static int localByteArg(void *stack) {                      // a call's first argument, when it's a local variable
    uint8_t *arg = *(uint8_t **)((uint8_t *)stack + FFRAME_CODE) + 8;
    if (arg[0] != 0x00) return -1;
    uint8_t *prop; memcpy(&prop, arg + 1, sizeof prop);
    uint8_t *locals = *(uint8_t **)((uint8_t *)stack + 0x30);
    return prop && locals ? *(locals + *(int *)(prop + 0x7c)) : -1;
}

// ---- 4h. A stage change held back by a daze is made when the hold ends (FIXES.md 43; release 12) ----
// A boss checks for its next stage only when a hit lands (SwordBoss.CheckForStageTransition: after each sword hit, stab
// and spell), and while it's dazed (IdleIndex 2) not in the first 60% of the daze (until DizzyTransitionTime), so a boss
// knocked below its stage's share of health inside that window fought on in the old stage until another hit landed.
// A check held back like that is made again as soon as the hold ends, as a hit landing then would. Every check made
// below the mark is logged.
typedef struct { int health, mark, stage, stages, idle; float dizzyUntil, now; } BossStage;
static float worldTime(void) {
    uint8_t *wi = WORLD_INFO();
    int o = wi ? poff(CLS(wi), "TimeSeconds") : -1;
    return o >= 0 ? *(float *)(wi + o) : 0;
}
static BOOL bossStage(void *boss, BossStage *s) {                // NO for anything but a boss (the hero has the check too)
    void *cls = CLS(boss); uint8_t *b = boss;
    int oM = poff(cls, "StageTransitionHealth");
    if (oM < 0) return NO;
    int oH = poff(cls, "Health"), oS = poff(cls, "CurrentStage"), oI = poff(cls, "IdleIndex"), oD = poff(cls, "DizzyTransitionTime"), oB = poff(cls, "BattleStages");
    if (oH < 0 || oS < 0 || oI < 0 || oD < 0 || oB < 0) return NO;
    s->health = *(int *)(b + oH); s->mark = *(int *)(b + oM); s->stage = b[oS]; s->idle = b[oI];
    s->stages = *(int *)(b + oB + 8);                           // BattleStages: a TArray (data, count, max)
    s->dizzyUntil = *(float *)(b + oD); s->now = worldTime();
    return YES;
}
static ObjRef gHeldBoss; static float gHeldUntil;
static void stageChecked(void *boss, const BossStage *b) {
    BossStage a;
    if (b->health <= 0 || b->health > b->mark || b->stage >= b->stages - 1 || !bossStage(boss, &a)) return;   // above the mark, or the last stage: nothing to say
    BOOL held = a.stage == b->stage && b->idle == 2 && b->now < b->dizzyUntil;
    LOG(@"stage check: boss health %d, next stage at %d or less: stage %d -> %d%@", b->health, b->mark, b->stage, a.stage,
        held ? [NSString stringWithFormat:@", held back by a daze until %.1f s of game time (now %.1f)", b->dizzyUntil, b->now] : @"");
    if (held) { gHeldBoss = (ObjRef){ boss, *(int *)((uint8_t *)boss + 0x38), CLS(boss) }; gHeldUntil = b->dizzyUntil; }
}
static void heldStageTick(void) {                               // each frame (the camera's update)
    if (!gHeldBoss.obj) return;
    BossStage s;
    if (!refLive(&gHeldBoss) || !bossStage(gHeldBoss.obj, &s) || s.health <= 0 || s.health > s.mark || s.stage >= s.stages - 1) { gHeldBoss.obj = NULL; return; }   // gone, or a hit changed it
    if (s.now < gHeldUntil) return;
    void *boss = gHeldBoss.obj, *fn = findFunction(boss, "CheckForStageTransition"); gHeldBoss.obj = NULL;
    if (!fn) return;
    uint8_t parms[16] = {0}; processEvent(boss, fn, parms);
    BossStage a; bossStage(boss, &a);
    LOG(@"stage check: the daze hold ended with the boss below its mark (health %d, next stage at %d or less): checked again, stage %d -> %d", s.health, s.mark, s.stage, a.stage);
}

// ---- 4i. Effect cues in films: watched (test builds), never played (FIXES.md 48, 53) ----
// Playing a cue that "didn't come" put the knight's attack effects into every fight's cutscenes (the game deliberately
// leaves his combat cues out of films) and doubled cues under fast-forward, so test builds only log a cue that didn't
// come, and real builds don't watch at all (the cause of the missing cues: 4m).
// A film plays a character's animation, and the animation's AnimNotify_FX cues ask the character for its effects
// (SwordPawn.PlayFX). Every cue of every film (filmcues.h, from the levels' own data by tools/filmcues.py) is checked:
// once a film has played half a second past a cue and the character hasn't asked for that effect since just before it,
// it is logged. Not when the film jumped over the cue (the engine skips cues on a jump), and not when the character is
// hidden and isn't being drawn (the cue skips then too: bSkipIfOwnerIsHidden).
// The cue's own code, UAnimNotify_FX::Notify(UAnimNodeSequence *), 0x1009248ac in slot 0x250 of the class's vtable
// (0x100b91f50): mesh = seq+0x88, character = mesh+0x78; skipped when bSkipIfOwnerIsHidden (this+0x64 bit 0, on by
// default) and the character's bHidden (+0xe8 bit 1) or the mesh's HiddenGame (+0x17c bit 2); then AnimPlayFX. Every
// skip is logged.
typedef struct { const char *level, *film, *group; float t; int fx; } FilmCue;
static const FilmCue kFilmCues[] = {
#include "filmcues.h"
};
enum { kNumFilmCues = sizeof kFilmCues / sizeof *kFilmCues };
typedef struct { ObjRef ref; int first, n; float lastPos; uint64_t done; } CueFilm;   // a playing film with cues
static CueFilm gCueFilms[16]; static int gNumCueFilms;
static ObjRef gNoCues[32]; static int gNoCuesAt;                // playing films found to have none (not looked up again)

__attribute__((unused)) static int intArg(void *stack) {                                // a call's first argument: a variable, or a constant
    uint8_t *arg = *(uint8_t **)((uint8_t *)stack + FFRAME_CODE) + 8;
    uint8_t *prop; memcpy(&prop, arg + 1, sizeof prop);
    switch (arg[0]) {
        case 0x00: { uint8_t *locals = *(uint8_t **)((uint8_t *)stack + 0x30);                     // EX_LocalVariable
                     return prop && locals ? *(int *)(locals + *(int *)(prop + 0x7c)) : -1; }
        case 0x01: { uint8_t *obj = *(uint8_t **)((uint8_t *)stack + 0x20);                        // EX_InstanceVariable
                     return prop && obj ? *(int *)(obj + *(int *)(prop + 0x7c)) : -1; }
        case 0x1D: { int v; memcpy(&v, arg + 1, 4); return v; }  // EX_IntConst
        case 0x2C: return arg[1];                                  // EX_IntConstByte
        case 0x25: return 0;                                       // EX_IntZero
        case 0x26: return 1;                                       // EX_IntOne
        default: return -1;
    }
}
static int filmCueRange(uint8_t *film, int *first) {          // the table's rows for this film (sorted by level, film)
    uint8_t *top = film; while (*(uint8_t **)(top + 0x40)) top = *(uint8_t **)(top + 0x40);
    char level[64], name[64];
    if (![ibfix_objname(top) getCString:level maxLength:sizeof level encoding:NSUTF8StringEncoding] ||
        ![ibfix_objname(film) getCString:name maxLength:sizeof name encoding:NSUTF8StringEncoding]) return 0;
    int lo = 0, hi = kNumFilmCues;
    while (lo < hi) {                                           // first row not before (level, name)
        int mid = (lo + hi) / 2, c = strcmp(kFilmCues[mid].level, level);
        if (!c) c = strcmp(kFilmCues[mid].film, name);
        if (c < 0) lo = mid + 1; else hi = mid;
    }
    int n = 0;
    while (lo + n < kNumFilmCues && !strcmp(kFilmCues[lo + n].level, level) && !strcmp(kFilmCues[lo + n].film, name)) n++;
    *first = lo;
    return MIN(n, 64);                                          // (49 at most)
}
static uint8_t *groupActor(uint8_t *film, const char *group) {  // the actor a playing film drives as that group
    void *fcls = CLS(film); int oGI = poff(fcls, "GroupInst");
    struct { uint8_t **data; int num, max; } *gi = (void *)(film + oGI);
    if (oGI < 0 || gi->num <= 0 || gi->num > 64) return NULL;
    for (int i = 0; i < gi->num; i++) {
        uint8_t *inst = gi->data[i]; if (!inst) continue;
        void *icls = CLS(inst); int oG = poff(icls, "Group"), oA = poff(icls, "GroupActor");
        if (oG < 0 || oA < 0) continue;
        uint8_t *g = *(uint8_t **)(inst + oG);
        if (g && [ibfix_objname(g) isEqualToString:@(group)]) return *(uint8_t **)(inst + oA);
    }
    return NULL;
}
static float filmWindow(uint8_t *film) {                        // how far a cue may come after its time: a step under
    int oR = poff(CLS(film), "PlayRate");         // fast-forward is up to 0.4 s of game time
    float rate = oR >= 0 ? *(float *)(film + oR) : 1;
    return 0.5f * MAX(1.0f, MIN(rate, 4.0f));
}
static NSString *hiddenUndrawn(uint8_t *actor) {               // why the cue would skip it, if it isn't being drawn
    void *cls = CLS(actor);
    int oH = poff(cls, "bHidden"), oM = poff(cls, "Mesh");
    uint8_t *mesh = oM >= 0 ? *(uint8_t **)(actor + oM) : NULL;
    void *mcls = mesh ? CLS(mesh) : NULL;
    BOOL hidden = oH == 0xe8 && (*(uint32_t *)(actor + 0xe8) & 2), meshHidden = mesh && poff(mcls, "HiddenGame") == 0x17c && (mesh[0x17c] & 4);
    if (!hidden && !meshHidden) return nil;
    int oL = mesh ? poff(mcls, "LastRenderTime") : -1;
    float ago = oL >= 0 ? worldTime() - *(float *)(mesh + oL) : 99;
    if (ago < 0.3f) return nil;                                 // marked hidden, yet drawn a moment ago
    return [NSString stringWithFormat:@"%@ hidden, not drawn for %.1f s", hidden ? @"the character is" : @"its mesh is", ago];
}
static void playMissedCue(CueFilm *c, const FilmCue *q, float pos) {
    uint8_t *actor = groupActor(c->ref.obj, q->group);
    void *fn = actor ? findFunction(actor, "PlayFX") : NULL;
    int oScale = fn ? poff(fn, "PSScale") : -1, size = fn ? *(uint16_t *)((uint8_t *)fn + 0xe2) : 0;
    if (!actor || !fn || oScale < 0 || size > 128 || poff(CLS(actor), "FXArray") < 0) {
        LOG(@"film cue: %s %s effect %d at %.2f s didn't come, and can't be played (%@)", q->level, q->film, q->fx, q->t,
            !actor ? @"no actor in its group" : @"not a character with effects");
        return;
    }
    NSString *hid = hiddenUndrawn(actor);
    if (hid) { LOG(@"film cue: %s %s effect %d at %.2f s didn't come; left, as the cue would (%@)", q->level, q->film, q->fx, q->t, hid); return; }
    // Watching only (FIXES.md 53): playing the effect here put the knight's combat effects into cutscenes (above).
    LOG(@"film cue: %s %s effect %d at %.2f s didn't come from the game (film at %.2f s, %@); not played (watching only)", q->level, q->film,
        q->fx, q->t, pos, ibfix_objname(actor));
}
__attribute__((unused)) static void filmCueAsked(void *actor, int fx) {                 // a character asked for an effect (PlayFX)
    for (int i = 0; i < gNumCueFilms; i++) {
        CueFilm *c = &gCueFilms[i];
        if (!refLive(&c->ref)) continue;
        int oPos = poff(c->ref.cls, "Position"); if (oPos < 0) continue;
        float pos = *(float *)(c->ref.obj + oPos), win = filmWindow(c->ref.obj);
        for (int k = 0; k < c->n; k++) {
            const FilmCue *q = &kFilmCues[c->first + k]; uint64_t bit = 1ULL << k;
            if (q->fx != fx || (c->done & bit) || pos < q->t - 0.1f || pos > q->t + win + 0.05f) continue;
            if (groupActor(c->ref.obj, q->group) != actor) continue;
            c->done |= bit;
#ifdef IBFIX_SNAPS
            LOG(@"film cue: %s %s effect %d at %.2f s came from the game (film at %.2f s)", q->level, q->film, fx, q->t, pos);
#endif
            return;
        }
    }
}
__attribute__((unused)) static void filmCueTick(void) {                                 // each frame (the camera's update, after the films moved)
    for (int i = 0; i < gNumCueFilms; ) {
        CueFilm *c = &gCueFilms[i];
        int oGI = refLive(&c->ref) ? poff(c->ref.cls, "GroupInst") : -1, oPos = poff(c->ref.cls, "Position");
        if (oGI < 0 || oPos < 0 || *(int *)(c->ref.obj + oGI + 8) <= 0) { *c = gCueFilms[--gNumCueFilms]; continue; }   // stopped, or gone
        float pos = *(float *)(c->ref.obj + oPos), win = filmWindow(c->ref.obj);
        if (pos < c->lastPos - 0.05f) c->done = 0;              // rewound or looped: its cues can come again
        else if (c->lastPos >= 0 && pos > c->lastPos)
            for (int k = 0; k < c->n; k++) {
                const FilmCue *q = &kFilmCues[c->first + k]; uint64_t bit = 1ULL << k;
                float due = q->t + win;
                if ((c->done & bit) || c->lastPos >= due || pos < due) continue;
                c->done |= bit;
                if (pos - c->lastPos > win + 0.1f || c->lastPos < q->t - 0.5f) continue;   // jumped over it: no cue then
                playMissedCue(c, q, pos);
            }
        c->lastPos = pos; i++;
    }
    for (int f = 0; f < gNumFilms; f++) {                       // films that have started playing
        Film *fl = &gFilms[f];
        if (!refLive(&fl->ref)) continue;
        int oGI = poff(fl->ref.cls, "GroupInst");
        if (oGI < 0 || *(int *)(fl->ref.obj + oGI + 8) <= 0) continue;
        BOOL known = NO;
        for (int i = 0; i < gNumCueFilms && !known; i++) known = gCueFilms[i].ref.obj == fl->ref.obj && gCueFilms[i].ref.idx == fl->ref.idx;
        for (int i = 0; i < 32 && !known; i++) known = gNoCues[i].obj == fl->ref.obj && gNoCues[i].idx == fl->ref.idx && refLive(&gNoCues[i]);
        if (known) continue;
        int first, n = filmCueRange(fl->ref.obj, &first);
        if (!n || gNumCueFilms == 16) { gNoCues[gNoCuesAt++ & 31] = fl->ref; continue; }
        gCueFilms[gNumCueFilms++] = (CueFilm){ fl->ref, first, n, -1, 0 };
#ifdef IBFIX_SNAPS
        LOG(@"film cue: watching %s %s, %d cues", kFilmCues[first].level, kFilmCues[first].film, n);
#endif
    }
}

// ---- 4m. Cutscene cues always fire (FIXES.md 59; every build) ----
// Every animation cue in a cutscene (footsteps, shouts, screams, the God King's flames and sword glow) could go missing,
// more often the longer a session ran: SwordPawn.PlayAnim sets the FullBodySlot node's NotifyWeightThreshold to 0
// ("cues always fire"), SwordPawn.StopAnim, for moves with bNoNotifiesOnBlendOut, to 1.0 ("only at full blend"), and
// the cutscenes (Matinee's AnimControl tracks), playing on the same nodes, never set it back, so once a fight move had
// left a node at 1.0, a cutscene on it fired only the cues where its weight is exactly 1. So when a cutscene drives a
// node (Pawn.SetAnimPosition -> MAT_SetAnimPosition each frame, its arguments in the caller's frame), the node's
// threshold goes back to 0, as PlayAnim does. The cues fire inside that call only when bFireNotifies is set and the
// node lets them (bNoNotifies; NotifyWeightThreshold against its NodeTotalWeight), through AnimNotify_FX::Notify
// (hooked below). Test builds also log each "Cut_Scene" animation: its node, AnimSeq and the mesh's AnimSets at its
// first call, its state at each cue time and how many cues were called, and the calls with bFireNotifies off.
static NSString *fnameStr(int idx) {
    struct { uint8_t **data; int num, max; } *names = (void *)(IB1_GNAMES + _dyld_get_image_vmaddr_slide(0));
    if (idx < 0 || idx >= names->num || !names->data[idx]) return @"?";
    const uint8_t *e = names->data[idx];
    return (e[0] & 1) ? @"(wide)" : ([NSString stringWithUTF8String:(const char *)(e + 0x10)] ?: @"?");
}
static BOOL plausibleObj(const uint8_t *p) {                  // a live object, checked before anything is read from it
    return isLiveObject(p);                                  // (its index read by the kernel: FIXES.md 90)
}
typedef struct { uint8_t *data; int num, max; } RawArr;      // TArray of structs; AnimBlendChild and AnimNotifyEvent are
enum { kStructStride = 32 };                                 // 32 bytes, with their object pointer at +8
static NSString *objPath(uint8_t *o) {
    NSString *s = ibfix_objname(o);
    for (uint8_t *u = plausibleObj(o) ? *(uint8_t **)(o + 0x40) : NULL; u && plausibleObj(u); u = *(uint8_t **)(u + 0x40))
        s = [NSString stringWithFormat:@"%@.%@", ibfix_objname(u), s];
    return s;
}
static int gAnimCuesCalled = -1;                             // -1: not inside a watched call
typedef struct { void *pawn; int anim; float last; int calls, noFire; BOOL said; } AnimWatch;
static AnimWatch gAnimW[8];
static uint8_t *animSlotSeq(uint8_t *pawn, int slotName, int channel) {
    int oSlots = poff(CLS(pawn), "SlotNodes");
    if (oSlots < 0) return NULL;
    RawArr *slots = (void *)(pawn + oSlots);
    for (int i = 0; i < slots->num && i < 16; i++) {
        uint8_t *slot = ((uint8_t **)slots->data)[i];
        if (!plausibleObj(slot)) continue;
        int oN = poff(CLS(slot), "NodeName"), oCh = poff(CLS(slot), "Children");
        if (oN < 0 || oCh < 0 || *(int *)(slot + oN) != slotName) continue;
        RawArr *ch = (void *)(slot + oCh);
        if (channel + 1 >= ch->num) return NULL;
        uint8_t *seq = *(uint8_t **)(ch->data + (size_t)(channel + 1) * kStructStride + 8);
        return plausibleObj(seq) && isClass(seq, "AnimNodeSequence") ? seq : NULL;
    }
    return NULL;
}
static NSString *animSeqState(uint8_t *seq, uint8_t *mesh, double now) {
    void *c = CLS(seq);
    int oCur = poff(c, "CurrentTime"), oPrev = poff(c, "PreviousTime"), oW = poff(c, "NodeTotalWeight"), oThr = poff(c, "NotifyWeightThreshold"),
        oNo = poff(c, "bNoNotifies"), oPl = poff(c, "bPlaying");
    int oLR = mesh ? poff(CLS(mesh), "LastRenderTime") : -1, oUp = mesh ? poff(CLS(mesh), "bUpdateSkelWhenNotRendered") : -1;
    return [NSString stringWithFormat:@"node at %.3f (before %.3f), weight %.2f (cue threshold %.2f), flags bNoNotifies word 0x%08x bPlaying word 0x%08x | mesh drawn %.2f s ago, update flags 0x%08x",
            oCur >= 0 ? *(float *)(seq + oCur) : -1, oPrev >= 0 ? *(float *)(seq + oPrev) : -1, oW >= 0 ? *(float *)(seq + oW) : -1,
            oThr >= 0 ? *(float *)(seq + oThr) : -1, oNo >= 0 ? *(uint32_t *)(seq + oNo) : 0, oPl >= 0 ? *(uint32_t *)(seq + oPl) : 0,
            oLR >= 0 ? now - *(float *)(mesh + oLR) : -1, oUp >= 0 ? *(uint32_t *)(mesh + oUp) : 0];
}
// The SetAnimPosition frame's arguments (offsets read once from the function)
static void *gFnSAP; static int gOSlot = -1, gOChan = -1, gOName = -1, gOPos = -1, gOFire = -1;
static BOOL sapArgs(void *stack) {
    void *fn = *(void **)((uint8_t *)stack + 0x18);
    if (!fn || !*(uint8_t **)((uint8_t *)stack + 0x30)) return NO;
    if (fn != gFnSAP) {
        if (![ibfix_objname(fn) isEqualToString:@"SetAnimPosition"]) return NO;
        gFnSAP = fn; gOSlot = propertyOffset(fn, "SlotName"); gOChan = propertyOffset(fn, "ChannelIndex"); gOName = propertyOffset(fn, "InAnimSeqName");
        gOPos = propertyOffset(fn, "InPosition"); gOFire = propertyOffset(fn, "bFireNotifies");
        LOG(@"cutscene cues: SetAnimPosition's arguments at %d %d %d %d %d", gOSlot, gOChan, gOName, gOPos, gOFire);
    }
    return gOSlot >= 0 && gOChan >= 0 && gOName >= 0;
}
static void cutsceneCueThreshold(void *self, void *stack) {
    if (!self || !sapArgs(stack)) return;
    uint8_t *loc = *(uint8_t **)((uint8_t *)stack + 0x30);
    uint8_t *seq = animSlotSeq(self, *(int *)(loc + gOSlot), *(int *)(loc + gOChan));
    int oThr = seq ? poff(CLS(seq), "NotifyWeightThreshold") : -1;
    if (oThr < 0 || *(float *)(seq + oThr) == 0) return;
    static int n; if (++n <= 20 || n % 50 == 0)
        LOG(@"cutscene cues: %@ on %@: cue threshold %.2f (left by a fight move's blend-out) set to 0, so its cues fire (%d)",
            fnameStr(*(int *)(loc + gOName)), ibfix_objname(self), *(float *)(seq + oThr), n);
    *(float *)(seq + oThr) = 0;
}
// Looping scene animations loop (FIXES.md 85; IB2's FIXES.md 25, the same engine): a scene (Matinee) gives a character
// its own time through Pawn.SetAnimPosition -> MAT_SetAnimPosition, and for a character the scene's AnimSets don't name
// (a spawned boss, its "Boss" group) neither the scene nor the engine wraps that time round a looping animation's
// length, so a waiting boss froze on the last frame until the scene looped. The arguments are Pawn.SetAnimPosition's
// locals, read by the native when it runs, so for a looping key past the end of the animation the node already plays
// (AnimSeqName; its AnimSeq's SequenceLength), the time handed on is wrapped round the length first. The engine then
// moves the animation on as a loop and fires each cue once per pass (none in the frame that wraps), as IB2 found.
static int gOLoop = -1; static uint32_t gLoopMask;
static BOOL boolProp(void *structp, const char *name, int *off, uint32_t *mask);
static void loopWrap(void *self, void *stack) {
    if (!self || !sapArgs(stack) || gOPos < 0) return;
    if (gOLoop == -1 && !boolProp(gFnSAP, "bLooping", &gOLoop, &gLoopMask)) gOLoop = -2;
    if (gOLoop < 0) return;
    uint8_t *loc = *(uint8_t **)((uint8_t *)stack + 0x30);
    if (!(*(uint32_t *)(loc + gOLoop) & gLoopMask)) return;
    float pos = *(float *)(loc + gOPos);
    if (pos <= 0) return;
    uint8_t *node = animSlotSeq(self, *(int *)(loc + gOSlot), *(int *)(loc + gOChan));
    void *nc = node ? CLS(node) : NULL;
    int oName = nc ? poff(nc, "AnimSeqName") : -1, oSeq = nc ? poff(nc, "AnimSeq") : -1;
    if (oName < 0 || oSeq < 0 || *(int *)(node + oName) != *(int *)(loc + gOName)) return;   // not that animation yet
    uint8_t *seq = *(uint8_t **)(node + oSeq);
    int oLen = plausibleObj(seq) ? poff(CLS(seq), "SequenceLength") : -1;
    float len = oLen >= 0 ? *(float *)(seq + oLen) : 0;
    if (len < 0.05f || pos <= len + 0.001f) return;
    float wrapped = fmodf(pos, len);
    *(float *)(loc + gOPos) = wrapped;
    static void *lastPawn; static int lastAnim, n;
    n++;
    if (self != lastPawn || *(int *)(loc + gOName) != lastAnim || n % 600 == 0) {
        lastPawn = self; lastAnim = *(int *)(loc + gOName);
        LOG(@"scene animations: %@'s %@ at %.2f s of a %.2f s looping animation: given to the engine at %.2f (%d)",
            ibfix_objname(self), fnameStr(lastAnim), pos, len, wrapped, n);
    }
}
#ifdef IBFIX_SNAPS
// called for MAT_SetAnimPosition: the caller's frame is Pawn.SetAnimPosition, whose locals hold the arguments
static BOOL animWatchCall(void *self, void *stack, void *result) {
    if (!self || !sapArgs(stack) || gOPos < 0 || gOFire < 0) return NO;
    uint8_t *loc = *(uint8_t **)((uint8_t *)stack + 0x30);
    int oSlot = gOSlot, oChan = gOChan, oName = gOName, oPos = gOPos, oFire = gOFire;
    int anim = *(int *)(loc + oName);
    static NSMutableDictionary<NSNumber *, NSNumber *> *isCut;
    if (!isCut) isCut = [NSMutableDictionary dictionary];
    NSNumber *k = @(anim);
    if (!isCut[k]) isCut[k] = @([fnameStr(anim) hasPrefix:@"Cut_Scene"]);
    if (![isCut[k] boolValue]) return NO;
    float pos = *(float *)(loc + oPos); BOOL fire = (*(uint32_t *)(loc + oFire) & 1) != 0;
    int slotName = oSlot >= 0 ? *(int *)(loc + oSlot) : -1, chan = oChan >= 0 ? *(int *)(loc + oChan) : 0;
    AnimWatch *w = NULL;
    for (int i = 0; i < 8 && !w; i++) if (gAnimW[i].pawn == self && gAnimW[i].anim == anim) w = &gAnimW[i];
    if (!w) {                                                 // a new animation for this character: the oldest slot goes
        static int next; w = &gAnimW[next++ & 7];
        if (w->pawn && w->noFire) LOG(@"cutscene cues: %@ on %@: %d of %d calls had bFireNotifies off", fnameStr(w->anim), ibfix_objname(w->pawn), w->noFire, w->calls);
        *w = (AnimWatch){ self, anim, -1, 0, 0, NO };
    }
    float before = w->last;
    gAnimCuesCalled = 0;
    ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
    int cues = gAnimCuesCalled; gAnimCuesCalled = -1;
    w->calls++; if (!fire) w->noFire++;
    if (!fire && w->noFire == 1) LOG(@"cutscene cues: %@ on %@ at %.3f: bFireNotifies OFF (first such call)", fnameStr(anim), ibfix_objname(self), pos);
    if (pos < before - 0.001f) LOG(@"cutscene cues: %@ on %@ went back from %.3f to %.3f (bFireNotifies %d)", fnameStr(anim), ibfix_objname(self), before, pos, fire);
    w->last = pos;
    uint8_t *pawn = self;
    int oMesh = poff(CLS(pawn), "Mesh");
    uint8_t *mesh = oMesh >= 0 ? *(uint8_t **)(pawn + oMesh) : NULL;
    if (mesh && !plausibleObj(mesh)) mesh = NULL;
    uint8_t *wi = WORLD_INFO();
    int oTS = wi ? poff(CLS(wi), "TimeSeconds") : -1;
    double now = oTS >= 0 ? *(float *)(wi + oTS) : 0;
    uint8_t *seq = animSlotSeq(pawn, slotName, chan);
    int oAS = seq ? poff(CLS(seq), "AnimSeq") : -1;
    uint8_t *as = oAS >= 0 ? *(uint8_t **)(seq + oAS) : NULL;
    if (as && !plausibleObj(as)) as = NULL;
    int oNot = as ? poff(CLS(as), "Notifies") : -1;
    RawArr *nots = oNot >= 0 ? (void *)(as + oNot) : NULL;
    if (!w->said) {
        w->said = YES;
        NSMutableString *times = [NSMutableString string];
        for (int i = 0; nots && i < nots->num && i < 16; i++) {
            uint8_t *e = nots->data + (size_t)i * kStructStride; uint8_t *nf = *(uint8_t **)(e + 8);
            [times appendFormat:@" %.2f(%@%@)", *(float *)e, plausibleObj(nf) ? ibfix_objname(CLS(nf)) : @"?",
                plausibleObj(nf) && isClass(nf, "AnimNotify_FX") ? [NSString stringWithFormat:@" %d", *(int *)(nf + 0x68)] : @""];
        }
        NSMutableString *sets = [NSMutableString string];
        int oSets = mesh ? poff(CLS(mesh), "AnimSets") : -1;
        RawArr *sa = oSets >= 0 ? (void *)(mesh + oSets) : NULL;
        for (int i = 0; sa && i < sa->num && i < 24; i++) [sets appendFormat:@" %@", objPath(((uint8_t **)sa->data)[i])];
        LOG(@"cutscene cues: %@ on %@ starts at %.3f (slot %@ channel %d, bFireNotifies %d): playing %@ with %d cue(s):%@ | %@ | mesh AnimSets (%d):%@",
            fnameStr(anim), ibfix_objname(self), pos, fnameStr(slotName), chan, fire, as ? objPath(as) : @"no AnimSeq", nots ? nots->num : -1, times,
            seq ? animSeqState(seq, mesh, now) : @"no slot node", sa ? sa->num : -1, sets);
    }
    for (int i = 0; nots && i < nots->num && i < 16; i++) {
        float t = *(float *)(nots->data + (size_t)i * kStructStride);
        if (before >= 0 && before < t && t <= pos)
            LOG(@"cutscene cues: %@ on %@ passed its cue at %.3f (from %.3f to %.3f): bFireNotifies %d, cues called in this call %d | %@",
                fnameStr(anim), ibfix_objname(self), t, before, pos, fire, cues, seq ? animSeqState(seq, mesh, now) : @"no slot node");
    }
    return YES;
}
#endif
#define IB1_FXNOTIFY_SLOT 0x100b921a0ULL
#define IB1_FXNOTIFY_FN   0x1009248acULL
static void (*gOrigFXNotify)(void *self, void *seq);
static void my_fxNotify(void *self, void *seq) {
    uint8_t *mesh = seq ? *(uint8_t **)((uint8_t *)seq + 0x88) : NULL, *owner = mesh ? *(uint8_t **)(mesh + 0x78) : NULL;
#ifdef IBFIX_SNAPS
    if (gAnimCuesCalled >= 0) {
        gAnimCuesCalled++;
        LOG(@"cutscene cues: effect cue %d called for %@ (%@)", *(int *)((uint8_t *)self + 0x68), ibfix_objname(owner),
            ((((uint8_t *)self)[0x64] & 1) && owner && ((*(uint32_t *)(owner + 0xe8) & 2) || (mesh[0x17c] & 4))) ? @"hidden: the game skips it" : @"shown");
    }
#endif
    if (owner && (((uint8_t *)self)[0x64] & 1) && ((*(uint32_t *)(owner + 0xe8) & 2) || (mesh[0x17c] & 4))) {
        static CFAbsoluteTime last; static int quiet;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - last > 2) { LOG(@"effect cue %d for %@ skipped by the game: %@ hidden%@", *(int *)((uint8_t *)self + 0x68), ibfix_objname(owner),
                                (*(uint32_t *)(owner + 0xe8) & 2) ? @"the character is" : @"its mesh is",
                                quiet ? [NSString stringWithFormat:@" (and %d more since)", quiet] : @""); last = t; quiet = 0; }
        else quiet++;
    }
    gOrigFXNotify(self, seq);
}
static void hookFXNotify(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **slot = (void **)(IB1_FXNOTIFY_SLOT + slide);
    if (*slot != (void *)(IB1_FXNOTIFY_FN + slide)) { LOG(@"effect cue log OFF: vtable not as expected"); return; }
    gOrigFXNotify = (void (*)(void *, void *))*slot; *slot = (void *)my_fxNotify;
}

// ---- 4n. Spell symbols: a tie goes to the symbol drawn most faithfully (FIXES.md 61; every build) ----
// The game (FindClosestSignature 0x10092a87c) scores a drawing against each of the ring's symbols by edit distance over
// MaxError, each symbol also drawn backwards, and on equal scores the first in the ring's list wins: a square U is as
// close to poison drawn backwards as to heal, and the Fire Circle lists poison first. Here a tie goes to the symbol with
// fewer lines at the wrong angle, then the one drawn the right way round, then the game's order.
// Just after SwordPC.CanPlayerCastMagic (the controller's ProcessEvent: slot 0x208 of ASwordPC's own vtable 0x100b86960,
// the last its constructor writes, not AActor's), the drawing is scored again with the game's rules (checked against the
// distances the game stores) and the winner moved just in front of the game's pick for that touch's handling
// (UMobileInputZoneGesture::ProcessTouch, slot 0x260 of 0x100b85a30), so the game picks it itself; the order is put
// back after. tools/spellcheck.py compiles this code for the Mac and replays its log lines.
#define IB1_GESTURE_TOUCH_SLOT 0x100b85c90ULL
#define IB1_GESTURE_TOUCH_FN   0x10092a23cULL
#define IB1_SWORDPC_PE_SLOT    0x100b86b68ULL
#define IB1_ACTOR_PROCESSEVENT 0x1002a0ce8ULL
enum { kZoneOwner = 0x168, kZoneLog = 0x208, kZoneGestures = 0x218, kZoneEliminate = 0x228, kGestureSize = 0x48,
       kSpellLen = 64, kSpellMany = 16 };                    // longer drawings or symbols, more symbols: left to the game
static const float kEliminateAtLeast = 0.01f;                // the game's floor for EliminateStrokePercent (0x1009eb7b4)
typedef struct { float x, y; } Vec2;
typedef uint64_t (*GestureTouchFn)(void *self, float dt, uint32_t handle, int event, Vec2 at, float a, float b, float c);
static GestureTouchFn gOrigGestureTouch;
static void (*gOrigPCProcessEvent)(void *, void *, void *, void *);
static void *gCanCastFn;
static _Thread_local uint8_t *gSpellZone;                    // the zone whose finger just lifted, while it's handled
static int gSpellUpdates; static double gSpellTouchStart;      // finger updates since it touched down, and when
static BOOL gSpellOff;
typedef struct { int dist, lines, back; } SpellFit;          // distance; lines at the wrong angle; matched backwards
static struct { uint8_t *zone, *data; int num, gw, pick; SpellFit fit[kSpellMany]; uint64_t key[kSpellMany]; } gSpellCast;

// LevenshteinDistance::Calculate (0x10092a020) with the gesture class's own check that the drawing starts within 45
// degrees of the symbol's start (0x100935914), plus the fewest lines at the wrong angle along a cheapest match.
static int spellDist(const uint8_t *t, int n, const uint8_t *s, int m, int off, int rep, int ext, int mis, int *lines) {
    int d0 = (int)t[0] - (int)s[off]; if (d0 < 0) d0 = -d0;
    int w = 8 - d0; *lines = 0;
    if ((w <= d0 ? w : d0) > 1) return INT_MAX;
    int cost[kSpellLen + 1], rp[kSpellLen + 1], nc[kSpellLen + 1], nr[kSpellLen + 1];
    for (int j = 0; j <= n; j++) { cost[j] = ext * j; rp[j] = 0; }
    for (int i = 1; i <= m; i++) {
        uint8_t c = s[(off + i - 1) % m];
        nc[0] = mis * i; nr[0] = 0;
        for (int j = 0; j < n; j++) {
            if (c == t[j]) { nc[j + 1] = cost[j]; nr[j + 1] = rp[j]; continue; }
            int bc = cost[j] + rep, br = rp[j] + 1;                                                     // at the wrong angle
            if (nc[j] + ext < bc || (nc[j] + ext == bc && nr[j] < br)) { bc = nc[j] + ext; br = nr[j]; }  // an extra piece
            if (cost[j + 1] + mis < bc || (cost[j + 1] + mis == bc && rp[j + 1] < br)) { bc = cost[j + 1] + mis; br = rp[j + 1]; }  // a missing one
            nc[j + 1] = bc; nr[j + 1] = br;
        }
        memcpy(cost, nc, sizeof(int) * (n + 1)); memcpy(rp, nr, sizeof(int) * (n + 1));
    }
    *lines = rp[n];
    return cost[n];
}
// A symbol (FGestureDefinition: InputKey +0, Signature +8, AssetName +0x18, bLoops/bReverses bits at +0x2c, Replace/
// Extra/MissingError +0x30/+0x34/+0x38 (0 = 1), MaxError +0x3c, LevenshteinDist +0x40) against the drawing t (ti: it
// reversed and turned round, as MakeInverse makes it): over every starting point of a looping symbol, both ways round.
static SpellFit spellFit(const uint8_t *t, const uint8_t *ti, int n, const uint8_t *g) {
    const uint8_t *s = *(const uint8_t **)(g + 8); int m = *(const int *)(g + 0x10); uint8_t fl = g[0x2c];
    int rep = *(const int *)(g + 0x30) ?: 1, ext = *(const int *)(g + 0x34) ?: 1, mis = *(const int *)(g + 0x38) ?: 1;
    SpellFit best = { INT_MAX, 0, 0 };
    for (int off = 0; off < ((fl & 1) ? m : 1); off++)
        for (int back = 0; back <= ((fl & 2) ? 1 : 0); back++) {
            int lines, d = spellDist(back ? ti : t, n, s, m, off, rep, ext, mis, &lines);
            if (d < best.dist || (d == best.dist && d < INT_MAX && (lines < best.lines || (lines == best.lines && back < best.back))))
                best = (SpellFit){ d, lines, back };
        }
    return best;
}
static float spellScore(const SpellFit *f, const uint8_t *g) {
    int mx = *(const int *)(g + 0x3c);
    return mx > 0 ? (float)f->dist / (float)mx : 1.0f;
}
static NSString *spellKey(const uint8_t *g) {                // "MagicSlot2" (the name's number is the digit plus 1)
    int num = *(const int *)(g + 4);
    return num ? [NSString stringWithFormat:@"%@%d", fnameStr(*(const int *)g), num - 1] : fnameStr(*(const int *)g);
}
static NSString *spellName(const uint8_t *g) {               // the symbol's glow, B_FX_Magic.Main.PS_Spell_GlowBar_<letter>
    const uint32_t *p = *(const uint32_t * const *)(g + 0x18); int n = *(const int *)(g + 0x20);
    NSString *s = (p && n > 1 && n < 200) ? [[NSString alloc] initWithBytes:p length:(NSUInteger)(n - 1) * 4 encoding:NSUTF32LittleEndianStringEncoding] : nil;
    NSString *tail = [s componentsSeparatedByString:@"."].lastObject;
    NSDictionary *names = @{ @"PS_Spell_GlowBar_O": @"fire", @"PS_Spell_GlowBar_Z": @"lightning", @"PS_Spell_GlowBar_T": @"ice",
                             @"PS_Spell_GlowBar_X": @"poison", @"PS_Spell_GlowBar_A": @"light", @"PS_Spell_GlowBar_V": @"dark",
                             @"PS_Spell_GlowBar_U": @"heal", @"PS_Spell_GlowBar_U2": @"shield" };
    return [NSString stringWithFormat:@"%@ (%@)", (tail ? names[tail] : nil) ?: tail ?: @"?", spellKey(g)];
}

// Just before the game scores the drawing: score it the same way, and settle a tie.
static void spellSettle(uint8_t *zone) {
    RawArr *log = (void *)(zone + kZoneLog), *ges = (void *)(zone + kZoneGestures);
    gSpellCast.zone = NULL;
    if (log->num <= 0 || ges->num <= 0 || ges->num > kSpellMany) return;
    float longest = 0, frac = kEliminateAtLeast;
    for (int i = 0; i < log->num; i++) { float l = *(float *)(log->data + i * 12 + 4); if (longest < l) longest = l; }
    if (frac < *(float *)(zone + kZoneEliminate)) frac = *(float *)(zone + kZoneEliminate);
    uint8_t t[kSpellLen], ti[kSpellLen]; int n = 0; unsigned last = 0xff;
    NSMutableString *strokes = [NSMutableString string];
    for (int i = 0; i < log->num; i++) {
        uint8_t *e = log->data + i * 12;
        if (i < 40) [strokes appendFormat:@" %d:%.0f", e[0] == 0xff ? -1 : e[0], *(float *)(e + 4)];
        if (!(longest * frac < *(float *)(e + 4)) || e[0] == last) continue;
        if (n == kSpellLen) { LOG(@"spells: a drawing of over %d strokes, left to the game", kSpellLen); return; }
        t[n++] = e[0]; last = e[0];
    }
    if (!n) { LOG(@"spells: drawn nothing long enough to read (strokes, direction:length in pixels:%@)", strokes); return; }
    for (int i = 0; i < n; i++) ti[i] = (uint8_t)((t[n - 1 - i] + 4) & 7);
    SpellFit fit[kSpellMany]; BOOL ok[kSpellMany]; float sc[kSpellMany];
    for (int k = 0; k < ges->num; k++) {
        uint8_t *g = ges->data + k * kGestureSize;
        int m = *(int *)(g + 0x10);
        if (m <= 0 || m > kSpellLen || !*(uint8_t **)(g + 8)) { LOG(@"spells: symbol %d has %d pieces, left to the game", k, m); return; }
        fit[k] = spellFit(t, ti, n, g);
        ok[k] = fit[k].dist <= *(int *)(g + 0x3c);
        sc[k] = ok[k] ? spellScore(&fit[k], g) : 0;
    }
    int gw = -1;                                             // the game's pick: the first strictly better, to a perfect one
    for (int k = 0; k < ges->num; k++) if (ok[k] && (gw < 0 || sc[k] < sc[gw])) { gw = k; if (fit[k].dist == 0) break; }
    int pick = gw;
    if (gw >= 0) for (int k = gw + 1; k < ges->num; k++)
        if (ok[k] && sc[k] == sc[gw] && (fit[k].lines < fit[pick].lines || (fit[k].lines == fit[pick].lines && fit[k].back < fit[pick].back))) pick = k;
    NSMutableString *line = [NSMutableString stringWithFormat:@"spells: drawn"];
    for (int i = 0; i < n; i++) [line appendFormat:@" %d", t[i]];
    [line appendString:@" |"];
    for (int k = 0; k < ges->num; k++) {
        uint8_t *g = ges->data + k * kGestureSize;
        if (fit[k].dist == INT_MAX) { [line appendFormat:@" %@ no match;", spellName(g)]; continue; }
        [line appendFormat:@" %@ %d%@%@ of %d;", spellName(g), fit[k].dist, fit[k].back ? @" backwards" : @"",
         fit[k].lines ? [NSString stringWithFormat:@", %d at the wrong angle", fit[k].lines] : @"", *(int *)(g + 0x3c)];
    }
    if (gw < 0) [line appendString:@" -> none close enough"];
    else if (pick == gw) [line appendFormat:@" -> %@", spellName(ges->data + gw * kGestureSize)];
    else [line appendFormat:@" -> %@, not %@: as close, and drawn more faithfully", spellName(ges->data + pick * kGestureSize), spellName(ges->data + gw * kGestureSize)];
    double held = CFAbsoluteTimeGetCurrent() - gSpellTouchStart;
    LOG(@"%@ (finger read %d times in %.2f s, %.0f a second; strokes, direction:length in pixels:%@)", line, gSpellUpdates, held,
        held > 0 ? gSpellUpdates / held : 0, strokes);
    gSpellCast.zone = zone; gSpellCast.data = ges->data; gSpellCast.num = ges->num; gSpellCast.gw = gw; gSpellCast.pick = pick;
    memcpy(gSpellCast.fit, fit, sizeof(SpellFit) * ges->num);
    if (pick != gw) {                                        // the winner just in front of the game's pick, for this touch
        uint8_t tmp[kGestureSize];
        memcpy(tmp, ges->data + pick * kGestureSize, kGestureSize);
        memmove(ges->data + (gw + 1) * kGestureSize, ges->data + gw * kGestureSize, (size_t)(pick - gw) * kGestureSize);
        memcpy(ges->data + gw * kGestureSize, tmp, kGestureSize);
    }
    for (int k = 0; k < ges->num; k++) gSpellCast.key[k] = *(uint64_t *)(ges->data + k * kGestureSize);
}
// After the touch: check our distances against the ones the game stored (in the order it scored), put the order back.
static void spellAfter(void) {
    uint8_t *zone = gSpellCast.zone; gSpellCast.zone = NULL;
    if (!zone) return;
    RawArr *ges = (void *)(zone + kZoneGestures);
    int gw = gSpellCast.gw, pick = gSpellCast.pick, num = gSpellCast.num;
    BOOL same = ges->data == gSpellCast.data && ges->num == num;
    for (int k = 0; same && k < num; k++) same = *(uint64_t *)(ges->data + k * kGestureSize) == gSpellCast.key[k];
    if (!same) { LOG(@"spells: the ring's symbols changed during the cast; their order left as it now is"); return; }
    int upto = (pick >= 0 && gSpellCast.fit[pick].dist == 0) ? gw : num - 1;     // the game stops at a perfect match
    for (int p = 0; p <= upto; p++) {
        int o = (pick == gw || p < gw || p > pick) ? p : p == gw ? pick : p - 1;
        int game = *(int *)(ges->data + p * kGestureSize + 0x40);
        if (game != gSpellCast.fit[o].dist) LOG(@"spells: CHECK FAILED: symbol %d's distance %d here, %d in the game", o, gSpellCast.fit[o].dist, game);
    }
    if (pick != gw) {
        uint8_t tmp[kGestureSize];
        memcpy(tmp, ges->data + gw * kGestureSize, kGestureSize);
        memmove(ges->data + gw * kGestureSize, ges->data + (gw + 1) * kGestureSize, (size_t)(pick - gw) * kGestureSize);
        memcpy(ges->data + pick * kGestureSize, tmp, kGestureSize);
    }
}
static void my_pcProcessEvent(void *obj, void *fn, void *parms, void *res) {
    gOrigPCProcessEvent(obj, fn, parms, res);
    if (!fn || fn != gCanCastFn) return;
    static int asked; if (asked++ < 3) LOG(@"spells: the game asked CanPlayerCastMagic: %@ (a drawing %@)", parms && *(uint32_t *)parms ? @"yes" : @"no", gSpellZone ? @"just finished" : @"not in hand");
    if (gSpellZone && parms && *(uint32_t *)parms) { uint8_t *z = gSpellZone; gSpellZone = NULL; spellSettle(z); }
}
// At each lift, the live controller's own ProcessEvent slot is checked (and hooked too if it uses another vtable).
static void spellCheckPC(uint8_t *pc) {
    static void **checkedVt;
    void **vt = *(void ***)pc;
    if (vt == checkedVt) return;
    checkedVt = vt;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **slot = &vt[VT_PROCESSEVENT / sizeof(void *)];
    if (*slot == (void *)my_pcProcessEvent) LOG(@"spells: the controller's ProcessEvent is hooked (vtable %#lx)", (unsigned long)((uintptr_t)vt - slide));
    else if (*slot == (void *)gOrigPCProcessEvent) { *slot = (void *)my_pcProcessEvent; LOG(@"spells: the controller has another vtable (%#lx): hooked it as well", (unsigned long)((uintptr_t)vt - slide)); }
    else LOG(@"spells: the controller's ProcessEvent is %#lx (vtable %#lx): not hooked", (unsigned long)((uintptr_t)*slot - slide), (unsigned long)((uintptr_t)vt - slide));
}
static uint64_t my_gestureTouch(void *self, float dt, uint32_t handle, int event, Vec2 at, float a, float b, float c) {
    if (gSpellOff) return gOrigGestureTouch(self, dt, handle, event, at, a, b, c);
    static uint32_t seen;                                    // the first of each kind of event, logged once
    if (event >= 0 && event < 8 && !(seen & (1u << event))) { seen |= 1u << event; LOG(@"spells: the magic zone's touch handler first saw event %d (%@)", event, ibfix_objname(CLS(self))); }
    if (event == 0) { gSpellUpdates = 0; gSpellTouchStart = CFAbsoluteTimeGetCurrent(); }
    else if (event == 1 || event == 2) gSpellUpdates++;      // the finger's position, once a frame while it moves
    if (event != 3) return gOrigGestureTouch(self, dt, handle, event, at, a, b, c);   // 3: the finger lifted
    uint8_t *zone = self, *owner = *(uint8_t **)(zone + kZoneOwner), *pc = plausibleObj(owner) ? *(uint8_t **)(owner + 0x40) : NULL;
    if (plausibleObj(pc)) spellCheckPC(pc); else { static int n; if (n++ < 3) LOG(@"spells: no controller found from the zone (owner %p)", owner); }
    static BOOL checked;
    if (!checked) {                                          // the native code's offsets, against the script's own layout
        checked = YES;
        void *cls = CLS(zone);
        if (poff(cls, "InputLog") != kZoneLog || poff(cls, "Gestures") != kZoneGestures || poff(cls, "EliminateStrokePercent") != kZoneEliminate) {
            gSpellOff = YES; LOG(@"spell tie fix OFF: the gesture zone's layout not as expected");
            return gOrigGestureTouch(self, dt, handle, event, at, a, b, c);
        }
    }
    if (!gCanCastFn && plausibleObj(pc)) { gCanCastFn = findFunction(pc, "CanPlayerCastMagic"); if (!gCanCastFn) LOG(@"spells: CanPlayerCastMagic not found"); }
    gSpellZone = zone;
    uint64_t r = gOrigGestureTouch(self, dt, handle, event, at, a, b, c);
    gSpellZone = NULL;
    spellAfter();
    return r;
}
static void hookSpells(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **touch = (void **)(IB1_GESTURE_TOUCH_SLOT + slide), **pe = (void **)(IB1_SWORDPC_PE_SLOT + slide);
    if (*touch != (void *)(IB1_GESTURE_TOUCH_FN + slide) || *pe != (void *)(IB1_ACTOR_PROCESSEVENT + slide)) { LOG(@"spell tie fix OFF: vtables not as expected"); return; }
    gOrigGestureTouch = (GestureTouchFn)*touch; *touch = (void *)my_gestureTouch;
    gOrigPCProcessEvent = (void (*)(void *, void *, void *, void *))*pe; *pe = (void *)my_pcProcessEvent;
    LOG(@"spell tie fix ON");
}

// ---- 4j. Speech over music (FIXES.md 49) ----
// Every spoken line, and no other sound, has subtitles in its wave: while one plays, the music goes 12 dB lower (down
// over 0.25 s, back up over 1 s from 0.3 s after the last line; steps of under 1 dB, 50 a second), and the line is 1.5x
// louder (+3.5 dB, kept to 0.89 or under: the recordings peak at full scale), times the Voice Volume slider (7).
// The levels are chosen (FIXES.md 49). FALSoundSource::Update (0x1008dad18; vtable 0x100b82838, slot 3 at 0x100b82858; Init
// calls it through the vtable too) sets each sound's gain from its wave instance (+0x10; the wave at +0): it's wrapped
// so ibfix.m's alSourcef knows the gain it sets is a spoken line's.
#define IB1_ALSOURCE_UPDATE_SLOT 0x100b82858ULL
#define IB1_ALSOURCE_UPDATE_FN   0x1008dad18ULL
extern _Thread_local float ibfix_speech_gain;                   // ibfix.m: < 0, or the gain factor for a spoken line
extern _Thread_local float ibfix_effects_gain;                  // ibfix.m: any other sound's gain factor (5d), 1 normally
static const float kVoiceLift = 1.5f, kMusicUnderSpeech = 0.2512f;   // +3.5 dB; -12 dB
static volatile double gLastSpeech;                             // when a spoken line was last updated (game thread)
static void *gSpeechWave;
static void (*gOrigSourceUpdate)(void *);
static BOOL isSpeech(uint8_t *wave) {
    int o = wave ? poff(CLS(wave), "Subtitles") : -1;
    return o >= 0 && *(int *)(wave + o + 8) > 0;
}
static float spokenLineFade(void *src, uint8_t *wi, uint8_t *wave);    // 4w: 1, or less while fast-forward silences it
static float ffSoftGain(void *src, uint8_t *wi);                        // 5d: 1, or less while skip is held
static void my_sourceUpdate(void *src) {
    uint8_t *wi = *(uint8_t **)((uint8_t *)src + 0x10), *wave = wi ? *(uint8_t **)wi : NULL;
    if (!isSpeech(wave)) {
        ibfix_effects_gain = wi ? ffSoftGain(src, wi) : 1;
        gOrigSourceUpdate(src);
        ibfix_effects_gain = 1;
        return;
    }
    float fade = spokenLineFade(src, wi, wave);
    if (fade > 0) {                                             // a silenced line neither logs nor lowers the music
        if (wave != gSpeechWave) {
            gSpeechWave = wave;
            LOG(@"speech: %@: music 12 dB lower while it plays, the line x%.2f (Voice Volume %.2f)", ibfix_objname(wave), kVoiceLift * gVoiceVolume, gVoiceVolume);
        }
        gLastSpeech = CFAbsoluteTimeGetCurrent();
    }
    ibfix_speech_gain = kVoiceLift * gVoiceVolume * fade;
    gOrigSourceUpdate(src);
    ibfix_speech_gain = -1;
}
static void musicDipTick(void) {                                // main thread, 50 times a second
    static float dB = 0;                                        // the dip now, 0 to -12
    BOOL speaking = CFAbsoluteTimeGetCurrent() - gLastSpeech < 0.3;
    float want = speaking ? 20 * log10f(kMusicUnderSpeech) : 0, was = dB;
    if (dB > want) dB = fmaxf(want, dB - 12.0f / 12.5f);        // 0.25 s down
    else if (dB < want) dB = fminf(want, dB + 12.0f / 50);      // 1 s up
    if (dB == was) return;
    gMusicDip = powf(10, dB / 20);
    id del = [UIApplication sharedApplication].delegate;
    AVAudioPlayer *p = [del respondsToSelector:NSSelectorFromString(@"MusicPlayer")] ? [del valueForKey:@"MusicPlayer"] : nil;
    if ([p isKindOfClass:[AVAudioPlayer class]]) { NSNumber *asked = objc_getAssociatedObject(p, kAskedVolume); p.volume = asked ? asked.floatValue : 1.0f; }
    if (gOutgoing) { NSNumber *asked = objc_getAssociatedObject(gOutgoing, kAskedVolume); gOutgoing.volume = asked ? asked.floatValue : 1.0f; }
    if (dB == 0) { LOG(@"speech: over, the music back up"); gSpeechWave = NULL; }
}
static void hookSpeech(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **slot = (void **)(IB1_ALSOURCE_UPDATE_SLOT + slide);
    if (*slot != (void *)(IB1_ALSOURCE_UPDATE_FN + slide)) { LOG(@"speech over music OFF: vtable not as expected"); return; }
    gOrigSourceUpdate = (void (*)(void *))*slot; *slot = (void *)my_sourceUpdate;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:kVoiceVolumeKey]) gVoiceVolume = fminf(fmaxf([[NSUserDefaults standardUserDefaults] floatForKey:kVoiceVolumeKey], 0), 1);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 50), NSEC_PER_SEC / 50, NSEC_PER_SEC / 500);
    dispatch_source_set_event_handler(t, ^{ musicDipTick(); });
    static dispatch_source_t keep; keep = t; dispatch_resume(t);
}

// ---- 4l. Fast-forward only while the button is held (FIXES.md 57) ----
// The game's fast-forward is a hold button (IPhone-SwordInput.ini: Sword_FastForward = "MatineeFastForward | Onrelease
// MatineeResume"; SwordHudBase sets the game's speed to 1000 and bFastForwardMode). While any cutscene is on screen, its
// FastForwardUpdate restarts fast-forward whenever bFastForwardMode is set and the speed isn't 1000, so a mode left set
// after let-go ran the next cutscene on its own. So that script call (MatineeFastForward from FastForwardUpdate, its only
// script caller; a real press comes through the input binding, not here) is skipped when the button isn't held, which
// also leaves the mode cleared (FastForwardUpdate clears it just before the call); ffHeldTick keeps the speed from
// sticking.
static int gNameFFStart = -2, gNameFFUpdate = -2;
static BOOL ffRestartBlocked(void *self, void *stack) {     // YES: the call was stepped over, not made
    if (gNameFFStart == -2) { gNameFFStart = nameIndex("MatineeFastForward"); gNameFFUpdate = nameIndex("FastForwardUpdate"); }
    uint8_t **code = (uint8_t **)((uint8_t *)stack + FFRAME_CODE);
    if (gNameFFStart < 0 || *(int *)*code != gNameFFStart || !self || skipHeld()) return NO;
    void *caller = *(void **)((uint8_t *)stack + 0x18);
    if (!caller || *(int *)((uint8_t *)caller + 0x48) != gNameFFUpdate) return NO;
    if ((*code)[8] != 0x16) return NO;                     // no arguments: the name, then EX_EndFunctionParms
    *code += 9;
    static int n; if (++n <= 20 || n % 50 == 0) LOG(@"fast-forward: the game tried to restart it with the button not held: not restarted (%d)", n);
    return YES;
}
// The HUD (SwordHudBase), kept by slot and looked for again when gone (every 2 s at most)
static void *ffHud(void) {
    static ObjRef h; static CFAbsoluteTime lastScan;
    if (h.obj && !refLive(&h)) h.obj = NULL;
    CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
    if (!h.obj && tn - lastScan > 2) {
        lastScan = tn;
        void *found[2]; int n = ibfix_objects_of_class("SwordHudBase", found, 2);
        ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
        for (int i = 0; n && i < objs->num; i++) if (objs->data[i] == found[0]) { h = (ObjRef){ found[0], i, CLS(found[0]) }; break; }
    }
    return h.obj;
}
// The 1000 can also come back with no finger down from a copy of the game's speed taken while fast-forward was on and
// put back later (tools/ffreplay.py finds such starts in saved logs). The game keeps three such copies and no more: the
// HUD's LastGameSpeed (put back on let-go), SwordPC.UnPauseGameSpeed (put back when the pause menu closes) and, in each
// playing film with a slow-motion track, InterpTrackInstSlomo.OldTimeDilation (put back when the film ends). The game's
// own let-go (MatineeResume) does nothing once the button is up. So each frame none of the three is left at a
// fast-forward speed (set to 1), and a speed still that high with no finger on the button is ended at once (waiting a
// frame lost 0.4 s of game time), by the game's own GameInfo.SetGameSpeed (the speed itself if that can't be called).
static void ffNoted(float *v, NSString *what) {
    static int m; if (++m <= 20 || m % 50 == 0) LOG(@"fast-forward: %@ had noted %.0f as the speed to go back to: set to 1 (%d)", what, *v, m);
    *v = 1;
}
static void ffHeldTick(void) {
    uint8_t *wi = WORLD_INFO();
    int oTD = wi ? poff(CLS(wi), "TimeDilation") : -1;
    if (oTD < 0) return;
    uint8_t *hud = ffHud();
    if (hud) {
        void *hcls = CLS(hud);
        int oLast = poff(hcls, "LastGameSpeed"), oPC = poff(hcls, "PlayerOwner");
        if (oLast >= 0 && *(float *)(hud + oLast) >= 500) ffNoted((float *)(hud + oLast), @"the HUD (LastGameSpeed, put back on let-go)");
        uint8_t *pc = oPC >= 0 ? *(uint8_t **)(hud + oPC) : NULL;
        int oUnp = pc ? poff(CLS(pc), "UnPauseGameSpeed") : -1;
        if (oUnp >= 0 && *(float *)(pc + oUnp) >= 500) ffNoted((float *)(pc + oUnp), @"the pause menu (UnPauseGameSpeed, put back when it closes)");
    }
    for (int f = 0; f < gNumFilms; f++) {                                    // every started film's slow-motion tracks
        Film *fl = &gFilms[f];
        if (!refLive(&fl->ref)) continue;
        uint8_t *film = fl->ref.obj;
        int oGI = poff(fl->ref.cls, "GroupInst");
        if (oGI < 0) continue;
        struct { uint8_t **data; int num, max; } *gi = (void *)(film + oGI);
        if (gi->num <= 0 || gi->num > 64) continue;                         // not started
        for (int g = 0; g < gi->num; g++) {
            GROUP_TRACKS(gi, g);
            for (int t = 0; t < ti->num && t < 256; t++) {
                uint8_t *tr = ti->data[t];
                if (!isClass(tr, "InterpTrackInstSlomo")) continue;
                int oOld = poff(CLS(tr), "OldTimeDilation");
                if (oOld >= 0 && *(float *)(tr + oOld) >= 500)
                    ffNoted((float *)(tr + oOld), [NSString stringWithFormat:@"film %@ (its slow-motion track, put back when the film ends)", ibfix_objname(film)]);
            }
        }
    }
    if (*(float *)(wi + oTD) < 500 || skipHeld()) return;
    void *fn = hud ? findFunction(hud, "MatineeResume") : NULL;
    if (fn) processEvent(hud, fn, NULL);
    NSString *how = fn ? @"MatineeResume" : @"no HUD found";
    if (*(float *)(wi + oTD) >= 500) {
        int oGame = poff(CLS(wi), "Game");
        void *game = oGame >= 0 ? *(void **)(wi + oGame) : NULL;
        uint8_t *set = game ? findFunction(game, "SetGameSpeed") : NULL;
        int oT = set ? propertyOffset(set, "T") : -1;
        if (set && oT >= 0 && *(uint16_t *)(set + 0xe2) >= oT + 4) {
            uint8_t parms[16] = {0}; *(float *)(parms + oT) = 1;
            processEvent(game, set, parms); how = [how stringByAppendingString:@", then SetGameSpeed(1)"];
        }
        if (*(float *)(wi + oTD) >= 500) { *(float *)(wi + oTD) = 1; how = [how stringByAppendingString:@", then the speed itself"]; }
    }
    static int k; if (++k <= 20 || k % 50 == 0)
        LOG(@"fast-forward: still on with the button not held: ended (%@, speed now %.2f) (%d)", how, *(float *)(wi + oTD), k);
}

// ---- 7c. Hide The HUD and Hide Combat Text (all builds; FIXES.md 63) ----
// Two switches just below Invert Look Axis, kept across launches, made with the game's own AddOption and checkbox:
//   Hide The HUD      health, gauges, prompts (SwordHudBase.DrawHUD) and the buttons' pictures
//                     (MobileHUD.DrawInputZoneOverlays; the buttons still work). Menus are drawn apart from both
//                     (MobileHUD.PostRender -> RenderMobileMenu), so pause and Options show.
//   Hide Combat Text  the pop-up words (DrawDisplayEvent), the damage and healing numbers (DrawDisplayStats) and the XP
//                     bonus (DrawXpBonus); the devs' own switch for this (OnUpdateDemoHud) also showed a parry readout.
// Neither turns the drawing off: the HUD's draw code also runs the game (SwordHudBase.DrawVictory ends the killing blow's
// slow motion; the engine's bShowHUD would have left it slow). So those calls run as usual under a canvas transform that
// squashes everything they draw to a point far off-screen (FCanvas::PushRelativeTransform, as section 3b uses).
// Handlers: the devs' OnUpdateMemLeakCheckRun (Hide The HUD) and OnUpdateDemoHud (Hide Combat Text), made native.
static uint8_t *objAt(uint8_t *obj, const char *name) {
    int o = plausibleObj(obj) ? poff(CLS(obj), name) : -1;
    uint8_t *v = o >= 0 ? *(uint8_t **)(obj + o) : NULL;
    return plausibleObj(v) ? v : NULL;
}
// A bool property of a class (or a function's parameter): its offset and bit (UBoolProperty::BitMask, +0xb8), remembered
// per class and name.
static BOOL boolProp(void *structp, const char *name, int *off, uint32_t *mask) {
    static struct { void *st; const char *name; int off; uint32_t mask; } memo[64]; static int n;   // a boss class each
    for (int i = 0; i < n; i++) if (memo[i].st == structp && memo[i].name == name) { *off = memo[i].off; *mask = memo[i].mask; return *off >= 0; }
    *off = -1; *mask = 0;
    for (uint8_t *st = structp; st && *off < 0; st = *(uint8_t **)(st + 0x68))
        for (uint8_t *f = *(uint8_t **)(st + 0x70); f; f = *(uint8_t **)(f + 0x60))
            if ([ibfix_objname(f) isEqualToString:@(name)] && [ibfix_objname(CLS(f)) isEqualToString:@"BoolProperty"]) {
                *off = *(int *)(f + 0x7c); *mask = *(uint32_t *)(f + 0xb8); break;
            }
    if (*mask == 0) *off = -1;
    if (n < 64) memo[n++] = (typeof(memo[0])){ structp, name, *off, *mask };
    return *off >= 0;
}
static BOOL boolGet(uint8_t *obj, const char *name, BOOL *on) {
    int off; uint32_t mask;
    if (!plausibleObj(obj) || !boolProp(CLS(obj), name, &off, &mask)) return NO;
    *on = (*(uint32_t *)(obj + off) & mask) != 0;
    return YES;
}
static BOOL boolSet(uint8_t *obj, const char *name, BOOL on) {
    int off; uint32_t mask;
    if (!plausibleObj(obj) || !boolProp(CLS(obj), name, &off, &mask)) return NO;
    uint32_t *w = (uint32_t *)(obj + off);
    *w = on ? (*w | mask) : (*w & ~mask);
    return YES;
}

// A switch's handler: on bInit, show the stored state; on a tap (the item has already flipped bIsChecked), keep it and
// apply it at once (apply: NULL, or what to do now, with the player controller).
static void optionSwitch(uint8_t *list, void *stack, void *fn, BOOL *flag, NSString *key, const char *what, void (*apply)(uint8_t *pc, BOOL on)) {
    BOOL bInit, on;
    uint8_t *item = handlerArgs(stack, fn, &bInit);
    if (!item) return;
    if (bInit) {
        uint8_t *set = findFunction(item, "SetChecked"); int o; uint32_t mask;
        if (!set || !boolProp(set, "bOn", &o, &mask) || *(uint16_t *)(set + 0xe2) > 16) { LOG(@"options: %s: SetChecked not as expected", what); return; }
        uint8_t parms[16] = {0}; *(uint32_t *)(parms + o) = *flag ? mask : 0;
        processEvent(item, set, parms);
        return;
    }
    if (!boolGet(item, "bIsChecked", &on)) { LOG(@"options: %s: no bIsChecked", what); return; }
    *flag = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:key];
    LOG(@"options: %s %@", what, on ? @"on" : @"off");
    if (apply) apply(objAt(list, "SwordPC"), on);
}

// Rows for the options list, made with the game's own AddOption and item classes (copied from its Invert Look Axis
// checkbox and a button), labelled with SetText, then moved: to the top (after NULL) or just below the item whose handler
// is after. NO if anything isn't as expected, or if they're already in this list (the first row's handler is found).
typedef struct { const char *label, *handler; BOOL check; void *native; void **save; } OptionRow;
static BOOL addOptionRows(uint8_t *list, const OptionRow *rows, int count, const char *after, const char *what) {
    uint8_t *addOption = findFunction(list, "AddOption");
    int itemsOff = propertyOffset(CLS(list), "Items");
    if (!addOption || *(uint16_t *)(addOption + 0xe2) != 0x30 || itemsOff <= 0 || count > 16) { LOG(@"%s OFF: options list not as expected", what); return NO; }
    struct { void **data; int num, max; } *items = (void *)(list + itemsOff);
    void *checkClass = NULL, *buttonClass = NULL;
    int first = nameIndex(rows[0].handler), afterName = after ? nameIndex(after) : -1, at = after ? -1 : 0;
    for (int i = 0; i < items->num; i++) {
        void *cls = CLS(items->data[i]);
        NSString *cn = ibfix_objname(cls);
        if ([cn isEqualToString:@"SwordOptionListCheckBox"]) checkClass = cls;
        if ([cn isEqualToString:@"SwordOptionListButton"]) buttonClass = cls;
        int o = propertyOffset(cls, "OnUpdate"), h = o > 0 ? *(int *)((uint8_t *)items->data[i] + o + 8) : -1;
        if (h == first) return NO;                                                  // already added to this list
        if (after && h == afterName) at = i + 1;
    }
    if (!checkClass || !buttonClass || at < 0) { LOG(@"%s OFF: no checkbox, button or %s in the list", what, after ?: "top"); return NO; }
    for (int k = 0; k < count; k++) if (!handlerShapeOK(list, rows[k].handler)) { LOG(@"%s OFF: %s not as expected", what, rows[k].handler); return NO; }
    for (int k = 0; k < count; k++)
        if (rows[k].native && !pointHandler(list, rows[k].handler, rows[k].native, rows[k].save)) { LOG(@"%s OFF: %s not replaced", what, rows[k].handler); return NO; }
    void *added[16] = {0};
    for (int k = 0; k < count; k++) {
        struct { void *cls; void *delObj; int32_t delName, delNum; FStr caption; void *ret; } parms =
            { rows[k].check ? checkClass : buttonClass, list, nameIndex(rows[k].handler), 0, { NULL, 0, 0 }, NULL };
        processEvent(list, addOption, &parms);                  // the caption is set after (see addVolumeSliders)
        added[k] = parms.ret;
        int capOff = added[k] ? propertyOffset(CLS(added[k]), "Caption") : -1;
        void *caption = capOff > 0 ? *(void **)((uint8_t *)added[k] + capOff) : NULL;
        if (caption) setText(caption, rows[k].label);
    }
    int n = items->num; void **d = items->data;
    for (int k = 0; k < count; k++) if (n < count || d[n - count + k] != added[k]) { LOG(@"%s: added at the end (couldn't move them)", what); return YES; }
    memmove(&d[at + count], &d[at], (size_t)(n - count - at) * sizeof(void *));
    for (int k = 0; k < count; k++) d[at + k] = added[k];
    LOG(@"%s: %d rows at place %d of the options list (%d options)", what, count, at, n);
    return YES;
}

static NSString *const kHideHUDKey = @"ibfixHideHUD", *const kHideCombatTextKey = @"ibfixHideCombatText";
static BOOL gHideHUD, gHideCombatText, gHaptics;                // gHaptics: 7d
static void *gHideHUDFn, *gHideTextFn;
static void displayOptionsLoad(void) {
    static BOOL loaded;
    if (loaded) return;
    loaded = YES;
    gHideHUD = [[NSUserDefaults standardUserDefaults] boolForKey:kHideHUDKey];
    gHideCombatText = [[NSUserDefaults standardUserDefaults] boolForKey:kHideCombatTextKey];
    gHaptics = [[NSUserDefaults standardUserDefaults] boolForKey:@"ibfixHaptics"];               // 7d (kHapticsKey)
    LOG(@"options: Hide The HUD %@, Hide Combat Text %@, Haptics %@", gHideHUD ? @"on" : @"off", gHideCombatText ? @"on" : @"off", gHaptics ? @"on" : @"off");
}
static void my_onHideHUD(void *self, void *stack, void *result)  { optionSwitch(self, stack, gHideHUDFn, &gHideHUD, kHideHUDKey, "Hide The HUD", NULL); }
static void my_onHideText(void *self, void *stack, void *result) { optionSwitch(self, stack, gHideTextFn, &gHideCombatText, kHideCombatTextKey, "Hide Combat Text", NULL); }
// ---- 7d. Turn Off Tutorials and Haptics (29 October 2026, for version 21; FIXES.md 83, 84) ----
// Turn Off Tutorials: the devs' own finished switch, never put in the list (SwordUserOptionsList.OnUpdateTutorial: ticked
// = PlayerPawn.GameOptions.bDisableTutorial, kept in the character's save). The game checks it wherever a lesson can
// come, our own lessons (4p) too. The devs left no caption; worded like the two switches above.
// Haptics (off until switched on, kept across launches; handler: the devs' unused OnToggleStats), at the strengths chosen
// picked in tools/hapticspicker (whose numbers these are): a good block 7 (also "Block Broken"), a parry and a dodge
// nothing, every attack that lands on the knight 7 (a dodge the wrong way included), his shield bash 7, and a big camera
// shake or a scene's hard hit 8 (below hapticMoment). Block and parry are seen as SwordPlayer.DisplayStatus shows its
// words through SwordHudBase.DisplayPlayerEvent (XPType 2 block, 4 parry, 3 dodge), its locals in the caller's frame.
static NSString *const kHapticsKey = @"ibfixHaptics";
static void *gHapticsFn;
static void my_onHaptics(void *self, void *stack, void *result) { optionSwitch(self, stack, gHapticsFn, &gHaptics, kHapticsKey, "Haptics", NULL); }
// Core Haptics drives the motor directly (UIKit's impacts, meant for buttons, were too gentle). The engine plays haptics
// only (playsHapticsOnly), so the game's audio session (sections 1, 5b) is never touched; it restarts itself after the
// app has been away (stoppedHandler) or the haptic server resets (resetHandler). UIKit's heavy impact if Core Haptics
// isn't there.
static CHHapticEngine *gHapticEngine; static BOOL gHapticStopped;
static CHHapticEventParameter *hapticParam(CHHapticEventParameterID p, float v) { return [[CHHapticEventParameter alloc] initWithParameterID:p value:v]; }
static BOOL hapticReady(void) {                                 // main thread: the engine running, or NO
    if (!gHapticEngine && CHHapticEngine.capabilitiesForHardware.supportsHaptics) {
        NSError *e = nil;
        gHapticEngine = [[CHHapticEngine alloc] initAndReturnError:&e];
        gHapticEngine.playsHapticsOnly = YES;
        gHapticEngine.stoppedHandler = ^(CHHapticEngineStoppedReason r) { gHapticStopped = YES; };
        gHapticEngine.resetHandler = ^{ NSError *e2 = nil; [gHapticEngine startAndReturnError:&e2]; gHapticStopped = NO; };
        if (gHapticEngine && [gHapticEngine startAndReturnError:&e]) LOG(@"haptics: Core Haptics engine started");
        else { LOG(@"haptics: Core Haptics engine not started (%@): UIKit's impacts instead", e.localizedDescription); gHapticEngine = nil; }
    }
    if (gHapticEngine && gHapticStopped) { NSError *e = nil; if ([gHapticEngine startAndReturnError:&e]) gHapticStopped = NO; }
    return gHapticEngine != nil;
}
// Haptics Picker's strengths 4, 7 and 8, the same numbers as its play(): 4 is one sharp knock at full strength (intensity
// 1, sharpness 0.75); 7 a thump (full strength, soft) and a rumble dying away over 0.45 s (6, no longer used: 0.22 s); 8 a
// softer knock and a rolling rumble of 0.85 s that swells twice as it dies.
// A camera shake plays 8 as strong as the shake (its Scale, 0.4 to 1) and squeezed into the shake's own length when
// that is shorter (0.15 s at least), so a full shake is 8 exactly. The same strength twice within 0.1 s plays once (a
// broken block is a block and a hit in one frame).
static void hapticPlay(int n, float strength, float length) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static double last[9]; double now = NSProcessInfo.processInfo.systemUptime;
        if (now - last[n] < 0.1) return;
        last[n] = now;
        if (!hapticReady()) { static UIImpactFeedbackGenerator *g; if (!g) g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy]; [g impactOccurredWithIntensity:strength]; return; }
        NSError *e = nil;
        CHHapticEvent *knock = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
            parameters:@[hapticParam(CHHapticEventParameterIDHapticIntensity, strength), hapticParam(CHHapticEventParameterIDHapticSharpness, n == 8 ? 0.3f : 0.35f)] relativeTime:0];
        CHHapticEvent *rumble = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
            parameters:@[hapticParam(CHHapticEventParameterIDHapticIntensity, strength), hapticParam(CHHapticEventParameterIDHapticSharpness, n == 8 ? 0.1f : 0.15f)] relativeTime:0.01 duration:length];
        static const float swell[][2] = { {0.01f, 1}, {0.2f, 0.6f}, {0.35f, 0.95f}, {0.55f, 0.45f}, {0.7f, 0.6f}, {0.86f, 0} };
        NSMutableArray *points = [NSMutableArray array];
        if (n == 8) for (int i = 0; i < 6; i++)
            [points addObject:[[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0.01 + (swell[i][0] - 0.01f) * length / 0.85f value:swell[i][1]]];
        else { [points addObject:[[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0.01 value:1.0f]];
               [points addObject:[[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:0.01 + length value:0.0f]]; }
        CHHapticParameterCurve *fade = [[CHHapticParameterCurve alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl controlPoints:points relativeTime:0];
        CHHapticPattern *pat = n == 4 ? [[CHHapticPattern alloc] initWithEvents:@[[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                parameters:@[hapticParam(CHHapticEventParameterIDHapticIntensity, strength), hapticParam(CHHapticEventParameterIDHapticSharpness, 0.75f)] relativeTime:0]] parameters:@[] error:&e]
            : [[CHHapticPattern alloc] initWithEvents:@[knock, rumble] parameterCurves:@[fade] error:&e];
        id<CHHapticPatternPlayer> p = pat ? [gHapticEngine createPlayerWithPattern:pat error:&e] : nil;
        if (![p startAtTime:CHHapticTimeImmediate error:&e]) { static int f; if (++f <= 3) LOG(@"haptics: strength %d not played (%@)", n, e.localizedDescription); }
    });
}
static void hapticMoment(int n) { hapticPlay(n, 1, n == 6 ? 0.22f : 0.45f); }    // 4, 6 or 7 at full strength
// Scenes that hit hard where the devs' own camera shakes are small (unfelt) or at other moments: 8 at full strength at
// the impact, by the film's own time, where the films' sound keys put it (decomp/levels/Battle_6ft_GodKing_seq,
// InterpTrackSound). By choice (FIXES.md 84).
typedef struct { const char *level, *film; float at; const char *what; } FilmHaptic;
static const FilmHaptic kFilmHaptics[] = {
    { "Battle_6ft_GodKing", "SeqAct_Interp_4", 0.49f, "the God King's slam (join offer)" },
    { "Battle_6ft_GodKing", "SeqAct_Interp_25", 0.39f, "the God King's blast (third stage)" },
    { "Battle_6ft_GodKing", "SeqAct_Interp_25", 2.70f, "the God King's landing (third stage)" },
    { "Battle_6ft_GodKing", "SeqAct_Interp_6", 11.31f, "the God King's sword through the knight (his kill)" },
};
enum { kNumFilmHaptics = sizeof kFilmHaptics / sizeof *kFilmHaptics };
static void filmHapticsTick(void) {                             // every frame (the camera's update)
    if (!gHaptics) return;
    static ObjRef film[kNumFilmHaptics]; static float last[kNumFilmHaptics]; static CFAbsoluteTime looked[kNumFilmHaptics];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (int e = 0; e < kNumFilmHaptics; e++) {
        if (!refLive(&film[e])) {                               // found by name and level, looked for every 2 s at most
            film[e].obj = NULL; last[e] = -1;
            if (now - looked[e] < 2) continue;
            looked[e] = now;
            for (int f = 0; f < gNumFilms; f++) {
                if (!refLive(&gFilms[f].ref) || ![ibfix_objname(gFilms[f].ref.obj) isEqualToString:@(kFilmHaptics[e].film)]) continue;
                const uint8_t *top = gFilms[f].ref.obj; for (int k = 0; *(const uint8_t **)(top + 0x40) && k < 16; k++) top = *(const uint8_t **)(top + 0x40);
                if ([ibfix_objname((void *)top) isEqualToString:@(kFilmHaptics[e].level)]) { film[e] = gFilms[f].ref; break; }
            }
            if (!film[e].obj) continue;
        }
        int oPos = poff(film[e].cls, "Position");
        if (oPos < 0) continue;
        float t = *(float *)(film[e].obj + oPos), at = kFilmHaptics[e].at;
        if (last[e] >= 0 && last[e] < at && t >= at && t - at < 0.5f) {   // passed it this frame (not by a big skip)
            hapticPlay(8, 1, 0.85f);
            LOG(@"haptics: %s, %.2f s into %s: 8 at 1.00 for 0.85 s", kFilmHaptics[e].what, t, kFilmHaptics[e].film);
        }
        last[e] = t;
    }
}
// Which camera shakes are felt (by choice, FIXES.md 84: only the big moments). Every fight effect plays its shake through
// SwordPawn.PlayFX -> PlayerController.ClientPlayCameraShake(FXArray[PawnFXIndex].CameraShake), and its Tag says whose
// and what it is: the knight's own are never felt but his shield bash (7); the enemy's fight results (Hit_Code,
// BigHit_Code, Miss_Code: a dodge, AttackBlocked*) never, as hits and blocks have their own. The rest (the enemy's own
// moves, Kismet's SeqAct_CameraShake) plays 8 only when its swing times the shake's scale is 100 or more (the game's
// shakes swing the camera 25 for a strike, 50 small, 100 for a shield block, big hit or long hit).
static struct { BOOL set; uint8_t *pawn, *elem; } gShakeFX;     // the fight effect whose shake is being played
static int gFxSize = -2, gFxTag, gFxShake;                      // SwordPawn.SwordEffect: record size, Tag and CameraShake
static uint8_t *findStruct(void *cls, const char *name) {       // a struct declared in a class or one of its parents
    for (uint8_t *st = cls; st; st = *(uint8_t **)(st + 0x68))
        for (uint8_t *f = *(uint8_t **)(st + 0x70); f; f = *(uint8_t **)(f + 0x60))
            if ([ibfix_objname(f) isEqualToString:@(name)] && [ibfix_objname(CLS(f)) isEqualToString:@"ScriptStruct"]) return f;
    return NULL;
}
// The effect records' size: UStruct::PropertiesSize (+0x78), trusted only if it ends where the last property does
// (UProperty: ArrayDim +0x68, ElementSize +0x6c, Offset +0x7c), give or take its alignment.
static void fxLayout(void *pawnCls) {
    uint8_t *st = findStruct(pawnCls, "SwordEffect");
    int size = st ? *(int *)(st + 0x78) : 0, end = 0;
    for (uint8_t *f = st ? *(uint8_t **)(st + 0x70) : NULL; f; f = *(uint8_t **)(f + 0x60))
        if ([ibfix_objname(CLS(f)) hasSuffix:@"Property"]) end = MAX(end, *(int *)(f + 0x7c) + *(int *)(f + 0x6c) * *(int *)(f + 0x68));
    gFxTag = st ? propertyOffset(st, "Tag") : -1; gFxShake = st ? propertyOffset(st, "CameraShake") : -1;
    gFxSize = (gFxTag >= 0 && gFxShake >= 0 && end > 0 && size >= end && size <= end + 8) ? size : -1;
    LOG(@"haptics: fight effects are %d-byte records (properties end at %d; Tag +%d, CameraShake +%d)%@", size, end, gFxTag, gFxShake,
        gFxSize < 0 ? @": not as expected, so their names aren't read" : @"");
}
static NSString *fstrText(const uint8_t *p) {                   // an FString's text (UTF-32), or nil
    const uint32_t *d = *(const uint32_t **)p; int n = *(const int *)(p + 8);
    return (d && ((uintptr_t)d & 3) == 0 && n > 1 && n < 64) ? [[NSString alloc] initWithBytes:d length:(NSUInteger)(n - 1) * 4 encoding:NSUTF32LittleEndianStringEncoding] : nil;
}
static float shakeSwing(uint8_t *shake) {                       // its larger rotation swing, pitch or yaw (RotOscillation)
    static int oRot = -2, oPitch, oYaw, oAmp;
    void *cls = CLS(shake);
    if (oRot == -2) {
        uint8_t *r = findStruct(cls, "ROscillator"), *f = findStruct(cls, "FOscillator");
        oRot = poff(cls, "RotOscillation"); oPitch = r ? propertyOffset(r, "Pitch") : -1; oYaw = r ? propertyOffset(r, "Yaw") : -1; oAmp = f ? propertyOffset(f, "Amplitude") : -1;
        LOG(@"haptics: a shake's swing at RotOscillation +%d, Pitch +%d, Yaw +%d, Amplitude +%d", oRot, oPitch, oYaw, oAmp);
    }
    if (oRot < 0 || oPitch < 0 || oYaw < 0 || oAmp < 0) return 0;  // can't tell: not felt
    return fmaxf(fabsf(*(float *)(shake + oRot + oPitch + oAmp)), fabsf(*(float *)(shake + oRot + oYaw + oAmp)));
}
static uint8_t *playerPawn(void) { uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL; return pc ? objAt(pc, "PlayerPawn") : NULL; }
// A boss's death scene: felt are the killing blow and the fall (by choice, FIXES.md 84). The killing blow is the knight's Stab or
// Stab_BIG effect while his enemy is dead (a stab in the fight stays unfelt): 8, as a big shake. The arenas' death films
// (SeqAct_Interp "Death") shake the camera at a time the devs copied from film to film (4.03 s in most), whatever the
// scene shows; in these arenas it comes before the knight's killing stab (decomp/levels/*_seq/kismet.txt event keys
// against tools/filmcues.py's stab cues, effect 8 or 38), so the stab carries the rumble and the shake plays nothing.
// Elsewhere it stays felt. A giant's fall is his own GroundSlam effect, a big shake, felt as any enemy's move.
static const char *kStabAfterShake[] = { "Battle_15ft_01", "Battle_15ft_02", "Battle_15ft_03", "Battle_15ft_Cell01", "Battle_15ft_MP",
                                         "Battle_6ft_01", "Battle_6ft_MP", "Battle_6ft_Zero" };
static NSString *gShakeLevel;                                   // a level's scripted shake being played: its level
// Whether the boss is dead: his health (Pawn.Health; -9999 once killed) from the knight's Enemy, the player controller's
// CurrentBoss, or the last boss seen playing an effect (SwordPawn.PlayFX: a pawn with StageTransitionHealth, below). By
// the death film the game has set both the knight's Enemy and CurrentBoss to none, so the last boss is what answers;
// test builds log all three as a death film starts (deathCheckLog).
static ObjRef gLastBoss;
static int healthOf(uint8_t *p) {
    int oH = p && plausibleObj(p) ? poff(CLS(p), "Health") : -1;
    return oH >= 0 ? *(int *)(p + oH) : 1;
}
static BOOL enemyDead(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL, *pawn = pc ? objAt(pc, "PlayerPawn") : NULL;
    uint8_t *enemy = pawn ? objAt(pawn, "Enemy") : NULL, *boss = pc ? objAt(pc, "CurrentBoss") : NULL;
    return (enemy && healthOf(enemy) <= 0) || (boss && healthOf(boss) <= 0) || (refLive(&gLastBoss) && healthOf(gLastBoss.obj) <= 0);
}
#ifdef IBFIX_SNAPS
static void deathCheckLog(NSString *film) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL, *pawn = pc ? objAt(pc, "PlayerPawn") : NULL;
    uint8_t *enemy = pawn ? objAt(pawn, "Enemy") : NULL, *boss = pc ? objAt(pc, "CurrentBoss") : NULL, *last = refLive(&gLastBoss) ? gLastBoss.obj : NULL;
    LOG(@"death film check (%@): knight's Enemy %@ (health %d), CurrentBoss %@ (health %d), last boss %@ (health %d)", film,
        enemy ? ibfix_objname(enemy) : @"none", enemy ? healthOf(enemy) : 0, boss ? ibfix_objname(boss) : @"none", boss ? healthOf(boss) : 0,
        last ? ibfix_objname(last) : @"none", last ? healthOf(last) : 0);
}
#endif
// From the script-call hook: YES if it made the call itself.
static int gNameDisplayEvent = -2, gNameTakeDamage, gNameAddShake, gNameElemental, gNameClientShake;
// The last boss seen playing an effect (SwordPawn.PlayFX: a pawn with StageTransitionHealth), whatever the switches say:
// haptics and blood both ask whether he's dead, so it's noted outside the haptics code, which doesn't run with Haptics
// off (FIXES.md 88).
static void noteLastBoss(void *self, int name) {
    NAME_ONCE(namePlayFX, "PlayFX");
    if (name == namePlayFX && self && self != gLastBoss.obj && poff(CLS(self), "StageTransitionHealth") >= 0)
        gLastBoss = (ObjRef){ self, *(int *)((uint8_t *)self + 0x38), CLS(self) };
}
static BOOL hapticCall(void *self, void *stack, void *result, int name) {
    if (!gHaptics || !self) return NO;
    static int namePlayFX = -2;
    if (gNameDisplayEvent == -2) { gNameDisplayEvent = nameIndex("DisplayPlayerEvent"); gNameTakeDamage = nameIndex("TakeDamage"); gNameAddShake = nameIndex("AddCameraShake");
                                   gNameElemental = nameIndex("HandleElementalAttackEffects"); gNameClientShake = nameIndex("ClientPlayCameraShake"); namePlayFX = nameIndex("PlayFX"); }
    (void)namePlayFX;                                           // the boss is remembered in noteLastBoss, for haptics and blood alike
    if (name == gNameClientShake) {                             // a fight effect's shake: note whose effect, for the call
        uint8_t *fn = *(uint8_t **)((uint8_t *)stack + 0x18), *loc = *(uint8_t **)((uint8_t *)stack + 0x30), *pawn = *(uint8_t **)((uint8_t *)stack + 0x20);
        static void *sceneFn; static int oAct = -1;               // a level's scripted shake (PlayerController.OnCameraShake)
        if (fn && fn != sceneFn && [ibfix_objname(fn) isEqualToString:@"OnCameraShake"]) { sceneFn = fn; oAct = propertyOffset(fn, "inAction"); }
        if (fn && fn == sceneFn && oAct >= 0 && loc && !gShakeLevel) {
            const uint8_t *act = *(const uint8_t **)(loc + oAct), *top = act;
            for (int k = 0; top && *(const uint8_t **)(top + 0x40) && k < 16; k++) top = *(const uint8_t **)(top + 0x40);
            gShakeLevel = act && plausibleObj(act) ? ibfix_objname((void *)top) : @"?";
            ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
            gShakeLevel = nil;
            return YES;
        }
        static void *playFX; static int oIdx = -1;
        if (fn && fn != playFX && [ibfix_objname(fn) isEqualToString:@"PlayFX"]) { playFX = fn; oIdx = propertyOffset(fn, "PawnFXIndex"); }
        if (fn != playFX || oIdx < 0 || !loc || !plausibleObj(pawn) || gShakeFX.set) return NO;
        void *cls = CLS(pawn);
        if (gFxSize == -2) fxLayout(cls);
        int oArr = poff(cls, "FXArray"), idx = *(int *)(loc + oIdx);
        struct { uint8_t *data; int num, max; } *arr = oArr >= 0 ? (void *)(pawn + oArr) : NULL;
        gShakeFX.pawn = pawn;
        gShakeFX.elem = (arr && arr->data && gFxSize > 0 && idx >= 0 && idx < arr->num) ? arr->data + (size_t)idx * gFxSize : NULL;
        gShakeFX.set = YES;
        ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
        gShakeFX.set = NO;
        return YES;
    }
    if (name == gNameAddShake) {                                // every camera shake: Camera.PlayCameraShake -> its modifier's AddCameraShake
        uint8_t *fn = *(uint8_t **)((uint8_t *)stack + 0x18), *loc = *(uint8_t **)((uint8_t *)stack + 0x30);
        static void *playFn; static int oShake = -1, oScale = -1;
        if (fn && fn != playFn && [ibfix_objname(fn) isEqualToString:@"PlayCameraShake"]) { playFn = fn; oShake = propertyOffset(fn, "Shake"); oScale = propertyOffset(fn, "Scale"); }
        if (fn != playFn || oShake < 0 || oScale < 0 || !loc) return NO;
        uint8_t *shake = *(uint8_t **)(loc + oShake); float scale = *(float *)(loc + oScale);
        if (!plausibleObj(shake) || scale <= 0.05f) return NO;
        BOOL fx = gShakeFX.set, knight = fx && gShakeFX.pawn == playerPawn();
        NSString *tag = nil;
        if (fx && gShakeFX.elem) {                              // the record's own shake must be this one, or its size is wrong
            if (*(uint8_t **)(gShakeFX.elem + gFxShake) == shake) tag = fstrText(gShakeFX.elem + gFxTag);
            else { static int m; if (++m <= 3) LOG(@"haptics: effect record doesn't hold shake %@: effect names not used", ibfix_objname(shake)); }
        }
        float swing = shakeSwing(shake);
        int play = 0; BOOL dead = enemyDead(), killing = NO, carried = NO;
        if (knight) { killing = dead && ([tag isEqualToString:@"Stab"] || [tag isEqualToString:@"Stab_BIG"]); play = [tag isEqualToString:@"Shield_Bash"] ? 7 : killing ? 8 : 0; }
        else if (fx && ([tag hasSuffix:@"Hit_Code"] || [tag containsString:@"Miss"] || [tag containsString:@"Blocked"])) play = 0;
        else {
            for (size_t k = 0; !fx && dead && gShakeLevel && k < sizeof kStabAfterShake / sizeof *kStabAfterShake; k++)
                if ([gShakeLevel isEqualToString:@(kStabAfterShake[k])]) carried = YES;
            play = !carried && swing * scale >= 99.0f ? 8 : 0;
        }
        int oDur = poff(CLS(shake), "OscillationDuration");
        float dur = oDur >= 0 ? *(float *)(shake + oDur) : 0, length = dur > 0 ? fminf(fmaxf(dur, 0.15f), 0.85f) : 0.85f;
        float strength = fminf(fmaxf(scale, 0.4f), 1.0f);
        if (killing) { strength = 1; length = 0.75f; }             // the killing blow: as the death scene's big shake
        if (play == 7) hapticMoment(7);
        else if (play == 8) hapticPlay(8, strength, length);
        static int nFelt, nNone;                                 // every felt one (to 300), the first 40 unfelt
        if (play ? ++nFelt <= 300 : ++nNone <= 40) LOG(@"haptics: camera shake %@ from %@ (%@, swing %.0f x %.2f, %.2f s%@): %@", ibfix_objname(shake),
            !fx ? [NSString stringWithFormat:@"a scene (%@)", gShakeLevel ?: @"not a level's"] : knight ? @"the knight's effect" : [NSString stringWithFormat:@"%@'s effect", ibfix_objname(gShakeFX.pawn)],
            tag ?: @"-", swing, scale, dur, dead ? (gDeathFilmPos >= 0 ? [NSString stringWithFormat:@", enemy dead, death film at %.2f s", gDeathFilmPos] : @", enemy dead") : @"",
            play == 7 ? @"7 (shield bash)" : play == 8 ? [NSString stringWithFormat:@"8 at %.2f for %.2f s%@", strength, length, killing ? @" (the killing blow)" : @""]
                      : carried ? @"none (the killing stab carries it)" : @"none");
        return NO;
    }
    if (name == gNameDisplayEvent) {                            // the knight's words for a good block, parry or dodge
        uint8_t *fn = *(uint8_t **)((uint8_t *)stack + 0x18), *loc = *(uint8_t **)((uint8_t *)stack + 0x30);
        static void *statusFn; static int oType = -1;
        if (fn && fn != statusFn && [ibfix_objname(fn) isEqualToString:@"DisplayStatus"] && [ibfix_objname(*(void **)(fn + 0x40)) isEqualToString:@"SwordPlayer"]) {
            statusFn = fn; oType = propertyOffset(fn, "XPType");
        }
        if (fn == statusFn && oType >= 0 && loc) {
            int type = *(int *)(loc + oType);
            if (type == 2) {                                    // a block; a dodge (3) or a parry (4) none (by choice, FIXES.md 84)
                hapticMoment(7);
                static int n; if (++n <= 30) LOG(@"haptics: block: 7");
            }
        }
        return NO;
    }
    if (name == gNameTakeDamage || name == gNameElemental) {     // an attack landing on the knight, however hard
        if (self != playerPawn()) return NO;
        // Every blow that reaches him calls TakeDamage from SwordPawn.AlertForHit (a hit, a dodge the wrong way too) or
        // SwordPlayer.HandleBlockDamage (through his block). TakeElementalDamage (an element's damage on top or ticking
        // away) has no contact, so nothing; but a hit carrying an element calls HandleElementalAttackEffects from
        // AlertForHit first, and fire, ice or dark can kill him there before the blow's own TakeDamage, so that call
        // counts as the hit too (the blow's TakeDamage straight after plays once with it).
        NSString *caller = ibfix_objname(*(void **)((uint8_t *)stack + 0x18));
        if ([caller isEqualToString:@"AlertForHit"] || (name == gNameTakeDamage && [caller isEqualToString:@"HandleBlockDamage"])) {
            hapticMoment(7);
            static int n; if (++n <= 40) LOG(@"haptics: hit taken (%@%@): 7", caller, name == gNameElemental ? @", element" : @"");
        }
        return NO;
    }
    return NO;
}
#ifdef IBFIX_BLOOD
static void *gBloodFn; static void my_onBlood(void *self, void *stack, void *result);   // 4ac
#endif
static void addDisplayOptions(uint8_t *list) {
    static const OptionRow rows[] = {
        { "Hide The HUD", "OnUpdateMemLeakCheckRun", YES, (void *)my_onHideHUD, &gHideHUDFn },
        { "Hide Combat Text", "OnUpdateDemoHud", YES, (void *)my_onHideText, &gHideTextFn },
        { "Turn Off Tutorials", "OnUpdateTutorial", YES, NULL, NULL },               // 7d: the devs' own handler
        { "Haptics", "OnToggleStats", YES, (void *)my_onHaptics, &gHapticsFn },      // 7d
#ifdef IBFIX_BLOOD
        { "Blood", "OnUpdateFastForward", YES, (void *)my_onBlood, &gBloodFn },      // 4ac: blood mode
#endif
    };
    displayOptionsLoad();
    addOptionRows(list, rows, sizeof rows / sizeof rows[0], "OnUpdateInvertAxis", "display options");
}
// A HUD drawing call to hide, run under the squashing transform; YES if it was (the call is made either way).
static int gNameDrawHUD = -2, gNameZoneOverlays, gNameDrawEvent, gNameDrawStats, gNameDrawXpBonus;
static BOOL hiddenDraw(void *self, void *stack, void *result, int name) {
    displayOptionsLoad();
    if ((!gHideHUD && !gHideCombatText) || !self) return NO;
    if (gNameDrawHUD == -2) {
        gNameDrawHUD = nameIndex("DrawHUD"); gNameZoneOverlays = nameIndex("DrawInputZoneOverlays");
        gNameDrawEvent = nameIndex("DrawDisplayEvent"); gNameDrawStats = nameIndex("DrawDisplayStats"); gNameDrawXpBonus = nameIndex("DrawXpBonus");
    }
    BOOL hide = (gHideHUD && name >= 0 && (name == gNameDrawHUD || name == gNameZoneOverlays)) ||
                (gHideCombatText && name >= 0 && (name == gNameDrawEvent || name == gNameDrawStats || name == gNameDrawXpBonus));
    if (!hide || self != ffHud()) return NO;
    uint8_t *canvas = objAt(self, "Canvas");
    void *fcanvas = canvas ? *(void **)(canvas + 0x98) : NULL;
    if (!fcanvas || !gPushRelative || !gPopTransform) return NO;
    int *num = (int *)((uint8_t *)fcanvas + 0x40), before = *num;   // the transform stack's depth (section 3b)
    static const float gone[16] = { 0,0,0,0,  0,0,0,0,  0,0,1,0,  -1e5f,-1e5f,0,1 };
    gPushRelative(fcanvas, gone);
    ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
    if (*num == before + 1) POP_XFORM(canvas);
    else { static int n; if (++n <= 5) LOG(@"options: the canvas transforms changed under a hidden HUD call (%d, expected %d): left as they are", *num, before + 1); }
    static int logged; if (logged < 3) { logged++; LOG(@"options: HUD drawing hidden (%@)", fnameStr(name)); }
    return YES;
}

// ---- 3g (continued). The iPad's health numbers, with room at the screen's edges (26 October 2026; FIXES.md 77) ----
// The iPad has no side insets, so its health numbers sat at the very edges. By choice (FIXES.md 77): the numbers at 80 %, each about
// its outer end (it's pinned to its bar's outer end: SwordHudHealthBar.Init puts its text box 1 unit in from the bar) and
// the middle of its box. Each number (SwordHudHealthBar.DrawText, which renders its SwordDrawText, DrawStats) runs under
// that canvas transform. The bars, the band and everything tapped stay. Not chosen: also moving them in by the devs'
// own unused indent (Init's XIndent = 20 units of 480, behind a test that is never true): INDENT 19.
#define IBFIX_PAD_NUMBER_SCALE  0.8f                  // by choice (FIXES.md 77)
#define IBFIX_PAD_NUMBER_INDENT 0.0f                  // units of 480 across; by choice: smaller only, not moved in
static BOOL padNumberCall(void *self, void *stack, void *result, int name) {
    static int nText = -2;
    if (!gIPadFill || !self) return NO;
    if (nText == -2) nText = nameIndex("DrawText");
    if (name != nText || name < 0 || !isClass(self, "SwordHudHealthBar")) return NO;
    uint8_t *hud = ffHud(), *canvas = hud ? objAt(hud, "Canvas") : NULL, *text = objAt(self, "DrawStats");
    void *fcanvas = canvas ? *(void **)(canvas + 0x98) : NULL;
    int oP = text ? poff(CLS(text), "BoundingBoxPos") : -1, oS = text ? poff(CLS(text), "BoundingBoxSize") : -1;
    float clipX = canvas ? *(float *)(canvas + 0x70) : 0;
    if (!fcanvas || oP < 0 || oS < 0 || clipX <= 0 || !gPushRelative || !gPopTransform) return NO;
    float *pos = (float *)(text + oP), *size = (float *)(text + oS);
    BOOL left = pos[0] + size[0] / 2 < clipX / 2;                     // the hero's, pinned left; the enemy's, right
    float k = IBFIX_PAD_NUMBER_SCALE, d = IBFIX_PAD_NUMBER_INDENT * clipX / 480;
    float ax = left ? pos[0] : pos[0] + size[0], ay = pos[1] + size[1] / 2;
    float m[16] = { k,0,0,0,  0,k,0,0,  0,0,1,0,  ax * (1 - k) + (left ? d : -d), ay * (1 - k),0,1 };
    int *num = (int *)((uint8_t *)fcanvas + 0x40), before = *num;   // the transform stack's depth (section 3b)
    gPushRelative(fcanvas, m);
    ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
    if (*num == before + 1) POP_XFORM(canvas);
    else { static int n; if (++n <= 5) LOG(@"iPad: the canvas transforms changed under a health number (%d, expected %d): left as they are", *num, before + 1); }
    static int logged; if (logged < 2) { logged++; LOG(@"iPad: health number (%@) at %.0f %% of its size, %.0f px in from its bar's end (box %.0f,%.0f %.0fx%.0f)",
        left ? @"hero" : @"enemy", k * 100, d, pos[0], pos[1], size[0], size[1]); }
    return YES;
}

// ---- 4q. "The God King observing you": the devs' unused film, behind a hidden circle at the bridge (FIXES.md 66) ----
// The film (Birthright_P SeqAct_Interp_36, the camera rising up the great tower) has a start nothing leads to
// (SeqAct_StartCinematicMode_10), and its end leads to the bridge's save point (SeqAct_StartChoiceMode_32, its camera named
// "Click - ENEMY or GOD KING OBSERVING YOU"): its circle was never placed. By choice (FIXES.md 66): a hidden circle on the
// tower, seen looking up from the bridge: the castle's one unused circle, SwordMobileTouchActor_43, freed from CameraActor_4
// and moved 50 units out from the tower's arched window, shown (the game's Toggle) while the bridge's fight circle
// (SwordMobileTouchActor_7) shows outside a fight. A tap reaches OnMobileTouch through AActor::ProcessEvent (slot 0x208 of
// 0x100b8b770, wrapped here) and does what a circle's tap does: the save point's OnChoiceMade, its camera film stopped
// (SeqAct_Interp_12 input 2), the film's start given an impulse (ForceActivateInput); the devs' link brings him back after.
#define IB1_TOUCHACTOR_PE_SLOT (IB1_TOUCHACTOR_VTABLE + 0x208)
static void (*gOrigTouchActorPE)(void *, void *, void *, void *);
static ObjRef gGKCircle, gGKBridge, gGKStart, gGKSave, gGKSaveFilm, gGKFilm;
static BOOL gGKOn, gGKPlaced;
static CFAbsoluteTime gGKWatchedAt;                                    // 0: look again at once
static BOOL gWorldTouchLine;                                           // 4r: the game's own tap line is running
static ObjRef gGateCircle; static BOOL gGateOn;                        // 4u: the way back from the dungeon
static void gateTapped(void);
static void preloadNextFight(const char *saveName, NSString *why);     // 4y
static const float kGKSpot[3] = { 3279.0f, -15640.0f, -9900.0f };
static const float kGKCamera[3] = { 2441.5f, -13226.7f, -14526.0f };   // the bridge save point's camera (SeqAct_Interp_12)
static ObjRef namedObject(const char *cls, const char *name) {           // the live object of that class and name
    void *found[160]; int n = ibfix_objects_of_class(cls, found, 160);
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    for (int i = 0; i < n; i++) if ([ibfix_objname(found[i]) isEqualToString:@(name)]) {
        int idx = *(int *)((uint8_t *)found[i] + 0x38);
        if (idx >= 0 && idx < objs->num) return (ObjRef){ found[i], idx, CLS(found[i]) };
    }
    return (ObjRef){ 0 };
}
static BOOL callNoArgs(void *obj, const char *fnName) {
    uint8_t *fn = obj ? findFunction(obj, fnName) : NULL;
    if (!fn || *(uint16_t *)(fn + 0xe2) > 64) return NO;
    uint8_t parms[64] = {0}; processEvent(obj, fn, parms); return YES;
}
static BOOL callIntArg(void *obj, const char *fnName, const char *arg, int v) {
    uint8_t *fn = obj ? findFunction(obj, fnName) : NULL; int o = fn ? propertyOffset(fn, arg) : -1;
    if (!fn || o < 0 || *(uint16_t *)(fn + 0xe2) > 64) return NO;
    uint8_t parms[64] = {0}; *(int *)(parms + o) = v; processEvent(obj, fn, parms); return YES;
}
static BOOL circleToggle(void *circle, BOOL on) {
    uint8_t *fn = circle ? findFunction(circle, "Toggle") : NULL; int o; uint32_t m;
    if (!fn || !boolProp(fn, "bTurnOn", &o, &m) || *(uint16_t *)(fn + 0xe2) > 64) return NO;
    uint8_t parms[64] = {0}; if (on) *(uint32_t *)(parms + o) |= m;
    processEvent(circle, fn, parms); return YES;
}
static void godKingPlace(uint8_t *c) {                                    // freed from its old camera, onto the tower
    uint8_t *setBase = findFunction(c, "SetBase"), *setLoc = findFunction(c, "SetLocation");
    int oLoc = setLoc ? propertyOffset(setLoc, "NewLocation") : -1, oPos = poff(CLS(c), "Location");
    if (setBase && *(uint16_t *)(setBase + 0xe2) <= 64) { uint8_t parms[64] = {0}; processEvent(c, setBase, parms); }
    if (setLoc && oLoc >= 0 && *(uint16_t *)(setLoc + 0xe2) <= 64) { uint8_t parms[64] = {0}; memcpy(parms + oLoc, kGKSpot, 12); processEvent(c, setLoc, parms); }
    float *pos = oPos >= 0 ? (float *)(c + oPos) : NULL;
    if (pos && (fabsf(pos[0] - kGKSpot[0]) > 1 || fabsf(pos[1] - kGKSpot[1]) > 1 || fabsf(pos[2] - kGKSpot[2]) > 1)) {
        LOG(@"God King circle: SetLocation left it at %.0f,%.0f,%.0f: placed directly", pos[0], pos[1], pos[2]);
        memcpy(pos, kGKSpot, 12);
    }
    // The circle is drawn where its sprite component is (ASwordMobileTouchActor::NativePostRenderFor projects the
    // AnimatedSprite's LocalToWorld, not the actor's Location), so the components are brought up to date with the game's
    // own ForceUpdateComponents, then checked, and the sprite's matrix moved directly if the game still left it behind
    // (this circle refuses SetLocation).
    uint8_t *upd = findFunction(c, "ForceUpdateComponents"); int oT; uint32_t mT;
    if (upd && boolProp(upd, "bTransformOnly", &oT, &mT) && *(uint16_t *)(upd + 0xe2) <= 64) {
        uint8_t parms[64] = {0}; *(uint32_t *)(parms + oT) |= mT; processEvent(c, upd, parms);
    }
    uint8_t *spr = objAt(c, "AnimatedSprite");
    int oM = spr ? poff(CLS(spr), "LocalToWorld") : -1;
    if (oM >= 0) {
        float *m = (float *)(spr + oM);
        if (fabsf(m[12] - kGKSpot[0]) > 1 || fabsf(m[13] - kGKSpot[1]) > 1 || fabsf(m[14] - kGKSpot[2]) > 1) {
            LOG(@"God King circle: its sprite was still at %.0f,%.0f,%.0f: moved directly", m[12], m[13], m[14]);
            m[12] = kGKSpot[0]; m[13] = kGKSpot[1]; m[14] = kGKSpot[2];
        } else LOG(@"God King circle: its sprite is on the tower too");
    } else LOG(@"God King circle: no sprite component found");
    // Its size: the game draws a circle as a sign of a set size in the world (half its width = DrawScale x the sprite's
    // pulsing AnimatedScale x 86 units, read in NativePostRenderFor every frame), so on screen it shrinks with distance.
    // So its DrawScale grows with the distance, to show the same size as the bridge's own circle.
    int oDS = poff(CLS(c), "DrawScale");
    float *bpos = gGKBridge.obj && oPos >= 0 ? (float *)((uint8_t *)gGKBridge.obj + oPos) : NULL;
    if (oDS >= 0 && bpos) {
        float bs = *(float *)((uint8_t *)gGKBridge.obj + oDS), dOurs = 0, dBridge = 0;
        for (int i = 0; i < 3; i++) { dOurs += powf(kGKSpot[i] - kGKCamera[i], 2); dBridge += powf(bpos[i] - kGKCamera[i], 2); }
        dOurs = sqrtf(dOurs); dBridge = sqrtf(dBridge);
        if (bs > 0 && dBridge > 50) {
            float k = dOurs / dBridge;
            *(float *)(c + oDS) = bs * k;
            LOG(@"God King circle: size %.2f (the bridge circle's %.2f at %.0f units; this one at %.0f)", bs * k, bs, dBridge, dOurs);
            // Its tap area is this drawn size too, as for every circle (4r).
        }
    } else LOG(@"God King circle: size left as it was (no DrawScale or bridge circle)");
    if (pos) LOG(@"God King circle: %@ on the tower at %.0f,%.0f,%.0f", ibfix_objname(c), pos[0], pos[1], pos[2]);
}
static BOOL actorPostRendered(uint8_t *hud, void *actor) {
    int o = poff(CLS(hud), "PostRenderedActors");
    if (o < 0 || !actor) return NO;
    struct { void **data; int num, max; } *a = (void *)(hud + o);
    for (int i = 0; i < a->num && i < 64; i++) if (a->data[i] == actor) return YES;
    return NO;
}
// Once per run (by choice, FIXES.md 66). A run is one bloodline. Kept on the phone, per save slot: the bloodline's numbers
// (GenerationCount, IsInNegativeBloodline, UberBossKillCount) and the run's fight count when the film was watched. A
// new run (SwordPC.GenerateRandomWorld: GenerationCount + 1, PlayThroughFightFinishedCount back to 0) or a restarted
// bloodline (the fight count falls below the one kept) brings the circle back.
static NSString *const kGKWatched = @"ibfixGodKingWatched";
static NSArray *godKingRun(uint8_t *pc, NSString **slot) {
    uint8_t *save = objAt(pc, "CommonSaveFile"), *pawn = objAt(pc, "PlayerPawn");
    int oS = save ? poff(CLS(save), "SwordSaveIndex") : -1;
    *slot = [NSString stringWithFormat:@"%d", oS >= 0 ? *(int *)(save + oS) : -1];
    static const char *names[4] = { "GenerationCount", "IsInNegativeBloodline", "UberBossKillCount", "PlayThroughFightFinishedCount" };
    NSMutableArray *r = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        int o = pawn ? poff(CLS(pawn), names[i]) : -1;
        [r addObject:@(o >= 0 ? *(int *)(pawn + o) : -1)];
    }
    return r;
}
static BOOL godKingWatched(uint8_t *pc) {
    NSString *slot; NSArray *r = godKingRun(pc, &slot);
    NSArray *e = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kGKWatched][slot];
    if (e.count != 4) return NO;
    for (int i = 0; i < 3; i++) if (![e[i] isEqual:r[i]]) return NO;
    return [e[3] intValue] <= [r[3] intValue];
}
static void godKingMarkWatched(uint8_t *pc) {
    NSString *slot; NSArray *r = godKingRun(pc, &slot);
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [[ud dictionaryForKey:kGKWatched] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[slot] = r; [ud setObject:d forKey:kGKWatched];
    LOG(@"God King circle: watched in this run (slot %@, bloodline %@ %@ %@, fight %@): gone until the next run", slot, r[0], r[1], r[2], r[3]);
}
// Every frame: the circle on while the bridge's own circle shows (outside a fight, not yet watched in this run), off
// otherwise.
static void godKingTick(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    static CFAbsoluteTime lastScan;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if ((!refLive(&gGKBridge) || !refLive(&gGKCircle)) && t - lastScan > 3) {     // looked for again after a level change
        lastScan = t;
        gGKBridge = namedObject("SwordMobileTouchActor", "SwordMobileTouchActor_7");
        gGKCircle = namedObject("SwordMobileTouchActor", "SwordMobileTouchActor_43");
        gGKPlaced = gGKOn = NO;
        if (!gGKCircle.obj) return;
        if (*(void **)gGKCircle.obj != (void *)(IB1_TOUCHACTOR_VTABLE + _dyld_get_image_vmaddr_slide(0)))
            LOG(@"God King circle: its vtable is not SwordMobileTouchActor's: taps won't be seen");
    }
    if (!refLive(&gGKBridge) || !refLive(&gGKCircle)) return;
    BOOL fight = NO; boolGet(pc, "bInBossFight", &fight);
    static BOOL watched;                                                      // looked up at most once a second
    if (t - gGKWatchedAt > 1) { gGKWatchedAt = t; watched = godKingWatched(pc); }
    // Shown 1.5 s after the bridge's own circles appear, the run read again then: when a saved game loads at the
    // bridge, its circles come before the save's bloodline numbers are in place.
    static CFAbsoluteTime bridgeSince;
    BOOL bridgeNow = !fight && actorPostRendered(hud, gGKBridge.obj);
    if (!bridgeNow) bridgeSince = 0; else if (!bridgeSince) bridgeSince = t;
    BOOL bridge = bridgeNow && !watched;
    if (bridge && !gGKOn && t - bridgeSince >= 1.5) {
        gGKWatchedAt = t; watched = godKingWatched(pc);
        if (!watched) {
            if (!gGKPlaced) { godKingPlace(gGKCircle.obj); gGKPlaced = YES; }
            if (circleToggle(gGKCircle.obj, YES)) { gGKOn = YES; LOG(@"God King circle: shown at the bridge (look up)"); }
        }
    } else if (!bridge && gGKOn) {
        circleToggle(gGKCircle.obj, NO); gGKOn = NO;
        LOG(@"God King circle: hidden (%@)", watched ? @"watched in this run" : @"the bridge's circles are gone");
    }
#ifdef IBFIX_SNAPS
    if (gGKOn) {        // where and how big the game drew it (NativePostRenderFor writes DrawPos and DrawSize every frame)
        static CFAbsoluteTime lastDraw; static float lastX = -9999;
        void *cls = CLS(gGKCircle.obj);
        int oP = poff(cls, "DrawPos"), oS = poff(cls, "DrawSize");
        if (oP >= 0 && oS >= 0 && t - lastDraw > 2) {
            float *p = (float *)((uint8_t *)gGKCircle.obj + oP), *s = (float *)((uint8_t *)gGKCircle.obj + oS);
            float *bs = (float *)((uint8_t *)gGKBridge.obj + oS);
            if (fabsf(p[0] - lastX) > 20 && p[0] > -s[0] && p[1] > -s[1] && p[0] < 4000 && p[1] < 2000) {   // on screen
                lastX = p[0]; lastDraw = t;
                LOG(@"God King circle: drawn at %.0f,%.0f, %.0f x %.0f pixels (the bridge circle %.0f x %.0f; in the HUD's list %@)",
                    p[0], p[1], s[0], s[1], bs[0], bs[1], actorPostRendered(hud, gGKCircle.obj) ? @"yes" : @"NO");
            }
        }
    }
#endif
}
#ifdef IBFIX_SNAPS
// Test builds: the test cheat "Back To Last Save Point" also forgets that this slot's run has watched the film, so the
// circle can be tried again without starting a new bloodline (4o).
static void godKingForget(uint8_t *pc) {
    NSString *slot; godKingRun(pc, &slot);
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [[ud dictionaryForKey:kGKWatched] mutableCopy];
    if (d[slot]) { [d removeObjectForKey:slot]; [ud setObject:d forKey:kGKWatched]; LOG(@"God King circle: back for slot %@ (test cheat)", slot); }
    gGKWatchedAt = 0;
}
#endif
static void godKingTapped(void) {
    gGKOn = NO;
    circleToggle(gGKCircle.obj, NO);
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (pc) godKingMarkWatched(pc);
    gGKWatchedAt = 0;
    // The film was never played by the devs, so it isn't set to rewind: left on its last frame after a showing, it ends
    // the moment it is started again. Set as the devs set their replayed films, so each run's showing plays in full.
    if (!refLive(&gGKFilm)) gGKFilm = namedObject("SeqAct_Interp", "SeqAct_Interp_36");
    BOOL rewind = refLive(&gGKFilm) && boolSet(gGKFilm.obj, "bRewindOnPlay", YES);
    if (!refLive(&gGKSave)) gGKSave = namedObject("SeqAct_StartChoiceMode", "SeqAct_StartChoiceMode_32");
    if (!refLive(&gGKSaveFilm)) gGKSaveFilm = namedObject("SeqAct_Interp", "SeqAct_Interp_12");
    if (!refLive(&gGKStart)) gGKStart = namedObject("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_10");
    BOOL choice = refLive(&gGKSave) && callNoArgs(gGKSave.obj, "OnChoiceMade");
    BOOL stopped = refLive(&gGKSaveFilm) && callIntArg(gGKSaveFilm.obj, "ForceActivateInput", "InputIdx", 2);
    BOOL started = refLive(&gGKStart) && callIntArg(gGKStart.obj, "ForceActivateInput", "InputIdx", 0);
    preloadNextFight("SeqAct_StartChoiceMode_32", @"God King circle");   // the bridge's fight, for coming back (4y's helper)
    LOG(@"God King circle: tapped: save point's circles off %@, its camera film stopped %@, the film set to rewind %@, started %@",
        choice ? @"yes" : @"NO", stopped ? @"yes" : @"NO", rewind ? @"yes" : @"NO", started ? @"yes" : @"NO");
}
#ifdef IBFIX_SNAPS
static NSString *circleName(void *obj) {                 // test logs: the circle, and the boss it belongs to
    int oO = poff(CLS(obj), "Owner"); void *owner = oO >= 0 ? *(void **)((uint8_t *)obj + oO) : NULL;
    return owner ? [NSString stringWithFormat:@"%@ of %@", ibfix_objname(obj), ibfix_objname(owner)] : ibfix_objname(obj);
}
#endif
static void my_touchActorPE(void *obj, void *fn, void *parms, void *res) {
    NAME_ONCE(nameTouch, "OnMobileTouch");
    BOOL touch = fn && *(int *)((uint8_t *)fn + 0x48) == nameTouch;
    if (touch && gWorldTouchLine) {                      // 4r: the game's line hit a circle where it isn't drawn
#ifdef IBFIX_SNAPS
        LOG(@"circle taps: the game's line reached %@ outside its drawn circle: ignored", ibfix_objname(obj));
#endif
        return;
    }
    gOrigTouchActorPE(obj, fn, parms, res);
#ifdef IBFIX_SNAPS
    if (touch) LOG(@"circle taps: %@ taken (%@)", circleName(obj), gWorldTouchLine ? @"the game's line" : @"the drawn circle");   // 4r
#endif
    if (touch && obj == gGateCircle.obj && gGateOn) { gateTapped(); return; }   // 4u
    if (!touch || obj != gGKCircle.obj || !gGKOn) return;
    godKingTapped();
}
// ---- 4r. Every circle's tap area is the circle as drawn (26 October 2026; FIXES.md 68) ----
// A circle (SwordMobileTouchActor; the bosses' weak spots, SwordBossTouchActor, share its code) is a picture the HUD
// draws over the scene, growing from 0.2 to 0.5 of its size each one-second pulse (AnimatedScale). Taps were tested two
// ways, neither matching what is seen: in fights (TouchMobileTouchActor -> IsPointInsideSprite) against the box drawn that
// frame; at save points (ProcessWorldTouch, 0x100884f0c) by a line from the camera that must hit the circle's collision
// cylinder, not scaled with it. Now both use the full box drawn (by choice, FIXES.md 68): once 3c stores the box (DrawPos,
// DrawSize) it is grown about its centre to the pulse's largest, which IsPointInsideSprite reads; ProcessWorldTouch (slot
// 0x2e0 of both input classes' vtables) tests every drawn circle first, calling the nearest one's OnMobileTouch as the
// engine does. Only with none under the finger does the game's line run, and a circle it reaches outside its box is ignored.
#define IB1_PLAYERINPUT_VTABLE      0x100b72910ULL   // MobilePlayerInput
#define IB1_SWORDPLAYERINPUT_VTABLE 0x100b8be50ULL   // SwordPlayerInput (the game's own)
#define IB1_PROCESSWORLDTOUCH       0x100884f0cULL
#define VT_PROCESSWORLDTOUCH        0x2e0
typedef uint32_t (*WorldTouchFn)(void *self, void *zone, float x, float y, uint8_t eventType);
static WorldTouchFn gOrigWorldTouch;
static void circleFullBox(uint8_t *a) {
    void *cls = CLS(a);
    int oP = poff(cls, "DrawPos"), oS = poff(cls, "DrawSize"), oT = poff(cls, "CurrentTime");
    uint8_t *spr = objAt(a, "AnimatedSprite");
    int oC = spr ? poff(CLS(spr), "AnimatedScale") : -1;
    if (oP < 0 || oS < 0 || oT < 0 || oC < 0) return;
    struct { uint8_t *data; int num, max; } *pts = (void *)(spr + oC);   // points of 20 bytes: InVal, OutVal, ...
    if (!pts->data || pts->num < 1 || pts->num > 32) return;
    #define PT_IN(i)  (*(float *)(pts->data + 20 * (i)))
    #define PT_OUT(i) (*(float *)(pts->data + 20 * (i) + 4))
    float t = *(float *)(a + oT), peak = PT_OUT(0), cur = PT_OUT(pts->num - 1);
    for (int i = 1; i < pts->num; i++) if (PT_OUT(i) > peak) peak = PT_OUT(i);
    if (t <= PT_IN(0)) cur = PT_OUT(0);                         // the size the game drew: straight between points
    else for (int i = 0; i + 1 < pts->num; i++) if (t < PT_IN(i + 1)) {
        float span = PT_IN(i + 1) - PT_IN(i);
        cur = span > 0 ? PT_OUT(i) + (PT_OUT(i + 1) - PT_OUT(i)) * (t - PT_IN(i)) / span : PT_OUT(i + 1);
        break;
    }
    #undef PT_IN
    #undef PT_OUT
    float *p = (float *)(a + oP), *sz = (float *)(a + oS);
    if (sz[0] <= 0 || sz[1] <= 0 || cur < 0.01f || peak <= cur) return;
    float k = peak / cur, cx = p[0] + sz[0] / 2, cy = p[1] + sz[1] / 2;
    sz[0] *= k; sz[1] *= k; p[0] = cx - sz[0] / 2; p[1] = cy - sz[1] / 2;
}
static uint32_t my_processWorldTouch(void *self, void *zone, float x, float y, uint8_t eventType) {
    uint8_t *hud = ffHud();
    int oL = hud ? poff(CLS(hud), "PostRenderedActors") : -1;
    if (oL < 0) return gOrigWorldTouch(self, zone, x, y, eventType);
    void *vt = (void *)(IB1_TOUCHACTOR_VTABLE + _dyld_get_image_vmaddr_slide(0));
    struct { uint8_t **data; int num, max; } *list = (void *)(hud + oL);
    uint8_t *best = NULL; float bestD = 1e30f; int drawn = 0;
    for (int i = 0; i < list->num && i < 64; i++) {
        uint8_t *a = list->data[i];
        if (!a || *(void **)a != vt || !(*(uint32_t *)(a + 0xf0) & 0x400)) continue;   // bEnableMobileTouch, as the engine
        void *cls = CLS(a);
        int oP = poff(cls, "DrawPos"), oS = poff(cls, "DrawSize");
        if (oP < 0 || oS < 0) continue;
        float *p = (float *)(a + oP), *sz = (float *)(a + oS);
        if (sz[0] <= 0 || sz[1] <= 0) continue;
        if (!circleDrawnRecently(a)) continue;                                          // 4r2: drawn this quarter second
        if (gRegionPx[2] > 0 && (sz[0] > gRegionPx[2] / 2 || sz[1] > gRegionPx[3] / 2)) continue;   // 4r2: no circle is that big
        drawn++;
        if (x < p[0] || y < p[1] || x > p[0] + sz[0] || y > p[1] + sz[1]) continue;   // IsPointInsideSprite's test
        float d = hypotf(x - (p[0] + sz[0] / 2), y - (p[1] + sz[1] / 2));
        if (d < bestD) { bestD = d; best = a; }
    }
    if (best) {
        uint8_t *fn = findFunction(best, "OnMobileTouch");
        int oPC = fn ? propertyOffset(fn, "InPC") : -1, oTL = fn ? propertyOffset(fn, "TouchLocation") : -1, oRV; uint32_t mRV;
        if (fn && oPC >= 0 && oTL >= 0 && boolProp(fn, "ReturnValue", &oRV, &mRV) && *(uint16_t *)(fn + 0xe2) <= 64) {
            uint8_t parms[64] = {0};
            *(void **)(parms + oPC) = *(void **)((uint8_t *)self + 0x40);          // the controller, as the engine passes
            ((float *)(parms + oTL))[0] = x; ((float *)(parms + oTL))[1] = y;
#ifdef IBFIX_SNAPS
            LOG(@"circle taps: tap at %.0f,%.0f on %@ (%.0f px from its middle)", x, y, ibfix_objname(best), bestD);
#endif
            processEvent(best, fn, parms);
            return (*(uint32_t *)(parms + oRV) & mRV) ? 1 : 0;
        }
    }
#ifdef IBFIX_SNAPS
    if (drawn) LOG(@"circle taps: tap at %.0f,%.0f is on none of the %d circles drawn", x, y, drawn);
#endif
    gWorldTouchLine = YES;
    uint32_t r = gOrigWorldTouch(self, zone, x, y, eventType);
    gWorldTouchLine = NO;
    return r;
}
#ifdef IBFIX_SNAPS
// Test builds: at every finger down and lift (snaps.m, the touch in screen pixels), each circle drawn on screen within
// twice its size of the finger: where it was drawn at that moment (its full box, as taps are tested), so taps on circles
// can be judged exactly, at save points and in fights (where the game tests the touch when the finger goes down).
void ibfix_circle_touch(float x, float y, BOOL down) {
    uint8_t *hud = ffHud();
    int oL = hud ? poff(CLS(hud), "PostRenderedActors") : -1;
    if (oL < 0) return;
    void *vt = (void *)(IB1_TOUCHACTOR_VTABLE + _dyld_get_image_vmaddr_slide(0));
    struct { uint8_t **data; int num, max; } *list = (void *)(hud + oL);
    for (int i = 0; i < list->num && i < 64; i++) {
        uint8_t *a = list->data[i];
        if (!a || *(void **)a != vt) continue;
        void *cls = CLS(a);
        int oP = poff(cls, "DrawPos"), oS = poff(cls, "DrawSize"), oO = poff(cls, "Owner");
        if (oP < 0 || oS < 0) continue;
        float *p = (float *)(a + oP), *sz = (float *)(a + oS);
        if (sz[0] <= 0 || sz[1] <= 0) continue;
        float x0 = p[0] + gTouchCircleMargin, y0 = p[1] + gTouchCircleMarginY, cx = x0 + sz[0] / 2, cy = y0 + sz[1] / 2, d = hypotf(x - cx, y - cy);
        if (d > sz[0] * 2) continue;
        BOOL in = x >= x0 && x <= x0 + sz[0] && y >= y0 && y <= y0 + sz[1];
        void *owner = oO >= 0 ? *(void **)(a + oO) : NULL;
        LOG(@"circle taps: finger %@ at %.0f,%.0f px by %@%@: drawn %.0f x %.0f px around %.0f,%.0f, %@, %.0f px from its middle",
            down ? @"down" : @"lifted", x, y, ibfix_objname(a), owner ? [NSString stringWithFormat:@" of %@", ibfix_objname(owner)] : @"",
            sz[0], sz[1], cx, cy, in ? @"inside" : @"outside", d);
    }
}
#endif
// ---- 4s. The first Deathless's death scene (26 October 2026; FIXES.md 69) ----
// The devs finished a scene for the Faun's win (Battle_10ft_Deathless SeqAct_Interp_24 "Death", ending in the console
// command StartNewCastleLevel: the next bloodline, as losing to the God King, the Mech or Zero gives), but nothing leads
// to its start (SeqAct_StartCinematicMode_4): the arena's "Player Death" (SeqEvent_BossEvents output 3, fired by
// SwordBoss.HandlePlayerDeath -> TriggerBossEvent(4)) is unconnected, and his boss data leaves bDontLetPlayerReallyDie off.
// Restored as the God King's death works: in his single-player fights the boss's and the knight's bDontLetPlayerReallyDie
// are set (SwordBoss copies it at the fight's start), so a lethal hit leaves 1 health, pauses the fight and fires "Player
// Death" instead of the loss screen; on it, in his arena, the scene's start gets its impulse. By choice (FIXES.md 69).
static NSString *const kFaunArena = @"Battle_10ft_Deathless";
static const int kFaunSceneStage = 2;                            // the stage spot the scene's cameras belong to
static ObjRef namedObjectIn(const char *cls, const char *name, NSString *level) {   // that object of that level
    static void *found[1024]; int n = ibfix_objects_of_class(cls, found, 1024);
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    for (int i = 0; i < n; i++) {
        if (![ibfix_objname(found[i]) isEqualToString:@(name)]) continue;
        const uint8_t *o = found[i];
        for (int k = 0; *(const uint8_t **)(o + 0x40) && k < 16; k++) o = *(const uint8_t **)(o + 0x40);
        int idx = *(int *)((uint8_t *)found[i] + 0x38);
        if ([ibfix_objname(o) isEqualToString:level] && idx >= 0 && idx < objs->num)
            return (ObjRef){ found[i], idx, CLS(found[i]) };
    }
    return (ObjRef){ 0 };
}
static BOOL faunFight(void *boss) {                              // the Faun's arena, from the single-player castle
    const uint8_t *sp, *arena = bossArena(boss, &sp), *castle = sp;
    for (int k = 0; castle && *(const uint8_t **)(castle + 0x40) && k < 16; k++) castle = *(const uint8_t **)(castle + 0x40);
    return arena && castle && [ibfix_objname(arena) isEqualToString:kFaunArena] && [ibfix_objname(castle) isEqualToString:@"Birthright_P"];
}
static void faunTick(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL; BOOL fight = NO, on = NO;
    if (!pc || !boolGet(pc, "bInBossFight", &fight) || !fight) return;
    uint8_t *boss = objAt(pc, "CurrentBoss"), *pawn = objAt(pc, "PlayerPawn");
    if (!boss || !pawn || !boolGet(pawn, "bDontLetPlayerReallyDie", &on) || on || !faunFight(boss)) return;
    if (boolSet(boss, "bDontLetPlayerReallyDie", YES) && boolSet(pawn, "bDontLetPlayerReallyDie", YES))
        LOG(@"Faun's death scene: on for this fight (if he wins, the devs' scene, then the next bloodline)");
}
#ifdef IBFIX_SNAPS
// Test builds: the scene photographed about 6 times a second (snaps.m, Documents/ibfix-snaps), to make a film of it.
static CFAbsoluteTime gFaunFilmAt;
static void faunSnapTick(void) {
    if (!gFaunFilmAt) return;
    static CFAbsoluteTime last; static int n;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (t - gFaunFilmAt > 10.5) { LOG(@"Faun's death scene: %d pictures taken", n); gFaunFilmAt = 0; n = 0; return; }
    if (t - last >= 1.0 / 6) { last = t; ibfix_snap([NSString stringWithFormat:@"faun-%03d-%05.2f", n++, t - gFaunFilmAt]); }
}
#endif
static void faunPlayerDeath(void *boss) {                         // after the game's TriggerBossEvent_Internal(4)
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL, *pawn = pc ? objAt(pc, "PlayerPawn") : NULL;
    BOOL on = NO;
    if (!faunFight(boss)) return;
    if (!pawn || !boolGet(pawn, "bDontLetPlayerReallyDie", &on) || !on) {   // the loss screen has it: no scene over it
        LOG(@"Faun's death scene: you fell before it was switched on: the ordinary loss screen"); return;
    }
    // The scene's cameras are the fight's cameras for stage spot 2 (SeqVar_BossCamera_13 and _3: BossStageIdx 2; the
    // Faun's spawn point keeps four spots, TransitionLocations[0-3]), while the fighters stand wherever the fight is. So
    // first, as the game does before each of its own scenes (TriggerBossEvent_Internal: SetupBattlePositions(Enemy,
    // GetCurrentStage(), true)), both are put on their marks, for the scene's spot.
    uint8_t *setup = findFunction(boss, "SetupBattlePositions"); int oSPre; uint32_t mSPre;
    int oSPawn = setup ? propertyOffset(setup, "PlayerPawn") : -1, oSIdx = setup ? propertyOffset(setup, "StageIdx") : -1;
    BOOL placed = NO;
    if (setup && oSPawn >= 0 && oSIdx >= 0 && boolProp(setup, "bIsPreTransition", &oSPre, &mSPre) && *(uint16_t *)(setup + 0xe2) <= 128) {
        uint8_t parms[128] = {0};
        *(void **)(parms + oSPawn) = pawn; *(int *)(parms + oSIdx) = kFaunSceneStage; *(uint32_t *)(parms + oSPre) |= mSPre;
        processEvent(boss, setup, parms); placed = YES;
    }
    LOG(@"Faun's death scene: both fighters %@ on stage spot %d, where its cameras are", placed ? @"put" : @"NOT put (SetupBattlePositions not found)", kFaunSceneStage);
    ObjRef start = namedObjectIn("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_4", kFaunArena);
    ObjRef film = namedObjectIn("SeqAct_Interp", "SeqAct_Interp_24", kFaunArena);
    if (film.obj) boolSet(film.obj, "bRewindOnPlay", YES);       // never played by the devs (as 4q)
    BOOL started = start.obj && callIntArg(start.obj, "ForceActivateInput", "InputIdx", 0);
#ifdef IBFIX_SNAPS
    if (started && ibfix_auto_photos()) gFaunFilmAt = CFAbsoluteTimeGetCurrent();
#endif
    LOG(@"Faun's death scene: you fell to %@: the devs' scene %@", ibfix_objname(boss), started ? @"started" : @"NOT started (its start wasn't found)");
}
// ---- 4t. A sped-up film never cuts a spoken line off (26 October 2026; FIXES.md 70) ----
// A film's sound track plays one sound at a time: a key starting a new sound stops the one still playing
// (InterpTrackInstSound's one PlayAudioComp). The devs set many arena films to play fast (SeqAct_Interp.PlayRate 1.1 or
// 1.2), which brings every key sooner while recorded speech plays at its own speed, so lines written to follow one
// another overlap (tools/study/speechcuts.py: only the Faun's intro, Battle_10ft_Deathless SeqAct_Interp_10, is cut).
// So, for any film playing at another speed: when the next key on a track starts a spoken line (a wave with subtitles,
// 4j) while the spoken line before it would still be playing, that key is moved so the real gap is the one the devs
// wrote, (t2 - t1) x rate after the first. Done once to the level's data when the film starts (recorded per track, so a
// reloaded level gets it again); logged.
typedef struct { float time, volume, pitch; uint8_t *sound; } SoundKey;  // InterpTrackSound.SoundTrackKey
static uint8_t *cueWave(uint8_t *node, int depth) {                    // the first SoundNodeWave under a cue's node
    if (!node || depth > 8 || !isLiveObject(node)) return NULL;
    if (isClass(node, "SoundNodeWave")) return node;
    int oC = poff(CLS(node), "ChildNodes");
    if (oC < 0) return NULL;
    struct { uint8_t **data; int num, max; } *ch = (void *)(node + oC);
    for (int i = 0; i < ch->num && i < 16; i++) { uint8_t *w = cueWave(ch->data[i], depth + 1); if (w) return w; }
    return NULL;
}
static BOOL cueSpoken(uint8_t *cue, float *dur) {     // a spoken line, and its recording's length
    if (!cue || !isLiveObject(cue)) return NO;
    void *cc = CLS(cue); int oF = poff(cc, "FirstNode"), oD = poff(cc, "Duration");
    uint8_t *wave = oF >= 0 ? cueWave(*(uint8_t **)(cue + oF), 0) : NULL;
    if (!isSpeech(wave)) return NO;
    // The wave's own Duration, not the cue's: a cue can keep an older, shorter length than the recording that ships.
    int oW = poff(CLS(wave), "Duration");
    *dur = oW >= 0 ? *(float *)(wave + oW) : 0;
    if (*dur <= 0 && oD >= 0) *dur = *(float *)(cue + oD);
    return *dur > 0;
}
static void speechGapTick(void) {
    static NSMutableDictionary<NSValue *, NSNumber *> *done;           // track -> the key time it was given
    if (!done) done = [NSMutableDictionary dictionary];
    static int oKey = -2;
    for (int f = 0; f < gNumFilms; f++) {
        FILM_STATE(f);
        if (gi->num <= 0 || gi->num > 64 || fabsf(rate - 1) < 0.01f || rate <= 0) continue;
        for (int g = 0; g < gi->num; g++) {
            uint8_t *inst = gi->data[g]; int oG = inst ? poff(CLS(inst), "Group") : -1;
            uint8_t *group = oG >= 0 ? *(uint8_t **)(inst + oG) : NULL;
            int oT = group ? poff(CLS(group), "InterpTracks") : -1;
            if (oT < 0) continue;
            struct { uint8_t **data; int num, max; } *tracks = (void *)(group + oT);
            for (int k = 0; k < tracks->num && k < 32; k++) {
                uint8_t *tr = tracks->data[k];
                if (!tr || !isClass(tr, "InterpTrackSound")) continue;
                if (oKey == -2) oKey = poff(CLS(tr), "Sounds");
                if (oKey < 0) return;
                struct { SoundKey *data; int num, max; } *keys = (void *)(tr + oKey);
                NSValue *v = [NSValue valueWithPointer:tr];
                for (int i = 0; i + 1 < keys->num && keys->num < 64; i++) {
                    SoundKey *a = &keys->data[i], *b = &keys->data[i + 1]; float dur;
                    if ([done[v] floatValue] == b->time || b->time <= pos || !cueSpoken(a->sound, &dur)) continue;
                    float d2; if (!cueSpoken(b->sound, &d2) || (b->time - a->time) / rate >= dur) continue;
                    float want = a->time + (b->time - a->time) * rate;
                    if (i + 2 < keys->num && want >= keys->data[i + 2].time) continue;   // keep the keys in order
                    LOG(@"spoken lines: %@ (plays at %.2f): %@ moved from %.2f to %.2f s, so %@ (%.1f s) isn't cut off: %.2f s apart in real time, as written",
                        ibfix_objname(film), rate, ibfix_objname(b->sound), b->time, want, ibfix_objname(a->sound), dur, want / rate - a->time / rate);
                    b->time = want; done[v] = @(want);
                }
            }
        }
    }
}
// ---- 5d. Other sounds softer while skip is held (29 October 2026; FIXES.md 82) ----
// Holding skip runs the game about 24 times faster (FIXES.md 26), so a frame's 0.4 s of game time starts all its sounds
// at once: they pile up, then play out. By choice (FIXES.md 82): softer. While skip is held every sound but the music
// and spoken lines (78 silences those) plays at kFFSoftGain: one already playing eases down over 0.08 s and back up over
// 0.4 s after let-go (off for 0.06 s: it goes off for a frame between two films); one started under skip stays down until
// it ends (the burst plays out for about 2 s), unless still playing 2 s after let-go (back up over 1 s). A looping sound
// (AL_LOOPING, the place's background) comes back over 0.4 s like one playing before. Nothing is cut or started.
// Decided in 4j's my_sourceUpdate (every playing sound, every frame, under every screen) from 78's signs: the HUD's
// bFastForwardMode, or the game's speed at 500 or more.
#import <OpenAL/al.h>
static const float kFFSoftGain = 0.35f, kFFSoftDown = 0.08f, kFFSoftUp = 0.4f, kFFSoftLate = 2.0f, kFFSoftLateUp = 1.0f;
static BOOL gFFSoftOff;                                         // test builds: the capture's "as now" run
static BOOL skipOn(void) {      // fast-forward on (9b's skipHeld is only the finger on the button)
    BOOL mode = NO; uint8_t *hud = ffHud();
    if (hud && boolGet(hud, "bFastForwardMode", &mode) && mode) return YES;
    uint8_t *wi = WORLD_INFO();
    int oTD = wi ? poff(CLS(wi), "TimeDilation") : -1;
    return oTD >= 0 && *(float *)(wi + oTD) >= 500;
}
static BOOL gSoftHeld; static double gSoftLetGo;                 // skip held, for this rule; when it was last let go
static void ffSoftState(void) {                                 // worked out at most every 5 ms (game thread)
    static double lastAt, offSince;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - lastAt < 0.005) return;
    lastAt = now;
    if (skipOn()) {
        offSince = 0;
        if (!gSoftHeld) { gSoftHeld = YES; LOG(@"softer skip: skip held: other sounds to %.0f%%%@", kFFSoftGain * 100, gFFSoftOff ? @" (test: left as now)" : @""); }
    } else if (gSoftHeld) {
        if (!offSince) offSince = now;
        else if (now - offSince >= 0.06) {
            gSoftHeld = NO; gSoftLetGo = now;
            LOG(@"softer skip: let go: sounds playing before it back up over %.1f s, those it started stay soft (back over %.0f s if still on after %.0f s)", kFFSoftUp, kFFSoftLateUp, kFFSoftLate);
        }
    }
}
// The factor for one sound, eased per source (the engine's FALSoundSource; a new wave instance on it is a new sound).
static float ffSoftGain(void *src, uint8_t *wi) {
    typedef struct { void *src, *wi; float gain; double at; BOOL skipped, looked; } Soft;
    static Soft soft[64]; static int n;
    ffSoftState(); double now = CFAbsoluteTimeGetCurrent();
    BOOL softNow = gSoftHeld && !gFFSoftOff;
    Soft *e = NULL;
    for (int i = 0; i < n && !e; i++) if (soft[i].src == src) e = &soft[i];
    if (!e) {
        if (n < 64) e = &soft[n++];
        else { e = &soft[0]; for (int i = 1; i < n; i++) if (soft[i].at < e->at) e = &soft[i]; }
        e->src = src; e->wi = NULL;
    }
    if (e->wi != wi) {                                          // starting now: part of the skip if skip is held
        e->wi = wi; e->skipped = softNow; e->looked = NO; e->gain = softNow ? kFFSoftGain : 1;
    } else {
        if (e->skipped && !e->looked) {                         // from its second update on: does it loop?
            ALint loops = 0; alGetSourcei(*(ALuint *)((uint8_t *)src + 0x3c), AL_LOOPING, &loops);
            e->looked = YES; if (loops) e->skipped = NO;
#ifdef IBFIX_SNAPS
            static int logged; uint8_t *wave = *(uint8_t **)wi;
            if (logged++ < 60) LOG(@"softer skip: %@ started under skip%@", wave ? ibfix_objname(wave) : @"?", loops ? @", loops: back up with the scene" : @"");
#endif
        }
        float dt = fminf((float)(now - e->at), 0.1f), target = 1, up = kFFSoftUp;
        if (softNow) target = kFFSoftGain;
        else if (e->skipped && !gFFSoftOff) {
            if (now - gSoftLetGo < kFFSoftLate) target = kFFSoftGain; else up = kFFSoftLateUp;
        }
        if (target < e->gain) e->gain = fmaxf(target, e->gain - (1 - kFFSoftGain) * dt / kFFSoftDown);
        else e->gain = fminf(target, e->gain + (1 - kFFSoftGain) * dt / up);
        if (e->gain >= 1) e->skipped = NO;
    }
    e->at = now;
    return e->gain;
}
// ---- 4w. Spoken lines under fast-forward (29 October 2026; FIXES.md 78) ----
// Holding the skip button runs the game about 24 times faster (FIXES.md 26), but a recording always plays at its own
// speed, and a film's sound track plays one sound at a time (UInterpTrackSound::UpdateTrack, 0x1004227ac, plays the
// last key passed each frame and stops the one before): so lines were cut, overlapped, and the last one played from its
// beginning, behind the picture. Now, while fast-forward is on (the HUD's bFastForwardMode, or the game's speed at 500
// or more: a film with a slow-motion track sets the speed back every frame, FIXES.md 57):
// - a line being heard fades out over 0.1 s, and its subtitle goes with it;
// - a line that starts plays silent, with its subtitle taken off at once (before any frame draws it);
// - each keeps the place it would have reached at normal speed: (film position - its key) / PlayRate while its film's
//   track holds it, then plus the game time since once the film has let it go (a track the devs let play on after its
//   film, bContinueSoundOnMatineeEnd).
// When fast-forward has been off for 3 frames (it goes off for a frame between two films while the finger stays down),
// each silenced line whose place still falls before its last word picks up there: pulled back to the start of the
// word or the pause it falls in (ibfix/speechstarts.h, measured from the recordings by tools/study/speechff.py), moved
// there in OpenAL while it plays (AL_SEC_OFFSET; Apple's OpenAL ignores an offset set before a queued sound starts,
// checked on the Mac), faded in over 0.05 s, its subtitles queued again from that point through the game's own
// subtitle manager. A line whose place is past its last word stays silent: nothing plays until the next key. Lines are
// only silenced and moved forward, never started or stopped, so the game's own bookkeeping (the track's one sound, a
// film's end, a line playing on after its film, the subtitles' removal when a line ends) is left as it is.
#import <OpenAL/al.h>
#include "speechstarts.h"
#define IB1_SUBTITLE_MANAGER 0x100611fb0ULL   // FSubtitleManager::GetSubtitleManager() (made on first use)
#define IB1_SUBTITLES_QUEUE  0x10060f644ULL   // FSubtitleManager::QueueSubtitles(id, priority, bManualWordWrap, duration, cues)
#define IB1_SUBTITLES_KILL   0x10060f590ULL   // FSubtitleManager::KillSubtitles(id)
#define IB1_ALSOURCE_ID_READ 0x1008dae30ULL   // in FALSoundSource::Update: ldr w0, [x19, #0x3c], the OpenAL source
static const float kLineFadeOut = 0.1f, kLineFadeIn = 0.05f, kLineMaxPullBack = 0.8f;
enum { kLineHeard, kLineFadingOut, kLineSilent, kLineFadingIn };
typedef struct {
    uint8_t *wi, *comp, *wave;        // the line's wave instance (one play of it, also its subtitles' key), component, recording
    ALuint al;                        // the OpenAL source playing it
    int mode; float fade, fadeFrom, heardTo; double fadeAt, seenAt;
    float wouldBe, gameAt;            // where it would be at normal speed, and the game time that was worked out at
    BOOL placed;                      // wouldBe known (from its film, or from where it was when fast-forward began)
    BOOL resume; float resumeAt; double resumeAsked;   // to pick up at its next update
#ifdef IBFIX_SNAPS
    double checkAt; float checkWant;  // test builds: where it should be a moment after picking up
#endif
} SpokenLine;
static SpokenLine gLines[16]; static int gNumLines;
static BOOL gFFSpeechOK, gFFSpeech;   // the fix's checks passed; fast-forward on as far as spoken lines go
static void *(*gSubtitleManager)(void);
static void (*gQueueSubtitles)(void *mgr, intptr_t id, float priority, int manualWrap, float duration, void *cues);
static void (*gKillSubtitles)(void *mgr, intptr_t id);
static void hookSpokenLines(void) {
    static const uint8_t mgr[8] = {0xf4,0x4f,0xbe,0xa9, 0xfd,0x7b,0x01,0xa9}, queue[8] = {0xe9,0x23,0xbb,0x6d, 0xf8,0x5f,0x01,0xa9},
                         kill[8] = {0xe8,0x03,0x01,0xaa, 0x09,0x48,0x40,0xb9}, idRead[4] = {0x60,0x3e,0x40,0xb9};
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!gOrigSourceUpdate || memcmp((void *)(IB1_SUBTITLE_MANAGER + slide), mgr, 8) || memcmp((void *)(IB1_SUBTITLES_QUEUE + slide), queue, 8)
        || memcmp((void *)(IB1_SUBTITLES_KILL + slide), kill, 8) || memcmp((void *)(IB1_ALSOURCE_ID_READ + slide), idRead, 4)) {
        LOG(@"spoken lines under fast-forward OFF: the game's code not as expected"); return;
    }
    gSubtitleManager = (void *)(IB1_SUBTITLE_MANAGER + slide);
    gQueueSubtitles = (void *)(IB1_SUBTITLES_QUEUE + slide);
    gKillSubtitles = (void *)(IB1_SUBTITLES_KILL + slide);
    gFFSpeechOK = YES;
    LOG(@"spoken lines under fast-forward ON (%d lines measured)", kNumSpeechStarts);
}
static const SpeechStarts *speechStarts(uint8_t *wave) {
    NSString *n = ibfix_objname(wave);
    for (int i = 0; i < kNumSpeechStarts; i++) if ([n caseInsensitiveCompare:@(kSpeechStarts[i].wave)] == NSOrderedSame) return &kSpeechStarts[i];
    return NULL;
}
// Where a line picks up for the place x (seconds into its recording): in a pause, right there (it's quiet, and the next
// word comes at its own time); in a word, the start of that word (the latest clean or soft point at or before x), at
// most 0.8 s back; else x itself (the fade-in covers it).
static float lineStart(const SpeechStarts *s, float x) {
    if (!s) return x;
    for (int i = 0; i < s->nPauses; i++) if (x >= s->pauses[2 * i] && x < s->pauses[2 * i + 1]) return x;
    float best = -1;
    for (int i = 0; i < s->nClean; i++) if (s->clean[i] <= x && s->clean[i] > best) best = s->clean[i];
    for (int i = 0; i < s->nSoft; i++) if (s->soft[i] <= x && s->soft[i] > best) best = s->soft[i];
    return best >= 0 && x - best <= kLineMaxPullBack ? best : x;
}
// The line's subtitles queued again as if it had started `at` seconds ago (the game queues them once, when the line's
// wave instance is made: USoundNodeWave's ParseNodes, 0x1003468b8, with the wave's Subtitles, Duration and the
// component's SubtitlePriority): the wave's times are moved for the call and put back. A cue already spoken gets time 0,
// which the game makes "now" (QueueSubtitles: a time from 0 to the duration gets the audio clock added, one past the
// duration the end, and one below 0 is left as it is), so it counts as passed and the one being spoken shows; the blank
// that ends them comes when the recording ends. Never below 0: the game's subtitle drawing (0x100611d6c) draws the
// current cue and then each cue before it while its time is 0 or less (the devs' way of showing lines together), so
// cues moved below 0 were all drawn, stacked above the one being spoken.
static void requeueSubtitles(SpokenLine *l, float at) {
    void *wc = CLS(l->wave), *cc = CLS(l->comp);
    int oSubs = poff(wc, "Subtitles"), oDur = poff(wc, "Duration"), oPrio = poff(cc, "SubtitlePriority");
    BOOL manual = NO; boolGet(l->wave, "bManualWordWrap", &manual);
    if (oSubs != 0x218 || oDur != 0xa0 || oPrio != 0x1b0) { LOG(@"spoken lines: subtitles not as expected (%#x %#x %#x): left off", oSubs, oDur, oPrio); return; }
    struct { uint8_t *data; int num, max; } *cues = (void *)(l->wave + oSubs);   // FSubtitleCue: FString Text, float Time at +0x10
    float dur = *(float *)(l->wave + oDur), prio = *(float *)(l->comp + oPrio), saved[32];
    if (cues->num <= 0 || cues->num > 32 || dur - at < 0.05f) return;
    for (int i = 0; i < cues->num; i++) { float *t = (float *)(cues->data + i * 0x18 + 0x10); saved[i] = *t; *t = fmaxf(*t - at, 0); }
    *(float *)(l->wave + oDur) = dur - at;
    gQueueSubtitles(gSubtitleManager(), (intptr_t)l->wi, prio, manual, dur - at, cues);
    for (int i = 0; i < cues->num; i++) *(float *)(cues->data + i * 0x18 + 0x10) = saved[i];
    *(float *)(l->wave + oDur) = dur;
}
#ifdef IBFIX_SNAPS
// Test builds: the subtitle the game holds for a line (its manager's TMap<id, FActiveSubtitle>, found as KillSubtitles
// finds it): the times of its cues against the audio clock, so the log shows which one is on screen.
static NSString *subtitleState(SpokenLine *l) {
    uint8_t *mgr = gSubtitleManager(); int size = *(int *)(mgr + 0x48);
    int *hash = *(int **)(mgr + 0x40) ? *(int **)(mgr + 0x40) : (int *)(mgr + 0x38);
    uint8_t *data = *(uint8_t **)mgr;
    for (int idx = size ? hash[(intptr_t)l->wi & (size - 1)] : -1, n = 0; idx != -1 && n < 64; n++) {
        uint8_t *e = data + idx * 0x30;
        if (*(void **)e != l->wi) { idx = *(int *)(e + 0x28); continue; }
        struct { uint8_t *data; int num, max; } *cues = (void *)(e + 0x18);
        void *w = *(void **)(IB1_GWORLD_GLOBAL + _dyld_get_image_vmaddr_slide(0));
        uint8_t *wi = w ? ((uint8_t *(*)(void *, int))(IB1_GETWORLDINFO + _dyld_get_image_vmaddr_slide(0)))(w, 0) : NULL;
        int oA = wi ? poff(CLS(wi), "AudioTimeSeconds") : -1;
        float now = oA >= 0 ? *(float *)(wi + oA) : 0; NSMutableString *s = [NSMutableString string]; int shown = -1;
        for (int i = 0; i < cues->num && i < 32; i++) {
            float t = *(float *)(cues->data + i * 0x18 + 0x10); if (t <= now) shown = i;
            [s appendFormat:@" %+.2f", t - now];
        }
        int drawn = shown >= 0 ? 1 : 0;                         // as the game draws: and each cue before while its time is <= 0
        for (int i = shown; i > 0 && *(float *)(cues->data + i * 0x18 + 0x10) <= 0; i--) drawn++;
        return [NSString stringWithFormat:@"subtitle cue %d of %d on screen, %d line%@ drawn (cue times from now:%@)", shown, cues->num, drawn, drawn == 1 ? @"" : @"s", s];
    }
    return @"no subtitle held";
}
#endif
static SpokenLine *spokenLine(uint8_t *wi) {
    for (int i = 0; i < gNumLines; i++) if (gLines[i].wi == wi) return &gLines[i];
    return NULL;
}
// 4j's per-frame update of a spoken line's sound (the audio update, game thread): the fade it plays at.
static float spokenLineFade(void *src, uint8_t *wi, uint8_t *wave) {
    if (!gFFSpeechOK) return 1;
    double now = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < gNumLines; ) {                                   // lines not updated for a second have ended
        if (now - gLines[i].seenAt > 1) gLines[i] = gLines[--gNumLines]; else i++;
    }
    SpokenLine *l = spokenLine(wi);
    if (!l) {
        if (gNumLines == 16) return 1;
        l = &gLines[gNumLines++]; memset(l, 0, sizeof *l);
        l->wi = wi; l->wave = wave; l->comp = *(uint8_t **)(wi + 0x10);
        l->mode = gFFSpeech ? kLineSilent : kLineHeard; l->fade = gFFSpeech ? 0 : 1;
        if (gFFSpeech) {
            gKillSubtitles(gSubtitleManager(), (intptr_t)wi);
            LOG(@"spoken lines: %@ started under fast-forward: silent, its subtitle taken off", ibfix_objname(wave));
        }
    }
    l->seenAt = now; l->al = *(ALuint *)((uint8_t *)src + 0x3c);
    if (l->resume) {
        float at = l->resumeAt + (float)(now - l->resumeAsked);
        float was = 0; alGetSourcef(l->al, AL_SEC_OFFSET, &was);
        if (fabsf(at - was) > 0.08f) alSourcef(l->al, AL_SEC_OFFSET, at);
        gKillSubtitles(gSubtitleManager(), (intptr_t)wi);
        requeueSubtitles(l, at);
        l->resume = NO; l->mode = kLineFadingIn; l->fadeAt = now; l->fade = 0;
        LOG(@"spoken lines: %@ picked up at %.2f s of its recording (it was at %.2f), faded in over %.2f s, its subtitles from there",
            ibfix_objname(wave), at, was, kLineFadeIn);
#ifdef IBFIX_SNAPS
        l->checkAt = now + 0.3; l->checkWant = at + 0.3f;
#endif
    }
    switch (l->mode) {
    case kLineFadingOut:
        l->fade = l->fadeFrom * fmaxf(0, 1 - (float)(now - l->fadeAt) / kLineFadeOut);
        if (l->fade <= 0) {
            l->mode = kLineSilent;
            alGetSourcef(l->al, AL_SEC_OFFSET, &l->heardTo);
            gKillSubtitles(gSubtitleManager(), (intptr_t)wi);
            LOG(@"spoken lines: %@ faded out at %.2f s of its recording, its subtitle taken off", ibfix_objname(wave), l->heardTo);
        }
        break;
    case kLineFadingIn:
        l->fade = fminf(1, (float)(now - l->fadeAt) / kLineFadeIn);
        if (l->fade >= 1) l->mode = kLineHeard;
        break;
    case kLineSilent: l->fade = 0; break;
    default: l->fade = 1;
    }
#ifdef IBFIX_SNAPS
    if (l->checkAt && now >= l->checkAt) {
        float pos = 0; alGetSourcef(l->al, AL_SEC_OFFSET, &pos);
        LOG(@"spoken lines: check: %@ at %.2f s of its recording (expected about %.2f), gain x%.2f; %@", ibfix_objname(wave), pos, l->checkWant, l->fade, subtitleState(l));
        if (ibfix_auto_photos()) ibfix_snap([NSString stringWithFormat:@"ffspeech-%@", ibfix_objname(wave)]);
        l->checkAt = 0;
    }
#endif
    return l->fade;
}
// The spoken line a film's track is playing: the last key at or before the film's position, if it holds this recording
// (else the track has moved on and the line is over: NO with *x huge).
static BOOL lineInFilm(SpokenLine *l, float *x) {
    for (int f = 0; f < gNumFilms; f++) {
        FILM_STATE(f);
        if (gi->num <= 0 || gi->num > 64 || rate <= 0) continue;
        for (int g = 0; g < gi->num; g++) {
            uint8_t *inst = gi->data[g]; void *ic = inst ? CLS(inst) : NULL;
            int oG = ic ? poff(ic, "Group") : -1, oTI = ic ? poff(ic, "TrackInst") : -1;
            uint8_t *group = oG >= 0 ? *(uint8_t **)(inst + oG) : NULL;
            int oT = group ? poff(CLS(group), "InterpTracks") : -1;
            if (oT < 0 || oTI < 0) continue;
            struct { uint8_t **data; int num, max; } *tracks = (void *)(group + oT), *ti = (void *)(inst + oTI);
            for (int t = 0; t < ti->num && t < tracks->num && t < 64; t++) {   // one track instance per track, in order
                uint8_t *tri = ti->data[t], *tr = tracks->data[t];
                if (!tri || !tr || !isClass(tri, "InterpTrackInstSound") || !isClass(tr, "InterpTrackSound")) continue;
                int oA = poff(CLS(tri), "PlayAudioComp"), oK = poff(CLS(tr), "Sounds");
                if (oA < 0 || oK < 0 || *(uint8_t **)(tri + oA) != l->comp) continue;
                struct { SoundKey *data; int num, max; } *keys = (void *)(tr + oK);
                SoundKey *k = NULL;                                      // the engine plays a key once the film is past it
                for (int i = 0; i < keys->num && i < 64; i++) if (keys->data[i].time < pos) k = &keys->data[i];
                int oF = k && k->sound ? poff(CLS(k->sound), "FirstNode") : -1;
                if (oF < 0 || cueWave(*(uint8_t **)(k->sound + oF), 0) != l->wave) { *x = 1e9f; return NO; }
                *x = (pos - k->time) / rate;
                return YES;
            }
        }
    }
    return NO;
}
// The camera's update each frame (game thread): fast-forward on or off, and where each line would be.
static void ffSpeechTick(void) {
    if (!gFFSpeechOK) return;
    double now = CFAbsoluteTimeGetCurrent(); float game = worldTime();
    BOOL on = NO, mode = NO; uint8_t *hud = ffHud();
    if (hud && boolGet(hud, "bFastForwardMode", &mode) && mode) on = YES;
    void *w = *(void **)(IB1_GWORLD_GLOBAL + _dyld_get_image_vmaddr_slide(0));
    uint8_t *wi = w ? ((uint8_t *(*)(void *, int))(IB1_GETWORLDINFO + _dyld_get_image_vmaddr_slide(0)))(w, 0) : NULL;
    int oTD = wi ? poff(CLS(wi), "TimeDilation") : -1;
    if (oTD >= 0 && *(float *)(wi + oTD) >= 500) on = YES;
    if (!on && !gFFSpeech) return;
    if (on && !gFFSpeech) {                                              // pressed: lines being heard fade out
        gFFSpeech = YES;
        for (int i = 0; i < gNumLines; i++) {
            SpokenLine *l = &gLines[i];
            if (now - l->seenAt > 0.2 || (l->mode != kLineHeard && l->mode != kLineFadingIn)) continue;
            l->mode = kLineFadingOut; l->fadeFrom = l->fade; l->fadeAt = now;
            alGetSourcef(l->al, AL_SEC_OFFSET, &l->wouldBe);             // where it is now: the start of its count
            l->heardTo = l->wouldBe; l->gameAt = game; l->placed = YES;
            LOG(@"spoken lines: fast-forward on: %@ fades out over %.1f s (at %.2f s of its recording)", ibfix_objname(l->wave), kLineFadeOut, l->wouldBe);
        }
    }
    for (int i = 0; i < gNumLines; i++) {                                // where each silenced line would be by now
        SpokenLine *l = &gLines[i]; float x = 0;
        if (l->mode == kLineHeard || l->mode == kLineFadingIn) continue;
        if (lineInFilm(l, &x) || x > 1e8f) { l->wouldBe = x; l->placed = YES; }
        else if (l->placed && game > l->gameAt) l->wouldBe += game - l->gameAt;   // let go by its film: the game's time on
        l->gameAt = game;
    }
    static int offFrames;
    if (on) { offFrames = 0; return; }
    if (++offFrames < 3) return;                                         // off for 3 frames: let go
    gFFSpeech = NO;
    for (int i = 0; i < gNumLines; i++) {
        SpokenLine *l = &gLines[i];
        if (l->mode != kLineSilent && l->mode != kLineFadingOut) continue;
        if (now - l->seenAt > 0.25) continue;                            // ended meanwhile
        const SpeechStarts *s = speechStarts(l->wave);
        int oD = poff(CLS(l->wave), "Duration");
        float words = s ? s->wordsEnd : oD >= 0 ? *(float *)(l->wave + oD) : 0, x = l->wouldBe;
        if (!l->placed || x >= words - 0.05f) {
            LOG(@"spoken lines: fast-forward off: %@ would be at %@ (its words end at %.2f s): stays silent, nothing until the next key",
                ibfix_objname(l->wave), l->placed ? (x > 1e8f ? @"a later key" : [NSString stringWithFormat:@"%.2f s", x]) : @"an unknown place", words);
            l->mode = kLineSilent; continue;
        }
        float at = fmaxf(lineStart(s, x), l->heardTo);                  // never back into what was already heard
        l->resume = YES; l->resumeAt = at; l->resumeAsked = now;
        LOG(@"spoken lines: fast-forward off: %@ would be at %.2f s (words to %.2f): picks up at %.2f s%@", ibfix_objname(l->wave), x, words, at,
            at == x ? @"" : at == l->heardTo ? @" (where it faded out)" : @" (the start of that word or pause)");
    }
}

// ---- 4u. The way back from the dungeon to the gate (26 October 2026; FIXES.md 71) ----
// The devs built a complete way out of the dungeon's first rooms: a tap on the circle "Back to Gate"
// (Birthright_P SwordMobileTouchActor_31, its SeqEvent_MobileTouch_38) blocks for loads, unloads the dungeon, loads the
// outer walls, stops the camera films of the dungeon save points SCM_9 (the cell block) and SCM_10 / SCM_11 (the
// dungeon door and its chest) and saves at SCM_25, the gate. No save point offers the circle (it is in none of their
// Touch Actors), so it never shows. So, as the God King circle (4q): it is switched on with the game's Toggle while one
// of those save points is the current one and its circles are up, outside a fight, and off otherwise; a tap runs the
// devs' own chain (the circle's event), and the save point's OnChoiceMade turns its other circles off, as a tap on one
// of its own does.
static const char *kGateNodes[] = { "SeqAct_StartChoiceMode_9", "SeqAct_StartChoiceMode_10", "SeqAct_StartChoiceMode_11" };
static uint8_t *gateNode(uint8_t *pc) {                          // the current save point, if it offers the way back
    uint8_t *node = objAt(pc, "ChoiceNode");
    if (!node || !isLiveObject(node)) return NULL;
    const uint8_t *o = node;
    for (int k = 0; *(const uint8_t **)(o + 0x40) && k < 16; k++) o = *(const uint8_t **)(o + 0x40);
    if (![ibfix_objname(o) isEqualToString:@"Birthright_P"]) return NULL;
    for (size_t i = 0; i < sizeof kGateNodes / sizeof kGateNodes[0]; i++) if ([ibfix_objname(node) isEqualToString:@(kGateNodes[i])]) return node;
    return NULL;
}
static void gateTick(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    static CFAbsoluteTime lastScan;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (!refLive(&gGateCircle) && t - lastScan > 3) {                  // looked for again after a level change
        lastScan = t; gGateOn = NO;
        gGateCircle = namedObjectIn("SwordMobileTouchActor", "SwordMobileTouchActor_31", @"Birthright_P");
    }
    if (!refLive(&gGateCircle)) return;
    BOOL fight = NO; boolGet(pc, "bInBossFight", &fight);
    int oL = poff(CLS(hud), "PostRenderedActors"); BOOL circlesUp = NO;
    if (oL >= 0) {                                                     // the save point's own circles are showing
        struct { void **data; int num, max; } *a = (void *)(hud + oL);
        void *vt = (void *)(IB1_TOUCHACTOR_VTABLE + _dyld_get_image_vmaddr_slide(0));
        for (int i = 0; i < a->num && i < 64; i++) if (a->data[i] && a->data[i] != gGateCircle.obj && *(void **)a->data[i] == vt) circlesUp = YES;
    }
    uint8_t *node = gateNode(pc);
    BOOL want = !fight && node && circlesUp;
    if (want && !gGateOn) {
        if (circleToggle(gGateCircle.obj, YES)) { gGateOn = YES; LOG(@"way back to the gate: circle shown at %@", ibfix_objname(node)); }
    } else if (!want && gGateOn) {
        circleToggle(gGateCircle.obj, NO); gGateOn = NO;
        LOG(@"way back to the gate: circle hidden");
    }
#ifdef IBFIX_SNAPS
    static CFAbsoluteTime shownAt; static BOOL drawnLogged;
    if (!gGateOn) { shownAt = 0; drawnLogged = NO; }
    else if (!shownAt) shownAt = t;
    else if (!drawnLogged && t - shownAt > 1.5) {                      // where the game drew it, once
        void *cls = CLS(gGateCircle.obj);
        int oP = poff(cls, "DrawPos"), oS = poff(cls, "DrawSize");
        if (oP >= 0 && oS >= 0) {
            float *p = (float *)((uint8_t *)gGateCircle.obj + oP), *sz = (float *)((uint8_t *)gGateCircle.obj + oS);
            LOG(@"way back to the gate: drawn at %.0f,%.0f, %.0f x %.0f pixels (of the HUD region)", p[0], p[1], sz[0], sz[1]);
        }
        drawnLogged = YES;
    }
#endif
}
static void gateTapped(void) {                                     // after the circle's own event (the devs' chain)
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL, *node = pc ? gateNode(pc) : NULL;
    gGateOn = NO;
    circleToggle(gGateCircle.obj, NO);
    BOOL choice = node && callNoArgs(node, "OnChoiceMade");
    LOG(@"way back to the gate: tapped at %@: the devs' chain runs, the save point's circles off %@", node ? ibfix_objname(node) : @"(no save point)", choice ? @"yes" : @"NO");
}
// ---- 4x. Places on the way back are as you left them (29 October 2026; FIXES.md 79) ----
// A tap runs the save point's OnChoiceMade (every circle off; MobileTouchActor.OnMobileTouch calls the tap delegate
// first), then the circle's SeqEvent_MobileTouch, which refuses once TriggerCount reaches MaxTriggerCount (1 by default):
// a spent circle offered again turns everything off and starts nothing. Coming back (4u) offers them again, and each
// chest's save point has a twin without the chest (tools/levelmap.py routes). So at a castle save point, as its circles
// show: a chest whose treasure was given in this bloodline is switched off, as its twin has it; any other shown circle
// whose event is spent gets its count back to 0 (4y keeps a beaten cell boss away). Never met on the devs' own path.
static const char *kChestCircles[][2] = {                     // the castle's chests: circle, its treasure (routes.txt)
    { "SwordMobileTouchActor_39", "SeqAct_AwardTreasure_1" },  // the gate (SCM_25 -> SCM_23)
    { "SwordMobileTouchActor_29", "SeqAct_AwardTreasure_8" },  // the dungeon cell (SCM_10 -> SCM_11)
    { "SwordMobileTouchActor_1", "SeqAct_AwardTreasure_3" },   // the courtyard's back corner (SCM_33 -> SCM_28)
    { "SwordMobileTouchActor_11", "SeqAct_AwardTreasure_10" }, // behind the statue (SCM_37 -> SCM_34)
    { "SwordMobileTouchActor_19", "SeqAct_AwardTreasure_6" },  // SCM_41 -> SCM_36
    { "SwordMobileTouchActor_17", "SeqAct_AwardTreasure_11" }, // the throne room (Special_1 -> SCM_2)
};
// Each note keeps the game's own lifetime count it was made at (FIXES.md 80): a chest the chest count
// (SwordPlayer.TotalTreasureChest, one more in GiveReward), the cell boss the fight count (FightFinishedCount, one more
// as each fight ends). A note counts only while the save playing has got that far, so an older save put back, or a new
// character in that slot, has its places as the game has them. (The God King circle's note, 4q, works the same way.)
static NSString *const kPlacesKept = @"ibfixPlacesKept";      // NSUserDefaults: slot -> { bloodline, kept: { place: count } }
static NSString *bloodlineKey(uint8_t *pc, NSString **slot) {  // "generation/uber-kills" of the character playing
    uint8_t *pawn = objAt(pc, "PlayerPawn"), *common = objAt(pc, "CommonSaveFile");
    int oG = pawn ? poff(CLS(pawn), "GenerationCount") : -1, oU = pawn ? poff(CLS(pawn), "UberBossKillCount") : -1;
    int oS = common ? poff(CLS(common), "SwordSaveIndex") : -1;
    if (oG < 0 || oU < 0) return nil;
    *slot = [NSString stringWithFormat:@"%d", oS >= 0 ? *(int *)(common + oS) : -1];
    return [NSString stringWithFormat:@"%d/%d", *(int *)(pawn + oG), *(int *)(pawn + oU)];
}
static const char *placeCounter(NSString *place) { return [place hasPrefix:@"SeqAct_AwardTreasure"] ? "TotalTreasureChest" : "FightFinishedCount"; }
static int knightCount(uint8_t *pc, const char *name) {
    uint8_t *pawn = objAt(pc, "PlayerPawn"); int o = pawn ? poff(CLS(pawn), name) : -1;
    return o >= 0 ? *(int *)(pawn + o) : -1;
}
static NSArray *chestsOpened(uint8_t *pc) {                   // the places done in this bloodline, as far as this save has got
    NSString *slot, *line = bloodlineKey(pc, &slot);
    NSDictionary *d = line ? [[NSUserDefaults standardUserDefaults] dictionaryForKey:kPlacesKept][slot] : nil;
    if (![d[@"bloodline"] isEqualToString:line]) return @[];
    NSMutableArray *r = [NSMutableArray array];
    static NSMutableSet *told; if (!told) told = [NSMutableSet set];
    for (NSString *place in d[@"kept"]) {
        int need = [d[@"kept"][place] intValue], now = knightCount(pc, placeCounter(place));
        if (now >= need) { [r addObject:place]; continue; }
        NSString *k = [NSString stringWithFormat:@"%@ %d %d", place, need, now];
        if (![told containsObject:k]) { [told addObject:k]; LOG(@"places as you left them: %@ was noted at %s %d, but this save is at %d (an older save): not counted", place, placeCounter(place), need, now); }
    }
    return r;
}
// A chest's treasure given: from the script-call hook (SeqAct_AwardTreasure.Activated calls GiveReward on the knight,
// before it counts the chest: ahead 1), and as a second witness, arriving at the gate's or the dungeon's twin save point
// (SCM_23, SCM_11: reached only through their chest, flow.txt)
static void chestOpenedNow(NSString *name, NSString *how, int ahead) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    NSString *slot, *line = pc ? bloodlineKey(pc, &slot) : nil;
    int now = pc ? knightCount(pc, placeCounter(name)) : -1;
    if (!line || now < 0) { LOG(@"places as you left them: %@ (%@), but the bloodline couldn't be read: not recorded", name, how); return; }
    NSMutableDictionary *all = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kPlacesKept] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *d = all[slot];
    NSMutableDictionary *kept = [d[@"bloodline"] isEqualToString:line] ? [d[@"kept"] mutableCopy] : [NSMutableDictionary dictionary];
    NSNumber *had = kept[name];
    if (had && had.intValue <= now) return;                   // noted already, and this save has got that far
    kept[name] = @(now + ahead);
    all[slot] = @{ @"bloodline": line, @"kept": kept };
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:kPlacesKept];
    LOG(@"places as you left them: %@ (%@): recorded for slot %@, bloodline %@, at %s %d%@", name, how, slot, line, placeCounter(name), now + ahead,
        had ? [NSString stringWithFormat:@" (its older note, at %d, was from a later point than this save)", had.intValue] : @"");
}
static void chestTreasureGiven(uint8_t *treasure) { chestOpenedNow(ibfix_objname(treasure), @"its treasure given", 1); }
// The camera's update (game thread): the current save point's circles, as they show
static void placesTick(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    BOOL fight = NO; boolGet(pc, "bInBossFight", &fight);
    uint8_t *node = objAt(pc, "ChoiceNode");
    int oTA = node && isLiveObject(node) ? poff(CLS(node), "TouchActors") : -1, oL = poff(CLS(hud), "PostRenderedActors");
    if (fight || oTA < 0 || oL < 0) return;
    const uint8_t *top = node;
    for (int k = 0; *(const uint8_t **)(top + 0x40) && k < 16; k++) top = *(const uint8_t **)(top + 0x40);
    if (![ibfix_objname(top) isEqualToString:@"Birthright_P"]) return;
    static void *witnessed;                                       // the twin save points reached only through their chest
    NSString *wslot;
    if (node != witnessed && bloodlineKey(pc, &wslot)) {          // (once the character is loaded: the save point comes first)
        witnessed = node; NSString *n = ibfix_objname(node);
        if ([n isEqualToString:@"SeqAct_StartChoiceMode_23"]) chestOpenedNow(@"SeqAct_AwardTreasure_1", @"at the gate's save point without it", 0);
        if ([n isEqualToString:@"SeqAct_StartChoiceMode_11"]) chestOpenedNow(@"SeqAct_AwardTreasure_8", @"at the dungeon's save point without it", 0);
        // 4y: the door's save points come only after the cell boss is beaten (his fight's Won Battle / NextChoice)
        if ([n isEqualToString:@"SeqAct_StartChoiceMode_10"] || [n isEqualToString:@"SeqAct_StartChoiceMode_11"])
            chestOpenedNow(@"SeqAct_StartChoiceMode_10", @"past the cell boss: he is beaten", 0);
    }
    struct { uint8_t **data; int num, max; } *ta = (void *)(node + oTA), *drawn = (void *)(hud + oL);
    static NSArray *opened; static void *openedFor; static CFAbsoluteTime openedAt;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < ta->num && i < 16; i++) {
        uint8_t *a = ta->data[i]; BOOL shown = NO;
        for (int j = 0; a && j < drawn->num && j < 64; j++) if (drawn->data[j] == a) shown = YES;
        if (!shown || !isLiveObject(a)) continue;
        NSString *circle = ibfix_objname(a), *treasure = nil;
        for (size_t c = 0; c < sizeof kChestCircles / sizeof kChestCircles[0]; c++) if ([circle isEqualToString:@(kChestCircles[c][0])]) treasure = @(kChestCircles[c][1]);
        if (treasure) {
            if (openedFor != node || now - openedAt > 2) { opened = chestsOpened(pc); openedFor = node; openedAt = now; }
            if ([opened containsObject:treasure]) {
                circleToggle(a, NO);
                LOG(@"places as you left them: %@ offers %@, whose chest was opened in this bloodline (%@): circle off", ibfix_objname(node), circle, treasure);
                continue;
            }
        }
        int oE = poff(CLS(a), "GeneratedEvents");
        struct { uint8_t **data; int num, max; } *ev = oE >= 0 ? (void *)(a + oE) : NULL;
        for (int e = 0; ev && e < ev->num && e < 8; e++) {
            uint8_t *s = ev->data[e];
            if (!s || !isClass(s, "SeqEvent_MobileTouch")) continue;
            int oM = poff(CLS(s), "MaxTriggerCount"), oT = poff(CLS(s), "TriggerCount");
            if (oM < 0 || oT < 0 || *(int *)(s + oM) <= 0 || *(int *)(s + oT) < *(int *)(s + oM)) continue;
            LOG(@"places as you left them: %@ offers %@ again, its %@ already used (%d of %d): ready again", ibfix_objname(node), circle,
                ibfix_objname(s), *(int *)(s + oT), *(int *)(s + oM));
            *(int *)(s + oT) = 0;
        }
    }
}
// ---- 4y. Down the well again: back where you left the dungeon (29 October 2026; FIXES.md 80) ----
// The devs' way down the well always loads the cell boss's fight (SeqAct_LoadBossBattle_7, SwordBossSpawnPoint_20) and
// shows him in the landing film (SeqAct_Interp_99), so with the way back (4u) a beaten boss came back. Once he is beaten
// in this bloodline (4x's note, made at SCM_10 or SCM_11), going down from the gate (SCM_23 or SCM_25 current): his spawn
// point's OnLoadBossBattle (through ProcessEvent, its class's vtable slot) is skipped, and StartCinematicMode_59's link
// to the landing film is pointed at the devs' after-win scene, "2-Sword Intro" (SeqAct_Interp_61), which leads to SCM_10
// as after the fight (by choice, FIXES.md 80; test builds can point it straight at SCM_10: route b below). In memory
// only: a level load brings the devs' data back, and this is set again when it applies.
#define IB1_SPAWNPOINT_PE_SLOT 0x100b8e9e8ULL   // ASwordBossSpawnPoint's vtable (0x100b8e7e0, its InternalConstructor's last store) + 0x208
static void (*gOrigSpawnPointPE)(void *, void *, void *, void *);
static BOOL gCellBossGone, gWellStraightToDoor;
static uint8_t *gWellPC;                                        // the player controller, for the gate check (game thread)
static BOOL atGate(void) {
    uint8_t *node = gWellPC ? objAt(gWellPC, "ChoiceNode") : NULL;
    NSString *n = node && isLiveObject(node) ? ibfix_objname(node) : nil;
    return [n isEqualToString:@"SeqAct_StartChoiceMode_23"] || [n isEqualToString:@"SeqAct_StartChoiceMode_25"];
}
#ifdef IBFIX_SNAPS
// Test builds: the preview's capture (FIXES.md 80). Documents/ibfix-welltest.txt, "<the Mac's time> <a|b|g>" (one-shot,
// honoured for 15 minutes): once resumed past the cell boss, Back to Gate from the door, then down the well from the
// gate, as their taps would (the save point's OnChoiceMade, then the circle's event's links by ForceActivateInput),
// photographing about 6 times a second (gate-<route>-..., well-<route>-...) until 10 s after arriving at the door.
// Route a: the devs' after-win scene; b: straight to the door (gWellStraightToDoor).
static int gWellTest; static char gWellRoute = 'a';
// Route g: from a save at the gate, the cell boss noted as beaten first, straight down the well; no pictures; at the
// door, whether its circles are drawn.
static BOOL gWellFromGate;
// robot.m (pressing Start for the capture) asks capture.m and gltrace.m for pictures and traces; when those aren't
// built in, these stand-ins answer (weak: the real ones win when they are).
__attribute__((weak)) void ibfix_request_snap(NSString *label) { LOG(@"robot: snap %@ asked, capture.m not built in", label); }
__attribute__((weak)) void ibfix_request_trace(NSString *label) { LOG(@"robot: trace %@ asked, gltrace.m not built in", label); }
static void wellTestRead(void) {
    NSString *path = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-welltest.txt"];
    NSArray *f = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (f.count < 2) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    double age = [NSDate date].timeIntervalSince1970 - [f[0] doubleValue];
    if (age < 0 || age > 15 * 60) { LOG(@"well test: file %.0f s old: ignored", age); return; }
    gWellRoute = [f[1] isEqualToString:@"b"] ? 'b' : 'a'; gWellStraightToDoor = gWellRoute == 'b'; gWellTest = 1;
    if ([f[1] isEqualToString:@"g"]) { gWellFromGate = YES; gWellTest = 2; }
    LOG(@"well test: on, route %c (%@)", gWellRoute, gWellStraightToDoor ? @"straight to the door" : @"the devs' after-win scene");
}
static BOOL fireInput(const char *cls, const char *name, int input) {
    ObjRef o = namedObjectIn(cls, name, @"Birthright_P");
    return refLive(&o) && callIntArg(o.obj, "ForceActivateInput", "InputIdx", input);
}
static void wellTestTick(uint8_t *pc) {
    if (!gWellTest) return;
    static CFAbsoluteTime since, start, shot, arrived, gateStart; static int shots;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    uint8_t *node = objAt(pc, "ChoiceNode"); NSString *n = node && isLiveObject(node) ? ibfix_objname(node) : @"";
    BOOL door = [n isEqualToString:@"SeqAct_StartChoiceMode_10"] || [n isEqualToString:@"SeqAct_StartChoiceMode_11"];
    BOOL gate = [n isEqualToString:@"SeqAct_StartChoiceMode_23"] || [n isEqualToString:@"SeqAct_StartChoiceMode_25"];
    if (gWellFromGate && gWellTest == 2 && gate && !gCellBossGone) {   // route g: noted as beaten in an earlier session
        static BOOL noted; if (!noted) { noted = YES; chestOpenedNow(@"SeqAct_StartChoiceMode_10", @"well test g: as beaten in an earlier session", 0); }
        since = 0; return;                                      // (the note is read once a second, wellReturnTick)
    }
    if (gWellTest == 2 && !gWellFromGate && t - shot >= 1.0 / 6) {   // the way back to the gate too (its arrival: 4z)
        shot = t; ibfix_snap([NSString stringWithFormat:@"gate-%c-%03d-%05.2f", gWellRoute, shots++, t - gateStart]);
    }
    if (gWellTest == 1 || gWellTest == 2) {
        BOOL here = gWellTest == 1 ? door && gCellBossGone && gGateOn : gate;
        if (!here) { since = 0; return; }
        if (!since) { since = t; return; }
        if (t - since < 4) return;
        since = 0;
        if (gWellTest == 1) {                                    // the Back to Gate circle's tap: 4u's own handling, then its event's links
            gateTapped();
            BOOL a = fireInput("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_54", 0), b = fireInput("SeqAct_Interp", "SeqAct_Interp_87", 0);
            LOG(@"well test: Back to Gate from %@ (%@), photographing", n, a && b ? @"started" : @"NOT started");
            gWellTest = 2; gateStart = t; shot = 0; shots = 0;
        } else {                                                 // the well's tap: the save point's circles off, then its event's links
            callNoArgs(node, "OnChoiceMade");
            BOOL a = fireInput("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_57", 0), b = fireInput("SeqAct_Interp", "SeqAct_Interp_90", 2);
            LOG(@"well test: down the well from %@ (%@), photographing", n, a && b ? @"started" : @"NOT started");
            gWellTest = 3; start = t; shot = 0; shots = 0; arrived = 0;
        }
        return;
    }
    if (door && !arrived) { arrived = t; LOG(@"well test: arrived at %@ %.1f s after the tap", n, t - start); }
    if (gWellFromGate && arrived) {                              // route g: the door's circles drawn yet? (HUD.PostRenderedActors)
        static int said; int sec = (int)(t - arrived);
        if (sec >= said) {
            said = sec + 1;
            uint8_t *hud = ffHud(); int oL = hud ? poff(CLS(hud), "PostRenderedActors") : -1;
            struct { uint8_t **data; int num, max; } *drawn = oL >= 0 ? (void *)(hud + oL) : NULL;
            BOOL doorC = NO, chestC = NO;
            for (int j = 0; drawn && j < drawn->num && j < 64; j++) {
                NSString *c = drawn->data[j] && isLiveObject(drawn->data[j]) ? ibfix_objname(drawn->data[j]) : @"";
                if ([c isEqualToString:@"SwordMobileTouchActor_41"]) doorC = YES;
                if ([c isEqualToString:@"SwordMobileTouchActor_29"]) chestC = YES;
            }
            LOG(@"well test: at the door %d s: door circle %@, chest circle %@", sec, doorC ? @"drawn" : @"not drawn", chestC ? @"drawn" : @"not drawn");
        }
        if (t - arrived > 15) { LOG(@"well test: done, route g"); gWellTest = 0; }
        return;
    }
    if ((arrived && t - arrived > 10) || t - start > 90) {
        LOG(@"well test: done, route %c, %d pictures", gWellRoute, shots); gWellTest = 0; return;
    }
    if (!gWellFromGate && t - shot >= 1.0 / 6) { shot = t; ibfix_snap([NSString stringWithFormat:@"well-%c-%03d-%05.2f", gWellRoute, shots++, t - start]); }
}
#endif
// A save point's next fight preloaded the devs' way (its PreCacheNextBoss; nothing if already loaded), for a route of
// ours that arrives without the fight that normally does it: 4y's way down the well (the door, SCM_10) and 4q's God King
// film (the bridge, SCM_32), the only save points our routes reach that have a Preload link (flow.txt).
static void preloadNextFight(const char *saveName, NSString *why) {
    ObjRef r = namedObjectIn("SeqAct_StartChoiceMode", saveName, @"Birthright_P");
    BOOL ok = refLive(&r) && callNoArgs(r.obj, "PreCacheNextBoss");
    LOG(@"%@: %s's next fight preloaded (its own PreCacheNextBoss): %@", why, saveName, ok ? @"yes" : @"NO");
}
static void my_spawnPointPE(void *obj, void *fn, void *parms, void *res) {
    NAME_ONCE(nameLoad, "OnLoadBossBattle");
    if (gCellBossGone && fn && *(int *)((uint8_t *)fn + 0x48) == nameLoad && [ibfix_objname(obj) isEqualToString:@"SwordBossSpawnPoint_20"] && atGate()) {
        LOG(@"down the well again: the cell boss (SwordBossSpawnPoint_20) was beaten in this bloodline: his fight not loaded");
        // The door's save point shows its circles only once its next fight is loaded (USeqAct_StartChoiceMode's
        // LevelsLoaded, vtable +0x380: every Preload link's spawn point IsFinishedLoading), which the devs do in the cell
        // boss's post-battle save (DoPostBattleSave -> PreCacheNextBoss). Skipping his fight would leave the game
        // standing still at the door, so the same call, here.
        static CFAbsoluteTime preloaded; CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - preloaded > 30) { preloaded = t; preloadNextFight("SeqAct_StartChoiceMode_10", @"down the well again"); }
        return;
    }
    gOrigSpawnPointPE(obj, fn, parms, res);
}
static void hookWellReturn(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **pe = (void **)(IB1_SPAWNPOINT_PE_SLOT + slide);
    if (*pe != (void *)(IB1_ACTOR_PROCESSEVENT + slide)) { LOG(@"down the well again OFF: the spawn points' vtable is not as expected"); return; }
    gOrigSpawnPointPE = (void (*)(void *, void *, void *, void *))*pe; *pe = (void *)my_spawnPointPE;
#ifdef IBFIX_SNAPS
    wellTestRead();
#endif
    LOG(@"down the well again ON%@", gWellStraightToDoor ? @" (test: straight to the door)" : @"");
}
// The camera's update (game thread): whether the cell boss is beaten, and the arrival's link once he is
static void wellReturnTick(void) {
    if (!gOrigSpawnPointPE) return;
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    gWellPC = pc;
#ifdef IBFIX_SNAPS
    wellTestTick(pc);
#endif
    static CFAbsoluteTime lastCheck; CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCheck < 1) return;
    lastCheck = now;
    gCellBossGone = [chestsOpened(pc) containsObject:@"SeqAct_StartChoiceMode_10"];
    static ObjRef step;                                          // StartCinematicMode_59, as found in this load of the castle
    if (!gCellBossGone) return;
    if (!refLive(&step)) {
        step = namedObjectIn("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_59", @"Birthright_P");
        if (!refLive(&step)) return;
    }
    ObjRef to = gWellStraightToDoor ? namedObjectIn("SeqAct_StartChoiceMode", "SeqAct_StartChoiceMode_10", @"Birthright_P")
                                    : namedObjectIn("SeqAct_Interp", "SeqAct_Interp_61", @"Birthright_P");
    int oOut = poff(step.cls, "OutputLinks");
    if (!refLive(&to) || oOut < 0) return;
    struct { uint8_t *data; int num, max; } *outs = (void *)(step.obj + oOut);
    if (outs->num < 1 || !outs->data) return;
    struct { struct { uint8_t *op; int input, pad; } *data; int num, max; } *links = (void *)outs->data;   // "Out": Links first
    for (int i = 0; i < links->num && i < 8; i++) {
        uint8_t *op = links->data[i].op;
        if (op == to.obj) return;                                // already pointed there
        if (!op || !isLiveObject(op) || ![ibfix_objname(op) isEqualToString:@"SeqAct_Interp_99"] || links->data[i].input != 0) continue;
        links->data[i].op = to.obj; links->data[i].input = 0;
        LOG(@"down the well again: the cell boss is beaten in this bloodline: the way down now leads to %@ instead of the landing film, as he was left",
            gWellStraightToDoor ? @"the door's save point (SCM_10)" : @"the devs' after-win scene \"2-Sword Intro\" (SeqAct_Interp_61), then the door (SCM_10)");
        return;
    }
}
// ---- 4z. A character moved in one step is lit for where he now is, at once (29 October 2026; FIXES.md 81) ----
// A character's light environment (DynamicLightEnvironmentComponent, the mesh's LightEnvironment) is worked out again
// only every so often and then blended towards (the knight's every 0.25 s in films, 1 s at save points and in fights:
// SetLightEnvUpdateTime), so one moved somewhere else in one step keeps the old place's light for a moment. The devs hid
// that under fades from black; 4y's arrival cuts from black. Any character (WorldInfo.PawnList) that moves more than 3 m
// in a frame, faster than anything walks (20 m a second of game time, so fast-forward's 0.4 s frames don't count), gets
// the engine's own ResetEnvironment: a full update on its next tick, with no blend.
static void lightFollowTick(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL, *wi = pc ? objAt(pc, "WorldInfo") : NULL;
    int oT = wi ? poff(CLS(wi), "TimeSeconds") : -1;
    if (oT < 0) return;
    typedef struct { uint8_t *pawn; float at[3]; } Seen;
    static Seen seen[16]; static int n; static float lastT; static int logged;
    float t = *(float *)(wi + oT), dt = t - lastT; lastT = t;
    Seen now[16]; int m = 0;
    for (uint8_t *p = objAt(wi, "PawnList"); p && m < 16; p = objAt(p, "NextPawn")) {
        int oL = poff(CLS(p), "Location");
        if (oL < 0) continue;
        float *at = (float *)(p + oL);
        now[m].pawn = p; memcpy(now[m].at, at, 12); m++;
        for (int i = 0; i < n; i++) {
            if (seen[i].pawn != p) continue;
            float dx = at[0] - seen[i].at[0], dy = at[1] - seen[i].at[1], dz = at[2] - seen[i].at[2], d = sqrtf(dx * dx + dy * dy + dz * dz);
            if (d > 300 && dt >= 0 && d > 2000 * dt) {
                uint8_t *mesh = objAt(p, "Mesh"), *env = mesh ? objAt(mesh, "LightEnvironment") : NULL;
                BOOL ok = env && callNoArgs(env, "ResetEnvironment");
                if (logged++ < 200) LOG(@"lighting follows: %@ moved %.0f units in one frame (%.3f s): its light %@", ibfix_objname(p), d, dt,
                                        ok ? @"worked out again at once" : @"NOT reset (no light environment)");
            }
            break;
        }
    }
    memcpy(seen, now, sizeof(Seen) * m); n = m;
}

// ---- 4aa. The Infinity Blade fits the Dias's slot (30 October 2026; FIXES.md 87) ----
// In "Open Cells" (Birthright_P's SeqAct_Interp_104) the knight sets the Infinity Blade in the Dias's blade-shaped slot,
// but the devs placed the panel (Birthright_Movers' InterpActor_2) at DrawScale 0.75: a 0.96 m slot for a 1.26 m blade,
// which stuck out. So while the knight plays "Key" (the film's camera cuts fall where it starts and stops), the blade is
// drawn at 0.75 of its size about its own middle: the same clearance as the devs' full-size slot and blade.
// How: the renderer builds each skeletal mesh's bone matrices in its mesh object's Update (GPU and CPU skinning, vtable
// slot 5) from the component's SpaceBases (FBoneAtom: rotation, translation, scale, 32 bytes; the scale multiplied in).
// The blade's bone (b_MF_Weapon_R_End, carrying all its vertices) is scaled for that call only: the game never sees it.
#define IB1_GPUSKIN_UPDATE_SLOT 0x100b1a528ULL   // FSkeletalMeshObjectGPUSkin::Update
#define IB1_GPUSKIN_UPDATE_FN   0x1005df110ULL
#define IB1_CPUSKIN_UPDATE_SLOT 0x100b1a448ULL   // FSkeletalMeshObjectCPUSkin::Update
#define IB1_CPUSKIN_UPDATE_FN   0x1005d7324ULL
typedef void (*SkinUpdateFn)(void *self, int lod, void *comp, void *morphs);
static SkinUpdateFn gOrigGPUSkinUpdate, gOrigCPUSkinUpdate;
static const float kKeyBladeScale = 0.75f;
static const float kKeyBladeMiddle[3] = {7.99f, 0.17f, 38.19f};  // the blade's middle in its bone's frame (its model, 1.26 m along Z)
static uint8_t *gKeyPawn, *gKeyMesh, *gKeySkel;                 // the knight, his mesh component, its skeletal mesh
static int gKeySlot, gKeyChan, gKeyBone = -1, gKeyName = -1;   // the slot node playing "Key"; the blade's bone
static double gKeySeen;                                         // when Matinee last set the knight's "Key"
static BOOL gKeyBladeOff;                                       // test builds: the "before" pictures
static int keyBladeBone(uint8_t *mesh) {                       // SkeletalMeshComponent.MatchRefBone('b_MF_Weapon_R_End')
    uint8_t *fn = findFunction(mesh, "MatchRefBone");
    int oN = fn ? propertyOffset(fn, "BoneName") : -1, oR = fn ? propertyOffset(fn, "ReturnValue") : -1, ni = nameIndex("b_MF_Weapon_R_End");
    if (!fn || oN < 0 || oR < 0 || ni < 0 || *(uint16_t *)(fn + 0xe2) > 64) return -1;
    uint8_t parms[64] = {0}; *(uint64_t *)(parms + oN) = (uint32_t)ni; processEvent(mesh, fn, parms);
    return *(int *)(parms + oR);
}
// called for MAT_SetAnimPosition (4m's dispatch): the knight's "Key", where it plays, and the blade's bone
static void keyBladeCall(void *self, void *stack) {
    static int tries;
    if (gKeyName < 0 && tries++ % 300 == 0) gKeyName = nameIndex("Key");
    if (!self || gKeyName < 0 || !sapArgs(stack)) return;
    uint8_t *loc = *(uint8_t **)((uint8_t *)stack + 0x30);
    if (*(int *)(loc + gOName) != gKeyName || self != playerPawn()) return;
    uint8_t *mesh = objAt(self, "Mesh"), *skel = mesh ? objAt(mesh, "SkeletalMesh") : NULL;
    if (!skel) return;
    if (skel != gKeySkel || mesh != gKeyMesh) {
        gKeyMesh = mesh; gKeySkel = skel; gKeyBone = keyBladeBone(mesh);
        LOG(@"Infinity Blade in the Dias: %@ plays Key; the blade's bone b_MF_Weapon_R_End is %d in %@%@", ibfix_objname(self), gKeyBone,
            ibfix_objname(skel), gOrigGPUSkinUpdate || gOrigCPUSkinUpdate ? @"" : @" (NOT drawn smaller: the renderer's hook isn't in)");
    }
    gKeyPawn = self; gKeySlot = *(int *)(loc + gOSlot); gKeyChan = *(int *)(loc + gOChan);
    gKeySeen = CFAbsoluteTimeGetCurrent();
}
static void quatRotate(const float *q, const float *v, float *out) {   // FQuat::RotateVector
    float t[3] = { 2 * (q[1] * v[2] - q[2] * v[1]), 2 * (q[2] * v[0] - q[0] * v[2]), 2 * (q[0] * v[1] - q[1] * v[0]) };
    out[0] = v[0] + q[3] * t[0] + (q[1] * t[2] - q[2] * t[1]);
    out[1] = v[1] + q[3] * t[1] + (q[2] * t[0] - q[0] * t[2]);
    out[2] = v[2] + q[3] * t[2] + (q[0] * t[1] - q[1] * t[0]);
}
// the knight's blade bone made smaller for this one call, or NULL (nothing changed); saved holds the bone as it was
static float *keyBladeShrink(void *comp, float saved[8]) {
    if (comp != gKeyMesh || gKeyBone < 0 || gKeyBladeOff || CFAbsoluteTimeGetCurrent() - gKeySeen > 0.5) return NULL;
    if (!isLiveObject(gKeyPawn) || objAt(comp, "SkeletalMesh") != gKeySkel) return NULL;
    uint8_t *node = animSlotSeq(gKeyPawn, gKeySlot, gKeyChan);     // what the slot plays now ("Stance" between the "Key"s)
    int oName = node ? poff(CLS(node), "AnimSeqName") : -1;
    if (oName < 0 || *(int *)(node + oName) != gKeyName) return NULL;
    static int oSB = -2; if (oSB == -2) oSB = poff(CLS(comp), "SpaceBases");
    struct { float *data; int num, max; } *sb = oSB >= 0 ? (void *)((uint8_t *)comp + oSB) : NULL;
    if (!sb || !sb->data || gKeyBone >= sb->num) return NULL;
    float *a = sb->data + gKeyBone * 8;                         // FBoneAtom: Rotation (x, y, z, w), Translation, Scale
    float len = a[0] * a[0] + a[1] * a[1] + a[2] * a[2] + a[3] * a[3];
    static int bad;
    if (fabsf(len - 1) > 0.01f || a[7] < 0.5f || a[7] > 2) { if (bad++ < 5) LOG(@"Infinity Blade in the Dias: the bone isn't as expected (|q|^2 %.3f, scale %.3f): left as it is", len, a[7]); return NULL; }
    memcpy(saved, a, 32);
    float mid[3]; quatRotate(a, kKeyBladeMiddle, mid);
    for (int i = 0; i < 3; i++) a[4 + i] += (1 - kKeyBladeScale) * a[7] * mid[i];   // the middle stays where it was
    a[7] *= kKeyBladeScale;
    static double lastLog;
    if (gKeySeen - lastLog > 5) { lastLog = gKeySeen; LOG(@"Infinity Blade in the Dias: drawn at %.2f of its size in the slot", kKeyBladeScale); }
    return a;
}
static void my_gpuSkinUpdate(void *self, int lod, void *comp, void *morphs) {
    float saved[8], *a = keyBladeShrink(comp, saved);
    gOrigGPUSkinUpdate(self, lod, comp, morphs);
    if (a) memcpy(a, saved, 32);
}
static void my_cpuSkinUpdate(void *self, int lod, void *comp, void *morphs) {
    float saved[8], *a = keyBladeShrink(comp, saved);
    gOrigCPUSkinUpdate(self, lod, comp, morphs);
    if (a) memcpy(a, saved, 32);
}
static void hookKeyBlade(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **gpu = (void **)(IB1_GPUSKIN_UPDATE_SLOT + slide), **cpu = (void **)(IB1_CPUSKIN_UPDATE_SLOT + slide);
    if (*gpu == (void *)(IB1_GPUSKIN_UPDATE_FN + slide)) { gOrigGPUSkinUpdate = (SkinUpdateFn)*gpu; *gpu = (void *)my_gpuSkinUpdate; }
    if (*cpu == (void *)(IB1_CPUSKIN_UPDATE_FN + slide)) { gOrigCPUSkinUpdate = (SkinUpdateFn)*cpu; *cpu = (void *)my_cpuSkinUpdate; }
    LOG(@"Infinity Blade in the Dias: %@", gOrigGPUSkinUpdate && gOrigCPUSkinUpdate ? @"ON" : gOrigGPUSkinUpdate || gOrigCPUSkinUpdate ? @"ON for one renderer only" : @"OFF: vtables not as expected");
}
#ifdef IBFIX_SNAPS
// Test builds: the preview's pictures (FIXES.md 87). Documents/ibfix-diastest.txt, "<the Mac's time> <before|after>"
// (one-shot, honoured for 15 minutes). Once resumed at SCM_8 with its one circle, the Dias's, drawn for 4 s, the circle is
// taken as its tap would (OnChoiceMade, then SeqEvent_MobileTouch_31's links: StartCinematicMode_41, which plays "Open
// Cells" for an owner of the Infinity Blade; "Click - Dragon" stopped; the 6-Foot fight loaded), then a picture every
// fifth of a second while the knight sets the blade (dias-<run>-<n>-<film time>), each logged with the blade bone
// (component space), the mesh's LocalToWorld and the panel's place and size. "before": the blade as the devs left it.
static int gDiasTest; static char gDiasRun[8];
static void diasTestRead(void) {
    NSString *path = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-diastest.txt"];
    NSArray *f = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (f.count < 2) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    double age = [NSDate date].timeIntervalSince1970 - [f[0] doubleValue];
    if (age < 0 || age > 15 * 60) { LOG(@"dias test: file %.0f s old: ignored", age); return; }
    gKeyBladeOff = [f[1] isEqualToString:@"before"]; strlcpy(gDiasRun, gKeyBladeOff ? "before" : "after", sizeof gDiasRun); gDiasTest = 1;
    NSString *snaps = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-snaps"];
    int gone = 0;                                               // earlier rounds' pictures (copied off then): only this run's go to the Mac
    for (NSString *x in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:snaps error:nil])
        if ([[NSFileManager defaultManager] removeItemAtPath:[snaps stringByAppendingPathComponent:x] error:nil]) gone++;
    LOG(@"dias test: on, run %s (%@); %d earlier pictures cleared from the test app", gDiasRun, gKeyBladeOff ? @"the blade as the devs left it" : @"the blade fitted to the slot", gone);
}
static void diasTestTick(void) {
    if (!gDiasTest) return;
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    static CFAbsoluteTime since; static float next; static int shots; static ObjRef film, panel;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (gDiasTest == 1) {                                       // the Dias's circle drawn for 4 s (the game resumed): taken, as its tap
        // The save point is set already under the start-up film and title: wait for the circle itself on screen.
        uint8_t *node = objAt(pc, "ChoiceNode"); NSString *n = node && isLiveObject(node) ? ibfix_objname(node) : @"";
        static ObjRef circle; if (!refLive(&circle)) circle = namedObjectIn("SwordMobileTouchActor", "SwordMobileTouchActor_45", @"Birthright_P");
        if (![n isEqualToString:@"SeqAct_StartChoiceMode_8"] || !refLive(&circle) || !actorPostRendered(hud, circle.obj)) { since = 0; return; }
        if (!since) { since = t; return; }
        if (t - since < 4) return;
        callNoArgs(node, "OnChoiceMade");
        BOOL a = fireInput("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_41", 0), b = fireInput("SeqAct_Interp", "SeqAct_Interp_96", 2),
             c = fireInput("SeqAct_LoadBossBattle", "SeqAct_LoadBossBattle_9", 0);
        film = namedObjectIn("SeqAct_Interp", "SeqAct_Interp_104", @"Birthright_P"); panel = namedObjectIn("InterpActor", "InterpActor_2", @"Birthright_Movers");
        LOG(@"dias test: the Dias's circle taken (%@); film %@, panel %@", a && b && c ? @"started" : @"NOT started", refLive(&film) ? @"found" : @"NOT found", refLive(&panel) ? @"found" : @"NOT found");
        gDiasTest = 2; next = 7.0f; shots = 0; since = t; return;
    }
    int oPos = refLive(&film) ? poff(film.cls, "Position") : -1;
    float pos = oPos >= 0 ? *(float *)(film.obj + oPos) : -1;
    if (pos >= next && pos < 21.4f) {
        next = floorf(pos * 5 + 1) / 5;
        if (next > 13.7f && next < 14.8f) next = 14.8f;
        ibfix_snap([NSString stringWithFormat:@"dias-%s-%03d-%05.2f", gDiasRun, shots++, pos]);
        NSMutableString *s = [NSMutableString stringWithFormat:@"dias test: picture %d at %.3f s of the film", shots - 1, pos];
        uint8_t *km = isLiveObject(gKeyMesh) ? gKeyMesh : NULL, *kp = isLiveObject(gKeyPawn) ? gKeyPawn : NULL;   // kept: checked (FIXES.md 90)
        int oSB = km ? poff(CLS(km), "SpaceBases") : -1, oL2W = km ? poff(CLS(km), "LocalToWorld") : -1;
        struct { float *data; int num, max; } *sb = oSB >= 0 ? (void *)(km + oSB) : NULL;
        if (sb && sb->data && gKeyBone >= 0 && gKeyBone < sb->num) {
            float *a = sb->data + gKeyBone * 8;
            [s appendFormat:@" | bone q (%.4f %.4f %.4f %.4f) t (%.2f %.2f %.2f) s %.3f", a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]];
        }
        if (oL2W >= 0) { float *m = (float *)(km + oL2W); [s appendString:@" | mesh"]; for (int i = 0; i < 16; i++) [s appendFormat:@" %.4g", m[i]]; }
        int oL = refLive(&panel) ? poff(panel.cls, "Location") : -1, oDS = refLive(&panel) ? poff(panel.cls, "DrawScale") : -1;
        if (oL >= 0 && oDS >= 0) { float *l = (float *)(panel.obj + oL); [s appendFormat:@" | panel (%.1f %.1f %.1f) x%.2f", l[0], l[1], l[2], *(float *)(panel.obj + oDS)]; }
        uint8_t *node = kp ? animSlotSeq(kp, gKeySlot, gKeyChan) : NULL; int oName = node ? poff(CLS(node), "AnimSeqName") : -1;
        if (oName >= 0) [s appendFormat:@" | playing %@", fnameStr(*(int *)(node + oName))];
        LOG(@"%@", s);
    }
    if (pos >= 21.4f || t - since > 60) { LOG(@"dias test: done, run %s, %d pictures", gDiasRun, shots); gDiasTest = 0; gKeyBladeOff = NO; }
}
#endif
// ---- 4ab. Test builds: pictures for the blood mock-ups (study/blood-plan.md, step 2; 31 October 2026) ----
// Built with -DIBFIX_BLOODCAP (with IBFIX_SNAPS). Each picture is named with its time and logged with the camera (POV
// location, pitch, yaw and roll in Unreal units, field of view), so the blood can be placed on it on the Mac:
// - a boss dazed (the knight's Enemy at IdleIndex 2, after a parry, block or dodge break): 10 a second, the first four
//   dazes after a launch, 120 pictures at most each, his health in the name: daze<N>-<n>-real<seconds>-hp<health>;
// - the arenas' death scenes: 7d's kDeathPictures, on in this build (10 a second, the first two after a launch);
// - the God King killing the knight (Battle_6ft_GodKing SeqAct_Interp_6, or _10 in his third stage): 15 a second
//   around his two stabs and the yank (0.5-2.7 and 10.8-15.8 s of film), 3 a second elsewhere, to 22 s:
//   gk<N>-<n>-film<seconds>.
#if defined(IBFIX_SNAPS) && defined(IBFIX_BLOODCAP)
static void bloodSnap(NSString *label, const uint8_t *vt) {
    ibfix_snap(label);
    if (!vt) { LOG(@"blood pics: %@ | camera not known", label); return; }
    const float *l = (const float *)(vt + 16); const int *r = (const int *)(vt + 28);
    LOG(@"blood pics: %@ | camera (%.1f %.1f %.1f) pitch %d yaw %d roll %d fov %.2f", label, l[0], l[1], l[2], r[0], r[1], r[2], *(const float *)(vt + 40));
}
static void bloodSnapTick(const uint8_t *vt) {                  // every frame, after the camera's update (vt: its view)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    static int dazes, shots; static BOOL dazed; static CFAbsoluteTime last, dazeAt;
    uint8_t *pawn = playerPawn(), *enemy = pawn ? objAt(pawn, "Enemy") : NULL;
    BossStage s;
    BOOL d = enemy && bossStage(enemy, &s) && s.idle == 2 && s.health > 0;
    if (d && !dazed) { dazes++; shots = 0; dazeAt = now; LOG(@"blood pics: daze %d: %@ (health %d)%@", dazes, ibfix_objname(enemy), s.health, dazes <= 4 ? @", photographed 10 a second" : @""); }
    if (!d && dazed) LOG(@"blood pics: daze %d over after %.1f s, %d pictures", dazes, now - dazeAt, shots);
    dazed = d;
    if (d && dazes <= 4 && shots < 120 && now - last >= 0.1) {
        last = now;
        bloodSnap([NSString stringWithFormat:@"daze%d-%03d-real%05.2f-hp%d", dazes, shots++, now - dazeAt, s.health], vt);
    }
    static ObjRef film[2]; static float lastPos[2] = {-1, -1}; static CFAbsoluteTime looked, lastShot, movedAt; static int kills, gkShots, playing = -1;
    if (!refLive(&film[0]) && now - looked >= 1) {              // both films, found by name and level
        looked = now; film[0].obj = film[1].obj = NULL;
        for (int f = 0, n = 0; f < gNumFilms && n < 2; f++) {
            if (!refLive(&gFilms[f].ref)) continue;
            NSString *fn = ibfix_objname(gFilms[f].ref.obj);
            if (![fn isEqualToString:@"SeqAct_Interp_6"] && ![fn isEqualToString:@"SeqAct_Interp_10"]) continue;
            const uint8_t *top = gFilms[f].ref.obj; for (int k = 0; *(const uint8_t **)(top + 0x40) && k < 16; k++) top = *(const uint8_t **)(top + 0x40);
            if ([ibfix_objname((void *)top) isEqualToString:@"Battle_6ft_GodKing"]) film[n++] = gFilms[f].ref;
        }
        if (film[0].obj) LOG(@"blood pics: the God King's kill films found (%@%@)", ibfix_objname(film[0].obj), film[1].obj ? [@", " stringByAppendingString:ibfix_objname(film[1].obj)] : @"");
    }
    for (int e = 0; e < 2; e++) {
        if (!refLive(&film[e])) continue;
        int oPos = poff(film[e].cls, "Position"); if (oPos < 0) continue;
        float pos = *(float *)(film[e].obj + oPos);
        BOOL moving = lastPos[e] >= 0 && pos != lastPos[e] && pos < 22;
        if (moving && playing != e) { playing = e; kills++; gkShots = 0; LOG(@"blood pics: the God King's kill %d: %@ from %.2f s", kills, ibfix_objname(film[e].obj), pos); }
        if (moving) movedAt = now;
        else if (playing == e && now - movedAt > 0.5) { LOG(@"blood pics: the God King's kill %d over at %.2f s, %d pictures", kills, pos, gkShots); playing = -1; }
        lastPos[e] = pos;
        if (!moving || kills > 2) continue;
        BOOL close = (pos >= 0.5f && pos < 2.7f) || (pos >= 10.8f && pos < 15.8f);
        if (now - lastShot >= (close ? 1.0 / 15 : 1.0 / 3)) {
            lastShot = now;
            bloodSnap([NSString stringWithFormat:@"gk%d-%03d-film%05.2f", kills, gkShots++, pos], vt);
        }
    }
}
#endif
// ---- 4ac. Blood mode, first build: blood in the 3D scene, from the blade (study/blood-plan.md; 31 October 2026) ----
// Built with -DIBFIX_BLOOD (blood.m draws). The game's damage calls carry no hit point or direction, so both come from
// the bones:
// - the blade: the knight's b_MF_Weapon_R_End (it carries all the blade's vertices; 4aa), from its origin to twice the
//   blade's middle (kKeyBladeMiddle) along it, in the world every frame (SpaceBases, then the mesh's LocalToWorld), so its
//   motion over the last frames is the swing;
// - a slash: the knight's own strike effect (Attack_*, played as it lands: the 7d tags); the cut is the blade's point
//   nearest the boss's nearest bone, the blood leaves along the blade's motion there, and the cut drips for a moment,
//   carried with its bone (stored in that bone's own frame);
// - a stab (Stab or Stab_BIG; a killing stab while the boss is dead, as 7d): the wound is kept in a bone's frame (the
//   head's for a killing stab), and when the blade comes back out, a fountain or a spurt out of it, then drips.
// Everything runs on game time (WorldInfo.TimeSeconds: slow motion slows it, a pause stops it) under the game's own
// gravity (WorldInfo.WorldGravityZ). Drops die below the knight's feet or when spent. Sizes are the game's units.
// Blood mode also quietens the weapon's own effects and trails (bloodFXApply, bloodTrailSockets).
#ifdef IBFIX_BLOOD
typedef struct { float p[3], v[3], r, stretch, a; int kind; } BloodDrop;   // as blood.m
void ibfix_blood_publish(const BloodDrop *d, int n, float light);
typedef struct { float p[3], v[3], r, life, age, drag, a; int kind; } BloodP;
#define kBloodMax 1600
static BloodP gBP[kBloodMax]; static int gNBP;
BOOL gBloodOn;                                                  // Options' Blood switch (ibfixBlood; off until switched on)
static NSString *const kBloodKey = @"ibfixBlood";
static void bloodLoadSetting(void) {                            // once, after the settings file (game.m 4) is copied in
    static BOOL loaded; if (loaded) return; loaded = YES;
    gBloodOn = [[NSUserDefaults standardUserDefaults] boolForKey:kBloodKey];
    LOG(@"options: Blood %@", gBloodOn ? @"on" : @"off");
}
typedef struct { ObjRef mesh; int bone; float local[3], dir[3]; float start, until, next, every; int kind; } Wound;   // kind 0 drips, 1 fountain
static const float kFountainBlows = 6, kFountainBlow = 0.45f;   // the head fountain's blows, and each one's length (s)
static Wound gWounds[24]; static int gNWounds;
static float gBladeH[3], gBladeT[3], gBladeHPrev[3], gBladeTPrev[3], gBladeAt, gBladeAtPrev; static BOOL gBladeKnown, gBladePrevKnown;
static struct { float h[3], t[3], at; } gBladeHist[4]; static int gBladeHistN;   // the blade over the last 4 frames, newest first
static float gGravity = -520, gFloorZ = -1e9;
static struct { ObjRef mesh; int bone; float local[3], depth; BOOL out, kill; float at; } gStab;   // a stab waiting for the blade to come out
static float frand(void) { return (float)arc4random() / 4294967296.0f; }
static float nrand(void) { float u = fmaxf(frand(), 1e-6f), v = frand(); return sqrtf(-2 * logf(u)) * cosf(6.2831853f * v); }
static void vsub(const float *a, const float *b, float *o) { o[0] = a[0] - b[0]; o[1] = a[1] - b[1]; o[2] = a[2] - b[2]; }
static float vdot(const float *a, const float *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
static float vlen(const float *a) { return sqrtf(vdot(a, a)); }
static void vnorm(float *a) { float l = vlen(a); if (l > 1e-6f) { a[0] /= l; a[1] /= l; a[2] /= l; } }
// a skeletal mesh component's bones: SpaceBases (FBoneAtom, component space: rotation x y z w, translation, scale) and
// LocalToWorld (an FMatrix: rows, a point times it)
static const float *boneAtom(uint8_t *comp, int bone) {
    int oSB = poff(CLS(comp), "SpaceBases");
    struct { float *data; int num, max; } *sb = oSB >= 0 ? (void *)(comp + oSB) : NULL;
    return sb && sb->data && bone >= 0 && bone < sb->num ? sb->data + bone * 8 : NULL;
}
static int boneCount(uint8_t *comp) {
    int oSB = poff(CLS(comp), "SpaceBases");
    struct { float *data; int num, max; } *sb = oSB >= 0 ? (void *)(comp + oSB) : NULL;
    return sb && sb->data ? sb->num : 0;
}
static const float *compL2W(uint8_t *comp) { int o = poff(CLS(comp), "LocalToWorld"); return o >= 0 ? (const float *)(comp + o) : NULL; }
static BOOL boneToWorld(uint8_t *comp, int bone, const float local[3], float out[3]) {
    const float *a = boneAtom(comp, bone), *m = compL2W(comp);
    if (!a || !m) return NO;
    float v[3] = { local[0] * a[7], local[1] * a[7], local[2] * a[7] }, r[3]; quatRotate(a, v, r);
    float c[3] = { r[0] + a[4], r[1] + a[5], r[2] + a[6] };
    for (int j = 0; j < 3; j++) out[j] = c[0] * m[j] + c[1] * m[4 + j] + c[2] * m[8 + j] + m[12 + j];
    return YES;
}
static BOOL worldToBone(uint8_t *comp, int bone, const float w[3], float out[3]) {
    const float *a = boneAtom(comp, bone), *m = compL2W(comp);
    if (!a || !m || a[7] < 1e-4f) return NO;
    float s2 = m[0] * m[0] + m[1] * m[1] + m[2] * m[2]; if (s2 < 1e-8f) return NO;
    float d[3] = { w[0] - m[12], w[1] - m[13], w[2] - m[14] }, c[3];
    for (int j = 0; j < 3; j++) c[j] = (d[0] * m[j * 4] + d[1] * m[j * 4 + 1] + d[2] * m[j * 4 + 2]) / s2;
    float q[4] = { -a[0], -a[1], -a[2], a[3] }, t[3] = { (c[0] - a[4]) / a[7], (c[1] - a[5]) / a[7], (c[2] - a[6]) / a[7] };
    quatRotate(q, t, out);
    return YES;
}
static NSString *boneNameOf(uint8_t *mesh, int b) {             // SkeletalMeshComponent.GetBoneName
    void *fn = findFunction(mesh, "GetBoneName");
    static int oi = -2, orv; if (oi == -2 && fn) { oi = propertyOffset(fn, "BoneIndex"); orv = propertyOffset(fn, "ReturnValue"); }
    if (!fn || oi < 0 || orv < 0 || *(uint16_t *)((uint8_t *)fn + 0xe2) > 64) return nil;
    uint8_t pn[64] = {0}; *(int *)(pn + oi) = b; processEvent(mesh, fn, pn);
    struct { uint8_t pad[0x48]; uint64_t name; } fake; fake.name = *(uint64_t *)(pn + orv);
    return (uint32_t)fake.name ? ibfix_objname(&fake) : nil;
}
// Who bleeds: every enemy of flesh, not the machines and stone (no blood, cuts or fountain), told apart by their skeletal
// mesh's name (by choice, FIXES.md 88; study/blood-plan.md, Who bleeds)
static const char *kNoBlood[] = { "Golem_Mesh", "GolemGold_Mesh", "Mech_Mesh" };
static BOOL meshBleeds(uint8_t *meshComp) {
    uint8_t *skel = meshComp ? objAt(meshComp, "SkeletalMesh") : NULL; if (!skel) return YES;
    NSString *nm = ibfix_objname(skel);
    for (size_t i = 0; i < sizeof kNoBlood / sizeof *kNoBlood; i++) if ([nm isEqualToString:@(kNoBlood[i])]) return NO;
    return YES;
}
static uint8_t *bossMesh(void) {
    uint8_t *pawn = playerPawn(), *enemy = pawn ? objAt(pawn, "Enemy") : NULL;
    uint8_t *boss = enemy && plausibleObj(enemy) ? enemy : refLive(&gLastBoss) ? gLastBoss.obj : NULL;
    return boss ? objAt(boss, "Mesh") : NULL;
}
static void bloodAdd(const float p[3], const float v[3], float r, float life, float drag, float a, int kind) {
    if (gNBP >= kBloodMax) return;
    BloodP *b = &gBP[gNBP++];
    memcpy(b->p, p, 12); memcpy(b->v, v, 12); b->r = r; b->life = life; b->age = 0; b->drag = drag; b->a = a; b->kind = kind;
}
// a spray along a direction: n drops and m puffs, speeds about `speed`, spread `spread` (radians)
static void bloodSpray(const float at[3], const float dir0[3], float speed, float spread, int n, int m, float size) {
    float dir[3] = { dir0[0], dir0[1], dir0[2] }; vnorm(dir);
    for (int i = 0; i < n + m; i++) {
        BOOL mist = i >= n;
        float s = spread * (mist ? 1.8f : 1.0f), d[3] = { dir[0] + nrand() * s, dir[1] + nrand() * s, dir[2] + nrand() * s }; vnorm(d);
        float sp = speed * (mist ? 0.5f + 0.5f * frand() : 0.55f + 0.6f * frand());
        float v[3] = { d[0] * sp, d[1] * sp, d[2] * sp };
        float p[3] = { at[0] + nrand() * size, at[1] + nrand() * size, at[2] + nrand() * size };
        // small drops, mostly fine specks drawn as thin streaks, and a soft mist that hangs a moment
        if (mist) bloodAdd(p, v, size * (1.2f + 1.2f * frand()), 0.6f + 0.35f * frand(), 4.5f, 0.3f, 1);
        else bloodAdd(p, v, size * 0.2f * expf(0.6f * nrand()), 1.4f, 0.35f, 1.0f, 0);
    }
}
static void addWound(uint8_t *mesh, int bone, const float local[3], const float dir[3], float now, float length, float every, int kind) {
    if (gNWounds >= 24) memmove(gWounds, gWounds + 1, sizeof(Wound) * (size_t)--gNWounds);
    Wound *w = &gWounds[gNWounds++];
    w->mesh = (ObjRef){ mesh, *(int *)(mesh + 0x38), CLS(mesh) }; w->bone = bone;
    memcpy(w->local, local, 12); memcpy(w->dir, dir, 12); w->start = w->next = now; w->until = now + length; w->every = every; w->kind = kind;
}
// the blade in the world, now and a frame ago
static void bladeUpdate(float now) {
    uint8_t *pawn = playerPawn(), *mesh = pawn ? objAt(pawn, "Mesh") : NULL;
    static uint8_t *lastMesh; static int bone = -1;
    if (!mesh) { gBladeKnown = gBladePrevKnown = NO; return; }
    if (mesh != lastMesh) { lastMesh = mesh; bone = keyBladeBone(mesh); LOG(@"blood: the blade's bone is %d", bone); }
    float h[3], t[3], o[3] = {0, 0, 0}, tip[3] = { 2 * kKeyBladeMiddle[0], 2 * kKeyBladeMiddle[1], 2 * kKeyBladeMiddle[2] };
    if (bone < 0 || !boneToWorld(mesh, bone, o, h) || !boneToWorld(mesh, bone, tip, t)) { gBladeKnown = NO; return; }
    if (gBladeKnown && now > gBladeAt) { memcpy(gBladeHPrev, gBladeH, 12); memcpy(gBladeTPrev, gBladeT, 12); gBladeAtPrev = gBladeAt; gBladePrevKnown = YES; }
    if (!gBladeHistN || now > gBladeHist[0].at) {
        memmove(gBladeHist + 1, gBladeHist, sizeof gBladeHist[0] * 3); memcpy(gBladeHist[0].h, h, 12); memcpy(gBladeHist[0].t, t, 12);
        gBladeHist[0].at = now; if (gBladeHistN < 4) gBladeHistN++;
    }
    memcpy(gBladeH, h, 12); memcpy(gBladeT, t, 12); gBladeAt = now; gBladeKnown = YES;
    // the floor: the knight's lowest bone
    int n = boneCount(mesh); float lo = 1e9;
    for (int b = 0; b < n; b++) { float w[3]; if (boneToWorld(mesh, b, o, w) && w[2] < lo) lo = w[2]; }
    if (lo < 1e8f) gFloorZ = lo - 4;
}
// the blade's point nearest any of the mesh's bones (or the one bone given): that bone, the point, the distance
static float bladeNearest(uint8_t *mesh, int only, int *boneOut, float pt[3], float *along) {
    int n = boneCount(mesh); float best = 1e9, o[3] = {0, 0, 0};
    for (int b = (only >= 0 ? only : 0); b < (only >= 0 ? only + 1 : n); b++) {
        float w[3]; if (!boneToWorld(mesh, b, o, w)) continue;
        for (int k = 0; k <= 16; k++) {
            float f = k / 16.0f, p[3] = { gBladeH[0] + f * (gBladeT[0] - gBladeH[0]), gBladeH[1] + f * (gBladeT[1] - gBladeH[1]), gBladeH[2] + f * (gBladeT[2] - gBladeH[2]) }, d[3];
            vsub(p, w, d); float l = vlen(d);
            if (l < best) { best = l; *boneOut = b; memcpy(pt, p, 12); if (along) *along = f; }
        }
    }
    return best;
}
static void woundCut(uint8_t *meshComp, const float swing0[3], float length, BOOL toTorso, int stab, const float *stabAt);   // below: the cut on his skin
// The giants: an upward or downward slash (Attack_C_*, Attack_D_*, Attack_Big_C, Attack_Big_D) on a 15-foot boss puts its
// cut on his torso, which the knight's slashes otherwise rarely reach (by choice, FIXES.md 88); other slashes stay
// where the blade met him. Told by skeletal mesh name (every BOSS_15ft_*_SF package's one mesh), not by height (the Troll
// crouches in his fight) or package (the meshes live in packages named for the boss, B_Boss_Troll.Mesh.Troll_Mesh).
static const char *kGiants[] = { "TwoHands_Phatty_Mesh", "Troll_Mesh", "Sumo_Mesh", "Rancor_Mesh", "Golem_Mesh", "GolemGold_Mesh" };
static BOOL isGiant(uint8_t *mesh) {
    static uint8_t *last; static BOOL giant;
    if (mesh == last) return giant;
    uint8_t *skel = objAt(mesh, "SkeletalMesh"); if (!skel) return NO;
    NSString *nm = ibfix_objname(skel); giant = NO;
    for (size_t i = 0; i < sizeof kGiants / sizeof *kGiants; i++) if ([nm isEqualToString:@(kGiants[i])]) giant = YES;
    last = mesh;
    LOG(@"blood: %@ is %@", nm, giant ? @"a giant (up and down slashes cut his torso)" : @"not a giant");
    return giant;
}
static BOOL verticalSlash(NSString *tag) {
    return [tag hasPrefix:@"Attack_C_"] || [tag hasPrefix:@"Attack_D_"] || [tag isEqualToString:@"Attack_Big_C"] || [tag isEqualToString:@"Attack_Big_D"];
}
#ifdef IBFIX_SNAPS
static int gBloodShots, gBloodStrikes; static CFAbsoluteTime gBloodShotAt;   // test builds: pictures after the first strikes
#endif
#ifdef IBFIX_SNAPS
// test builds: the knight's mesh's sockets (the swing trails run between two of them) and his particle effects at the
// first strikes (which one draws the big trails)
static NSString *nameText(uint64_t nm) { struct { uint8_t pad[0x48]; uint64_t name; } fake; fake.name = nm; return (uint32_t)nm ? ibfix_objname(&fake) : @""; }
static void bloodDiag(void) {
    static int calls; if (calls++ >= 4) return;
    uint8_t *pawn = playerPawn(), *mesh = pawn ? objAt(pawn, "Mesh") : NULL, *skel = mesh ? objAt(mesh, "SkeletalMesh") : NULL;
    if (calls == 1 && skel) {
        int oS = poff(CLS(skel), "Sockets");
        struct { uint8_t **data; int num, max; } *arr = oS >= 0 ? (void *)(skel + oS) : NULL;
        NSMutableString *out = [NSMutableString string];
        for (int i = 0; arr && arr->data && i < arr->num && i < 64; i++) {
            uint8_t *so = arr->data[i]; if (!plausibleObj(so)) continue;
            void *c = CLS(so); int oN = poff(c, "SocketName"), oB = poff(c, "BoneName"), oL = poff(c, "RelativeLocation");
            if (oN < 0 || oB < 0 || oL < 0) continue;
            const float *l = (const float *)(so + oL);
            [out appendFormat:@" | %@ on %@ (%.1f %.1f %.1f)", nameText(*(uint64_t *)(so + oN)), nameText(*(uint64_t *)(so + oB)), l[0], l[1], l[2]];
        }
        LOG(@"blood: the knight's sockets (%@):%@", ibfix_objname(skel), out);
    }
    static void *pscs[512]; int n = ibfix_objects_of_class("ParticleSystemComponent", pscs, 512);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < n; i++) {
        uint8_t *c = pscs[i]; uint8_t *owner = objAt(c, "Owner"), *tpl = objAt(c, "Template");
        if (owner == pawn && tpl) [out appendFormat:@" %@", ibfix_objname(tpl)];
    }
    LOG(@"blood: the knight's particle effects at this strike:%@", out.length ? out : @" none");
}
#endif
static void bloodStrike(NSString *tag) {                        // the knight's strike landing
    float now = worldTime();
#ifdef IBFIX_SNAPS
    bloodDiag();
#endif
#ifdef IBFIX_SNAPS
    if (gBloodStrikes < 24) { gBloodStrikes++; gBloodShots = 3; gBloodShotAt = 0; }   // 3 pictures after each of the first 24
#endif
    uint8_t *mesh = bossMesh();
    if (!mesh || !gBladeKnown) { LOG(@"blood: %@ landed, but %@", tag, mesh ? @"the blade isn't known" : @"no boss mesh"); return; }
    if (!meshBleeds(mesh)) { static int told; if (told++ < 3) LOG(@"blood: %@ landed on %@: not a living enemy, no blood", tag, ibfix_objname(objAt(mesh, "SkeletalMesh"))); return; }
    int bone = -1; float pt[3], f = 0; float dist = bladeNearest(mesh, -1, &bone, pt, &f);
    if (bone < 0) return;
    // the swing at that point: the blade's motion over the last frames there (up to three, steadier than one)
    float v[3] = {0, 0, 1}; int old = MIN(gBladeHistN - 1, 3);
    float dt = old > 0 ? gBladeHist[0].at - gBladeHist[old].at : 0;
    if (dt > 1e-4f) for (int j = 0; j < 3; j++) {
        float p0 = gBladeHist[old].h[j] + f * (gBladeHist[old].t[j] - gBladeHist[old].h[j]), p1 = gBladeHist[0].h[j] + f * (gBladeHist[0].t[j] - gBladeHist[0].h[j]);
        v[j] = (p1 - p0) / dt;
    }
    float speed = vlen(v);
    // The blood goes the way the blade went, like cast-off at a crime scene. Taken out: most of the swing's motion
    // towards or away from the camera (mostly the knight's lunge into him), and any part still going into his body.
    // No push outward from his body: that is straight at the knight and the camera.
    float o[3] = {0, 0, 0}, root[3], nrm[3], cam[3];
    if (ibfix_camera_location(cam)) {
        float fw[3]; vsub(pt, cam, fw); vnorm(fw); float along = vdot(v, fw);
        for (int j = 0; j < 3; j++) v[j] -= 0.85f * along * fw[j];
    }
    if (boneToWorld(mesh, 0, o, root)) {
        vsub(pt, root, nrm); nrm[2] = 0; vnorm(nrm);
        float in = vdot(v, nrm);
        if (in < 0) for (int j = 0; j < 3; j++) v[j] -= in * nrm[j];
    }
    float sp = fminf(fmaxf(speed * 0.4f, 150), 420);              // the flick: a share of the blade's speed
    bloodSpray(pt, v, sp, 0.10f, 56, 8, 3.0f);                    // a tight fan of fine spatter, a little mist
    BOOL torso = verticalSlash(tag) && isGiant(mesh);
    woundCut(mesh, v, 26, torso, 0, NULL);
    float local[3], bw[3], out[3];
    if (worldToBone(mesh, bone, pt, local)) {
        boneToWorld(mesh, bone, o, bw); vsub(pt, bw, out); vnorm(out);
        addWound(mesh, bone, local, out, now, 1.0f, 0.04f, 0);
    }
    float vl = vlen(v);
    LOG(@"blood: %@ landed: the blade %.0f units from %@'s bone %@ at %.0f%% along it, moving %.0f units/s; the spatter goes (%.2f %.2f %.2f)", tag, dist,
        ibfix_objname(mesh), boneNameOf(mesh, bone) ?: @"?", 100 * f, speed, vl > 0 ? v[0] / vl : 0, vl > 0 ? v[1] / vl : 0, vl > 0 ? v[2] / vl : 0);
}
// Cuts (wound.m draws them): each enemy's skin from ibfix-wounds.pak (tools/blood/woundmesh.py: every corner's place on
// his texture and its bones, each with the corner's place in that bone's frame at the reference pose). At a strike the
// skin is placed from the bones and the cut walks along it in the swing's direction (the part through the skin taken
// out), a unit at a time, each step's nearest triangle giving its place on the texture, so a cut crossing a texture
// seam carries on in the right place. The cuts stay for the fight; a new enemy starts clean.
int ibfix_wound_register(uint64_t key);
uint8_t *ibfix_wound_pixels(int s);
void ibfix_wound_dirty(int s, int x0, int y0, int x1, int y1);
void ibfix_wound_clear(int s);
int ibfix_wound_skin_shown(int s);
#define kWoundSize 1024                                         // as wound.m: each half of the wound layer (two halves side by side)
#define kWoundW (2 * kWoundSize)
typedef struct { char name[32]; int skin, nw, nt; float *uv; int *first; uint8_t *n, *bone, *bare, *shared, *mask; float *w, *local; uint16_t *tri; } WMesh;
static WMesh gWM[32]; static int gNWM;
__attribute__((constructor)) static void woundsLoad(void) {
    NSString *f = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-wounds.pak"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:f]) f = [[NSBundle mainBundle] pathForResource:@"ibfix-wounds" ofType:@"pak"];
    NSData *d = f ? [NSData dataWithContentsOfFile:f] : nil;
    const uint8_t *p = d.bytes, *end = p + d.length;
    if (!d || d.length < 12 || memcmp(p, "IBWM", 4)) return;
    uint32_t version = *(const uint32_t *)(p + 4), count = *(const uint32_t *)(p + 8); p += 12;
    for (uint32_t k = 0; k < count && gNWM < 32 && p + 56 <= end; k++) {
        WMesh *m = &gWM[gNWM]; uint64_t key = *(const uint64_t *)p; memcpy(m->name, p + 8, 32); m->name[31] = 0;
        m->nw = *(const int *)(p + 40); m->nt = *(const int *)(p + 44); uint32_t len = *(const uint32_t *)(p + 52); p += 56;
        const uint8_t *b = p, *bend = p + len; p += len; if (p > end) break;
        m->uv = malloc(sizeof(float) * 2 * m->nw); m->first = malloc(sizeof(int) * (m->nw + 1)); m->n = malloc(m->nw); m->bare = calloc(m->nw, 1); m->shared = calloc(m->nw, 1);
        m->bone = malloc(4 * m->nw); m->w = malloc(sizeof(float) * 4 * m->nw); m->local = malloc(sizeof(float) * 12 * m->nw); m->tri = malloc(6 * m->nt);
        int inf = 0;
        for (int i = 0; i < m->nw && b + 10 <= bend; i++) {
            memcpy(&m->uv[i * 2], b, 8); b += 8;
            if (version >= 2) { m->bare[i] = *b & 1; m->shared[i] = (*b & 2) != 0; b++; }   // version 2: bare skin (1); version 3: on a place shared the same way round (2)
            m->n[i] = *b++; m->first[i] = inf;
            for (int j = 0; j < m->n[i]; j++, inf++) { m->bone[inf] = b[0]; memcpy(&m->w[inf], b + 1, 4); memcpy(&m->local[inf * 3], b + 5, 12); b += 17; }
        }
        m->first[m->nw] = inf;
        memcpy(m->tri, b, 6 * (size_t)m->nt); b += 6 * (size_t)m->nt;
        if (version >= 3 && b + 8192 <= bend) { m->mask = malloc(8192); memcpy(m->mask, b, 8192); }   // those places, 256 x 256 bits
        m->skin = ibfix_wound_register(key);
        LOG(@"wounds: %s's skin read (%d corners, %d triangles), skin %d", m->name, m->nw, m->nt, m->skin);
        gNWM++;
    }
}
static void closestOnTri(const float *p, const float *a, const float *b, const float *c, float *bary) {   // Ericson's closest point, as barycentrics
    float ab[3], ac[3], ap[3]; vsub(b, a, ab); vsub(c, a, ac); vsub(p, a, ap);
    float d1 = vdot(ab, ap), d2 = vdot(ac, ap); if (d1 <= 0 && d2 <= 0) { bary[0] = 1; bary[1] = bary[2] = 0; return; }
    float bp[3]; vsub(p, b, bp); float d3 = vdot(ab, bp), d4 = vdot(ac, bp); if (d3 >= 0 && d4 <= d3) { bary[1] = 1; bary[0] = bary[2] = 0; return; }
    float vc = d1 * d4 - d3 * d2; if (vc <= 0 && d1 >= 0 && d3 <= 0) { float v = d1 / (d1 - d3); bary[0] = 1 - v; bary[1] = v; bary[2] = 0; return; }
    float cp[3]; vsub(p, c, cp); float d5 = vdot(ab, cp), d6 = vdot(ac, cp); if (d6 >= 0 && d5 <= d6) { bary[2] = 1; bary[0] = bary[1] = 0; return; }
    float vb = d5 * d2 - d1 * d6; if (vb <= 0 && d2 >= 0 && d6 <= 0) { float w = d2 / (d2 - d6); bary[0] = 1 - w; bary[2] = w; bary[1] = 0; return; }
    float va = d3 * d6 - d5 * d4; if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) { float w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); bary[1] = 1 - w; bary[2] = w; bary[0] = 0; return; }
    float den = 1 / (va + vb + vc); bary[1] = vb * den; bary[2] = vc * den; bary[0] = 1 - bary[1] - bary[2];
}
// a place on the texture his picture shares the same way round with another part of his body (woundmesh.py's mask)
static BOOL texShared(const WMesh *m, float x, float y) {
    if (!m->mask) return NO;
    int X = (((int)floorf(x) % kWoundSize) + kWoundSize) % kWoundSize / 4, Y = (((int)floorf(y) % kWoundSize) + kWoundSize) % kWoundSize / 4;
    return (m->mask[Y * 32 + X / 8] >> (7 - X % 8)) & 1;
}
// one dab of a cut on the wound layer (straight alpha, "over" what's there), of three kinds: 0 a piece of the gash, a
// short streak along the cut's direction on the texture (width w): a near-black wet core, a faint bruise round it and a
// thin light glint along one lip; 1 a piece of a drip running down (width w); 2 a drip's end (a small bead).
// style: the cut's own colouring (its wet lip, its bruise, how dark the gash and its blood: about 1 each)
// half: which of the wound layer's two halves (which way round the skin's picture lies where the dab is: wound.m)
static void woundDab(uint8_t *pix, float x, float y, float dx, float dy, float alpha, int kind, float w, const float *style, int half, int *bx0, int *by0, int *bx1, int *by1) {
    const int R = 8;
    for (int yy = (int)y - R; yy <= (int)y + R; yy++) for (int xx = (int)x - R; xx <= (int)x + R; xx++) {
        float rx = xx + 0.5f - x, ry = yy + 0.5f - y;
        float along = rx * dx + ry * dy, across = -rx * dy + ry * dx;
        float a, sr, sg, sb;
        if (kind == 0) {
            float core = expf(-(along * along) / (2 * 2.2f * 2.2f) - (across * across) / (2 * 0.8f * 0.8f * w * w));
            float lip = expf(-(along * along) / (2 * 2.2f * 2.2f) - (across - 1.6f * w) * (across - 1.6f * w) / (2 * 0.45f * 0.45f)) * 0.35f * style[0];
            float bruise = expf(-(along * along) / (2 * 3.5f * 3.5f) - (across * across) / (2 * 4.0f * 4.0f)) * 0.22f * style[1];
            a = fminf(1, core + lip + bruise);
            if (a < 0.01f) continue;
            // the colour each part brings, weighted: the gash near-black red, the glint a pale wet pink, the bruise a dull dark red
            sr = (core * 22 * style[2] + lip * 150 + bruise * 45) / a; sg = (core * style[2] + lip * 70 + bruise * 14) / a; sb = (core * 2 * style[2] + lip * 65 + bruise * 12) / a;
        } else {
            float r2 = kind == 1 ? (across * across) / (2 * 0.55f * 0.55f * w * w) + (along * along) / (2 * 1.4f * 1.4f) : (rx * rx + ry * ry) / (2 * 1.1f * 1.1f * w * w);
            a = expf(-r2) * (kind == 1 ? 0.85f : 0.9f); if (a < 0.01f) continue;
            sr = 30 * style[2]; sg = 1; sb = 3;
        }
        a *= alpha;
        int X = ((xx % kWoundSize) + kWoundSize) % kWoundSize + half * kWoundSize, Y = ((yy % kWoundSize) + kWoundSize) % kWoundSize;
        uint8_t *q = pix + ((size_t)Y * kWoundW + X) * 4;
        float da = q[3] / 255.0f, oa = a + da * (1 - a);
        q[0] = (uint8_t)fminf(255, (sr * a + q[0] * da * (1 - a)) / oa); q[1] = (uint8_t)fminf(255, (sg * a + q[1] * da * (1 - a)) / oa);
        q[2] = (uint8_t)fminf(255, (sb * a + q[2] * da * (1 - a)) / oa); q[3] = (uint8_t)fminf(255, oa * 255);
        if (Y < *by0) *by0 = Y; if (Y + 1 > *by1) *by1 = Y + 1; if (X < *bx0) *bx0 = X; if (X + 1 > *bx1) *bx1 = X + 1;
    }
}
// The cuts kept on each enemy all fight (by choice, FIXES.md 88): at most kMaxCuts; one more makes the oldest fade
// away over a second, and a cut landing on an old one (their middles within kCutNear texels on the texture) replaces it
// instead of painting over it. Each cut is kept as its dabs and colouring, and the layer is repainted from the kept cuts
// 8 times a second while one fades.
#define kMaxCuts 30
#define kCutDabs 200
#define kCutNear 8.0f
#define kCutFade 1.0f
typedef struct { int n; float x[kCutDabs], y[kCutDabs], dx[kCutDabs], dy[kCutDabs], w[kCutDabs]; uint8_t kind[kCutDabs], half[kCutDabs]; float cx, cy, fadeFrom, style[3]; int ch; BOOL fading; } Cut;
typedef struct { Cut c[kMaxCuts + 8]; int n; float lastRepaint; } SkinCuts;
static SkinCuts gCuts[32];
static void cutsClear(int skin) { if (skin >= 0 && skin < 32) gCuts[skin].n = 0; ibfix_wound_clear(skin); }
static void cutsRepaint(int skin, float now) {
    uint8_t *pix = ibfix_wound_pixels(skin); SkinCuts *k = &gCuts[skin]; if (!pix) return;
    memset(pix, 0, (size_t)kWoundW * kWoundSize * 4);
    int bx0 = kWoundW, by0 = kWoundSize, bx1 = 0, by1 = 0;
    for (int i = 0; i < k->n; i++) {
        Cut *c = &k->c[i]; float a = c->fading ? fmaxf(0, 1 - (now - c->fadeFrom) / kCutFade) : 1;
        for (int j = 0; a > 0 && j < c->n; j++) woundDab(pix, c->x[j], c->y[j], c->dx[j], c->dy[j], a, c->kind[j], c->w[j], c->style, c->half[j], &bx0, &by0, &bx1, &by1);
    }
    ibfix_wound_dirty(skin, 0, 0, kWoundW, kWoundSize);
    k->lastRepaint = now;
}
static void cutsTick(float now) {                               // every frame: the fading cuts
    for (int s = 0; s < 32; s++) {
        SkinCuts *k = &gCuts[s]; BOOL any = NO, gone = NO;
        for (int i = 0; i < k->n; i++) if (k->c[i].fading) { any = YES; if (now - k->c[i].fadeFrom >= kCutFade) gone = YES; }
        if (!any) continue;
        if (gone) {                                             // faded away: dropped from the list
            int n = 0; for (int i = 0; i < k->n; i++) if (!(k->c[i].fading && now - k->c[i].fadeFrom >= kCutFade)) k->c[n++] = k->c[i];
            k->n = n; cutsRepaint(s, now);
        } else if (now - k->lastRepaint >= 1.0f / 8 || now < k->lastRepaint) cutsRepaint(s, now);   // 8 a second (each repaints all 30)
    }
}
// a mesh's torso bones (spine, neck, collarbones), by name, once per skin
static const uint8_t *torsoBones(uint8_t *meshComp, WMesh *m) {
    static uint8_t mark[32][128]; static BOOL done[32];
    int k = (int)(m - gWM); if (k < 0 || k >= 32) return NULL;
    if (!done[k]) {
        done[k] = YES; int n = MIN(boneCount(meshComp), 128), found = 0;
        for (int b = 0; b < n; b++) {
            NSString *nm = boneNameOf(meshComp, b);
            if (nm && ([nm containsString:@"Spine"] || [nm containsString:@"Neck"] || [nm containsString:@"Clavicle"])) { mark[k][b] = 1; found++; }
        }
        LOG(@"wounds: %s's torso: %d bones", m->name, found);
    }
    return mark[k];
}
#ifdef IBFIX_SNAPS
// Test builds, settings key ibfixWoundTest: once his skin is on screen, every triangle of it is painted a see-through
// green into the half its winding gives, with the shared-the-same-way places left bare. If the pixel shader picks the
// halves the same way, all of him turns green; turned round, only the mirrored parts would (each finding its twin's).
static void woundSideTest(uint8_t *meshComp) {
    static int on = -1; static uint8_t *done; static CFAbsoluteTime lookedAt; if (on < 0) on = [[NSUserDefaults standardUserDefaults] boolForKey:@"ibfixWoundTest"];
    if (!on || done) return;
    if (!meshComp && CFAbsoluteTimeGetCurrent() - lookedAt > 1) {   // before his fight: the boss standing at the save point
        lookedAt = CFAbsoluteTimeGetCurrent(); void *found[4]; int n = ibfix_objects_of_class("SwordBoss", found, 4);
        if (n > 0) meshComp = objAt(found[0], "Mesh");
    }
    if (!meshComp) return;
    uint8_t *skel = objAt(meshComp, "SkeletalMesh"); if (!skel) return;
    const char *nm = ibfix_objname(skel).UTF8String; WMesh *m = NULL;
    for (int i = 0; i < gNWM; i++) if (!strcmp(gWM[i].name, nm)) m = &gWM[i];
    if (!m || !ibfix_wound_skin_shown(m->skin)) return;
    uint8_t *pix = ibfix_wound_pixels(m->skin); if (!pix) return;
    done = meshComp; int painted = 0;
    for (int t = 0; t < m->nt; t++) {
        const float *a = &m->uv[m->tri[t * 3] * 2], *b = &m->uv[m->tri[t * 3 + 1] * 2], *c = &m->uv[m->tri[t * 3 + 2] * 2];
        float wnd = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]); if (fabsf(wnd) < 1e-12f) continue;
        int half = wnd < 0 ? 0 : 1;
        float ax = a[0] * kWoundSize, ay = a[1] * kWoundSize, bx = b[0] * kWoundSize, by = b[1] * kWoundSize, cx = c[0] * kWoundSize, cy = c[1] * kWoundSize;
        int x0 = (int)floorf(fminf(ax, fminf(bx, cx))), x1 = (int)ceilf(fmaxf(ax, fmaxf(bx, cx))), y0 = (int)floorf(fminf(ay, fminf(by, cy))), y1 = (int)ceilf(fmaxf(ay, fmaxf(by, cy)));
        if (x1 - x0 > kWoundSize / 2 || y1 - y0 > kWoundSize / 2) continue;
        float den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
        for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) {
            float px = x + 0.5f, py = y + 0.5f, l0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den, l1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den;
            if (l0 < -0.01f || l1 < -0.01f || 1 - l0 - l1 < -0.01f || texShared(m, px, py)) continue;
            int X = ((x % kWoundSize) + kWoundSize) % kWoundSize + half * kWoundSize, Y = ((y % kWoundSize) + kWoundSize) % kWoundSize;
            uint8_t *q = pix + ((size_t)Y * kWoundW + X) * 4; q[0] = 40; q[1] = 220; q[2] = 60; q[3] = 140; painted++;
        }
    }
    ibfix_wound_dirty(m->skin, 0, 0, kWoundW, kWoundSize);
    LOG(@"wounds: side test: %s painted green, %d texels, each triangle in its own half", m->name, painted);
}
#endif
// A stab leaves a stab wound instead: a short gaping slit across the body, with long trickles. stab 1: the blade is in
// him now, and the wound goes where it enters his skin (of the skin within 12 units of the blade, the nearest the hilt;
// the tip can be deep inside him); stab 2: by stabAt, on its side facing the camera (a fight stab's weak spot, the
// circle tapped; the killing stab's, where the fountain starts: the game plays its stab effect before the sword reaches
// the head). Bare skin if any is within 10 units of the nearest skin.
static void woundCut(uint8_t *meshComp, const float swing0[3], float length, BOOL toTorso, int stab, const float *stabAt) {
    if (stab != 2) stabAt = NULL;
    uint8_t *skel = objAt(meshComp, "SkeletalMesh"); if (!skel) return;
    const char *nm = ibfix_objname(skel).UTF8String; WMesh *m = NULL;
    for (int i = 0; i < gNWM; i++) if (!strcmp(gWM[i].name, nm)) m = &gWM[i];
    static int told; if (!m) { if (told++ < 3) LOG(@"wounds: no skin for %s", nm); return; }
    uint8_t *pix = ibfix_wound_pixels(m->skin); if (!pix) return;
    static uint8_t *lastMesh; if (meshComp != lastMesh) { lastMesh = meshComp; cutsClear(m->skin); }   // a new enemy: clean
    // his skin where it is now
    static float *pos; static int cap; if (cap < m->nw) { cap = m->nw; pos = realloc(pos, sizeof(float) * 3 * cap); }
    for (int i = 0; i < m->nw; i++) {
        float acc[3] = {0, 0, 0};
        for (int j = m->first[i]; j < m->first[i + 1]; j++) { float w3[3]; if (boneToWorld(meshComp, m->bone[j], &m->local[j * 3], w3)) for (int k = 0; k < 3; k++) acc[k] += m->w[j] * w3[k]; }
        memcpy(&pos[i * 3], acc, 12);
    }
    // where the cut goes: one of the bare corners within 20 units of the bare one nearest the blade, at random, so cuts
    // don't keep landing on one spot; armour only when no bare skin is within 80 units more than the nearest of anything
    static float *dist; static int dcap; if (dcap < m->nw) { dcap = m->nw; dist = realloc(dist, sizeof(float) * dcap); }
    float ax[3]; vsub(gBladeT, gBladeH, ax); float L2 = vdot(ax, ax); int best = -1; float bd = 1e9, bdBare = 1e9;
    for (int i = 0; i < m->nw; i++) {
        float hp[3]; vsub(&pos[i * 3], gBladeH, hp); float t = L2 > 0 ? fminf(1, fmaxf(0, vdot(hp, ax) / L2)) : 0;
        float q[3] = { gBladeH[0] + ax[0] * t - pos[i * 3], gBladeH[1] + ax[1] * t - pos[i * 3 + 1], gBladeH[2] + ax[2] * t - pos[i * 3 + 2] };
        if (stabAt) vsub(stabAt, &pos[i * 3], q);              // the killing stab: from where the blade went in
        if (m->shared[i]) { dist[i] = 1e9f; continue; }        // a place his picture shares the same way round: never there
        dist[i] = vlen(q); if (dist[i] < bd) { bd = dist[i]; best = i; }
        if (m->bare[i] && dist[i] < bdBare) bdBare = dist[i];
        if (stab == 1) dist[i] = dist[i] < 12 ? t : 1e9f;       // a stab in the fight: how far along the blade it enters
    }
    BOOL onSkin = bdBare < 1e8f && bdBare <= bd + (stab ? 10 : 80), torso = NO;
    if (stab) {                                                 // no wandering
        toTorso = NO;
        if (stab == 1) {                                        // the entry: the skin near the blade nearest the hilt (bare if close)
            int e = -1, eb = -1;
            for (int i = 0; i < m->nw; i++) if (dist[i] < 1e8f) { if (e < 0 || dist[i] < dist[e]) e = i; if (m->bare[i] && (eb < 0 || dist[i] < dist[eb])) eb = i; }
            if (eb >= 0 && e >= 0 && (dist[eb] - dist[e]) * sqrtf(L2) <= 10) e = eb;
            if (e >= 0) best = e;                               // (none within 12 units: the nearest skin to the blade)
            float hp[3]; vsub(&pos[best * 3], gBladeH, hp); float t = L2 > 0 ? fminf(1, fmaxf(0, vdot(hp, ax) / L2)) : 0;
            float q[3] = { gBladeH[0] + ax[0] * t - pos[best * 3], gBladeH[1] + ax[1] * t - pos[best * 3 + 1], gBladeH[2] + ax[2] * t - pos[best * 3 + 2] };
            bd = vlen(q);
        } else {                                                // at a point (a weak spot, the head): the skin by it on the side facing
            float cam[3]; BOOL camOK = ibfix_camera_location(cam); int e = -1; float ec = 1e9;   // the camera, not his back
            for (int i = 0; i < m->nw; i++) if (dist[i] <= bd + 15) {
                float dc[3]; if (camOK) vsub(&pos[i * 3], cam, dc);
                float c = (camOK ? vlen(dc) : dist[i]) - (m->bare[i] ? 10 : 0);
                if (c < ec) { ec = c; e = i; }
            }
            if (e >= 0) { best = e; bd = dist[e]; }
        }
        onSkin = NO;
    }
    if (toTorso) {                                              // a giant's up or down slash: bare torso skin, above where the blade met him
        const uint8_t *tb = torsoBones(meshComp, m); float hit[3], bh = 1e9;
        memcpy(hit, &pos[best * 3], 12);
        for (int i = 0; tb && i < m->nw; i++) if (m->bare[i] && m->n[i] && tb[m->bone[m->first[i]]]) {
            float h = hypotf(pos[i * 3] - hit[0], pos[i * 3 + 1] - hit[1]); if (h < bh) bh = h;   // across, not up
        }
        if (bh < 1e8f) {
            int n = 0, pick = -1;
            for (int i = 0; i < m->nw; i++) if (m->bare[i] && m->n[i] && tb[m->bone[m->first[i]]] &&
                hypotf(pos[i * 3] - hit[0], pos[i * 3 + 1] - hit[1]) <= bh + 30 && arc4random_uniform(++n) == 0) pick = i;
            if (pick >= 0) { best = pick; bd = dist[pick]; torso = YES; onSkin = NO; }
        }
    }
    if (onSkin) {                                               // a bare corner near the nearest bare one, at random
        int n = 0, pick = -1;
        for (int i = 0; i < m->nw; i++) if (m->bare[i] && dist[i] <= bdBare + 20 && arc4random_uniform(++n) == 0) pick = i;
        if (pick >= 0) { best = pick; bd = dist[pick]; }
    }
    if (best < 0 || (bd > (stab ? 60 : 160) && !torso)) { LOG(@"wounds: the blade is %.0f units from %s's skin: no %@", bd, nm, stab ? @"stab wound" : @"cut"); return; }
    float C[3]; memcpy(C, &pos[best * 3], 12);
    // the skin's facing there, and the triangles near
    float nrm[3] = {0, 0, 0}; static int *near; static int ncap; if (ncap < m->nt) { ncap = m->nt; near = realloc(near, sizeof(int) * ncap); } int nn = 0;
    float reach = length * 0.5f + 15;
    for (int t = 0; t < m->nt; t++) {
        const float *a = &pos[m->tri[t * 3] * 3], *b = &pos[m->tri[t * 3 + 1] * 3], *c = &pos[m->tri[t * 3 + 2] * 3];
        float da[3], db[3], dc[3]; vsub(a, C, da); vsub(b, C, db); vsub(c, C, dc);
        if (vlen(da) > reach && vlen(db) > reach && vlen(dc) > reach) continue;
        near[nn++] = t;
        if (vlen(da) < 8 || vlen(db) < 8 || vlen(dc) < 8) {
            float e1[3], e2[3]; vsub(b, a, e1); vsub(c, a, e2);
            float n3[3] = { e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
            for (int k = 0; k < 3; k++) nrm[k] += n3[k];
        }
    }
    vnorm(nrm);
    float d[3] = { swing0[0], swing0[1], swing0[2] };
    if (stab) { d[0] = -nrm[1]; d[1] = nrm[0]; d[2] = 0; }     // a stab's slit lies across the body (level), whatever the blade did
    float in = vdot(d, nrm); for (int k = 0; k < 3; k++) d[k] -= in * nrm[k];
    if (vlen(d) < 1e-3f) { d[0] = ax[1] * nrm[2] - ax[2] * nrm[1]; d[1] = ax[2] * nrm[0] - ax[0] * nrm[2]; d[2] = ax[0] * nrm[1] - ax[1] * nrm[0]; }
    vnorm(d);
    // walk the cut, keeping its dabs. No two alike: each cut its own length, bend, waver, deepest point and width,
    // sometimes a skip where the blade lifted and a second shallow nick beside it, and its own colouring
    float pv[3] = { nrm[1] * d[2] - nrm[2] * d[1], nrm[2] * d[0] - nrm[0] * d[2], nrm[0] * d[1] - nrm[1] * d[0] };   // across it, along the skin
    float len0 = length * (stab ? 0.7f + 0.6f * frand() : 0.55f + 0.8f * frand()), widthK = stab ? 0.8f + 0.5f * frand() : 0.7f + 0.65f * frand();
    int bx0 = kWoundW, by0 = kWoundSize, bx1 = 0, by1 = 0, midTri = -1, mainN = 0; float midS = 1e9;
    Cut cut = { 0 };
    cut.style[0] = 0.3f + 1.0f * frand(); cut.style[1] = 0.5f + 0.9f * frand(); cut.style[2] = 0.6f + 0.8f * frand();
    int strokes = !stab && frand() < 0.3f ? 2 : 1;
    for (int st = 0; st < strokes; st++) {
        float L = st ? len0 * (0.25f + 0.25f * frand()) : len0, half = L * 0.5f;
        float off0 = st ? (frand() < 0.5f ? -1 : 1) * (2.5f + 2 * frand()) : 0, along0 = st ? (frand() - 0.5f) * len0 * 0.5f : 0;
        float bend = (frand() * 2 - 1) * (stab ? 0.08f : 0.18f) * L, wob = (0.2f + 0.8f * frand()) * (stab ? 0.4f : 1), lam = 4 + 6 * frand(), ph = 6.2832f * frand();
        float s0 = (frand() - 0.5f) * 0.6f * half, gap0 = !stab && !st && frand() < 0.25f ? (frand() - 0.5f) * L * 0.6f : 1e9f, gapL = 1.5f + 2 * frand();
        float wk = st ? widthK * 0.5f : widthK, lastUV[2] = { -1, -1 }, dir[2] = { 1, 0 }; int dabs = 0;
        for (float s = -half; s <= half; s += stab ? 0.5f : 1.0f) {
            if (s > gap0 && s < gap0 + gapL) continue;          // the blade lifted here
            float u = s / fmaxf(half, 1), off = off0 + bend * (1 - u * u) + wob * sinf(6.2832f * s / lam + ph);
            float q[3] = { C[0] + d[0] * (s + along0) + pv[0] * off, C[1] + d[1] * (s + along0) + pv[1] * off, C[2] + d[2] * (s + along0) + pv[2] * off }, bestB[3] = {0};
            int bt = -1; float bdist = 1e9;
            for (int k = 0; k < nn; k++) {
                int t = near[k]; const float *a = &pos[m->tri[t * 3] * 3], *b = &pos[m->tri[t * 3 + 1] * 3], *c = &pos[m->tri[t * 3 + 2] * 3];
                float br[3]; closestOnTri(q, a, b, c, br);
                float cp[3] = { a[0] * br[0] + b[0] * br[1] + c[0] * br[2] - q[0], a[1] * br[0] + b[1] * br[1] + c[1] * br[2] - q[1], a[2] * br[0] + b[2] * br[1] + c[2] * br[2] - q[2] };
                float dd = vlen(cp); if (dd < bdist) { bdist = dd; bt = t; memcpy(bestB, br, 12); }
            }
            if (bt < 0 || bdist > 10) continue;                 // off his skin here
            const float *u0 = &m->uv[m->tri[bt * 3] * 2], *u1 = &m->uv[m->tri[bt * 3 + 1] * 2], *u2 = &m->uv[m->tri[bt * 3 + 2] * 2];
            float uv[2] = { (u0[0] * bestB[0] + u1[0] * bestB[1] + u2[0] * bestB[2]) * kWoundSize, (u0[1] * bestB[0] + u1[1] * bestB[1] + u2[1] * bestB[2]) * kWoundSize };
            if (texShared(m, uv[0], uv[1])) continue;           // shared the same way round: no part of a cut there
            // which half: the triangle's winding on the texture, in the game's own corner order (the .psk's first two
            // corners swapped back); the pixel shader picks the half the same way from the screen
            float wnd = (u1[0] - u0[0]) * (u2[1] - u0[1]) - (u1[1] - u0[1]) * (u2[0] - u0[0]);
            int half = wnd < 0 ? 0 : 1;
            if (lastUV[0] >= 0) { float ddx = uv[0] - lastUV[0], ddy = uv[1] - lastUV[1], l = sqrtf(ddx * ddx + ddy * ddy); if (l > 0.3f && l < 12) { dir[0] = ddx / l; dir[1] = ddy / l; } }
            // deepest at its own point along it, fading to its ends
            float f = 1 - fabsf(s - s0) / (half + fabsf(s0) + 1);
            if (!st && fabsf(s) < midS) { midS = fabsf(s); midTri = bt; }
            if ((f > 0.15f || dabs % 2 == 0) && cut.n < (st ? 110 : 95)) {   // a ragged gash: each dab's width varies
                cut.x[cut.n] = uv[0]; cut.y[cut.n] = uv[1]; cut.dx[cut.n] = dir[0]; cut.dy[cut.n] = dir[1]; cut.half[cut.n] = half;
                cut.w[cut.n] = wk * (stab ? (1.7f + 0.6f * frand()) * (0.45f + 0.55f * f) : (0.55f + 0.65f * frand()) * (0.4f + 0.6f * f)); cut.kind[cut.n] = 0; cut.n++;
            }
            memcpy(lastUV, uv, 8); dabs++;
        }
        if (!st) mainN = cut.n;
    }
    if (!mainN) return;
    // drips: which way is down on the texture where the cut is (the world's down, along the skin, through the middle
    // triangle's texture directions), then one to three trickles from points along the gash
    float down[2] = { 0, 1 };
    if (midTri >= 0) {
        const float *p0 = &pos[m->tri[midTri * 3] * 3], *p1 = &pos[m->tri[midTri * 3 + 1] * 3], *p2 = &pos[m->tri[midTri * 3 + 2] * 3];
        const float *t0 = &m->uv[m->tri[midTri * 3] * 2], *t1 = &m->uv[m->tri[midTri * 3 + 1] * 2], *t2 = &m->uv[m->tri[midTri * 3 + 2] * 2];
        float e1[3], e2[3]; vsub(p1, p0, e1); vsub(p2, p0, e2);
        float du1 = (t1[0] - t0[0]) * kWoundSize, dv1 = (t1[1] - t0[1]) * kWoundSize, du2 = (t2[0] - t0[0]) * kWoundSize, dv2 = (t2[1] - t0[1]) * kWoundSize;
        float det = du1 * dv2 - du2 * dv1;
        if (fabsf(det) > 1e-6f) {
            float T[3], Bv[3], g[3] = { -nrm[0] * -nrm[2], -nrm[1] * -nrm[2], -1 - nrm[2] * -nrm[2] };   // down, along the skin
            for (int k = 0; k < 3; k++) { T[k] = (e1[k] * dv2 - e2[k] * dv1) / det; Bv[k] = (e2[k] * du1 - e1[k] * du2) / det; }
            float a11 = vdot(T, T), a12 = vdot(T, Bv), a22 = vdot(Bv, Bv), b1 = vdot(T, g), b2 = vdot(Bv, g), dd = a11 * a22 - a12 * a12;
            if (fabsf(dd) > 1e-9f) { float u = (b1 * a22 - b2 * a12) / dd, v = (a11 * b2 - a12 * b1) / dd, l = hypotf(u, v); if (l > 1e-6f) { down[0] = u / l; down[1] = v / l; } }
        }
    }
    // trickles: each cut its own number (a slash none to three, a stab two to five), each its own length, width and
    // wander, ending in a drop of its own size; then, off a slash, a few specks thrown on past its end the way the blade went
    int drips = stab ? 2 + (int)arc4random_uniform(4) : (int)arc4random_uniform(4);
    float across2[2] = { -down[1], down[0] };
    for (int k = 0; k < drips && cut.n < kCutDabs - 12; k++) {
        int from = (int)(mainN * (0.1f + 0.8f * frand())), h = cut.half[from]; float len = stab ? 10 + 28 * frand() : 4 + 26 * frand(), x = cut.x[from], y = cut.y[from];
        float wv = (frand() * 2 - 1) * 1.2f, wl = 5 + 8 * frand(), wph = 6.2832f * frand(), dw = 0.8f + 0.6f * frand(), ex = 0, ey = 0; int steps = 0;
        for (float t = 0; t < len && cut.n < kCutDabs - 12; t += 1.2f) {
            float side = wv * sinf(6.2832f * t / wl + wph);
            float nx = x + down[0] * t + across2[0] * side, ny = y + down[1] * t + across2[1] * side;
            if (texShared(m, nx, ny)) break;                    // runs onto a shared place: stops there
            ex = nx; ey = ny; steps++;
            cut.x[cut.n] = ex; cut.y[cut.n] = ey; cut.dx[cut.n] = down[0]; cut.dy[cut.n] = down[1]; cut.half[cut.n] = h;
            cut.w[cut.n] = dw * (1.1f - 0.5f * t / len); cut.kind[cut.n] = 1; cut.n++;
        }
        if (!steps) continue;                                   // stopped at once
        cut.x[cut.n] = ex + down[0] * 1.2f; cut.y[cut.n] = ey + down[1] * 1.2f; cut.dx[cut.n] = down[0]; cut.dy[cut.n] = down[1]; cut.half[cut.n] = h; cut.w[cut.n] = 0.7f + 0.9f * frand(); cut.kind[cut.n] = 2; cut.n++;
    }
    if (!stab && mainN > 2) {
        float ex = cut.x[mainN - 1], ey = cut.y[mainN - 1], fx = cut.dx[mainN - 1], fy = cut.dy[mainN - 1];
        for (int k = (int)arc4random_uniform(6); k > 0 && cut.n < kCutDabs; k--) {
            float r = 2 + 9 * frand(), sd = nrand() * 1.8f;
            if (texShared(m, ex + fx * r - fy * sd, ey + fy * r + fx * sd)) continue;
            cut.x[cut.n] = ex + fx * r - fy * sd; cut.y[cut.n] = ey + fy * r + fx * sd; cut.dx[cut.n] = fx; cut.dy[cut.n] = fy; cut.half[cut.n] = cut.half[mainN - 1];
            cut.w[cut.n] = 0.25f + 0.35f * frand(); cut.kind[cut.n] = 2; cut.n++;
        }
    }
    cut.n = MIN(cut.n, kCutDabs);
    int gash = mainN;
    cut.cx = cut.x[gash / 2]; cut.cy = cut.y[gash / 2]; cut.ch = cut.half[gash / 2];
    // keep at most kMaxCuts: one landing on an old cut replaces it; past the limit the oldest fades away
    SkinCuts *k = &gCuts[m->skin]; float now = worldTime(); int kept = 0, replaced = 0, retired = 0;
    for (int i = 0; i < k->n; i++) {
        Cut *c = &k->c[i]; if (c->fading) continue;
        if (c->ch == cut.ch && hypotf(c->cx - cut.cx, c->cy - cut.cy) < kCutNear) { c->fading = YES; c->fadeFrom = now; replaced++; } else kept++;
    }
    for (int i = 0; i < k->n && kept >= kMaxCuts; i++) if (!k->c[i].fading) { k->c[i].fading = YES; k->c[i].fadeFrom = now; kept--; retired++; }
    if (k->n >= kMaxCuts + 8) { memmove(k->c, k->c + 1, sizeof(Cut) * (size_t)(k->n - 1)); k->n--; }   // never more than the room (a fading one goes at once)
    k->c[k->n++] = cut;
    for (int j = 0; j < cut.n; j++) woundDab(pix, cut.x[j], cut.y[j], cut.dx[j], cut.dy[j], 1, cut.kind[j], cut.w[j], cut.style, cut.half[j], &bx0, &by0, &bx1, &by1);
    if (bx1 > bx0) ibfix_wound_dirty(m->skin, bx0, by0, bx1, by1);
    LOG(@"wounds: a %@ on %s's %@, %d dabs, the blade %.0f units from it; %d kept%@%@, %@", stab ? @"stab wound" : @"cut", nm, torso ? @"torso (a giant's up or down slash)" : onSkin || (stab && m->bare[best]) ? @"bare skin" : @"armour", cut.n, bd, kept + 1,
        replaced ? [NSString stringWithFormat:@", %d under it replaced", replaced] : @"", retired ? [NSString stringWithFormat:@", the oldest fading (%d)", retired] : @"",
        ibfix_wound_skin_shown(m->skin) ? @"his skin is on screen" : @"his skin NOT seen uploaded");
}
// the blue circle tapped for a stab in the fight (a SwordBossTouchActor, at one of his weak spots): the stab wound goes
// by it, since the blade itself often ends short of him (the game times the hit by the animation)
static struct { void *actor; float at; } gStabSpot;
static void bloodStabSpot(void *actor) { gStabSpot.actor = actor; gStabSpot.at = worldTime(); }
// A stab going in: the killing stab (into the head), or one in the fight after a good parry. Both play the knight's Stab
// effect (DoStabAttackAnim.DoStabPauseFX, PlayFX(FXIndexStab), as the blade lands); each leaves a stab wound where the
// blade went in, and the blood comes when the blade comes out (stabTick).
static void bloodStab(NSString *tag, BOOL kill) {
    uint8_t *mesh = bossMesh(); NSString *what = kill ? @"killing stab" : @"stab";
    if (!mesh || !gBladeKnown) { LOG(@"blood: %@ (%@), but %@", what, tag, mesh ? @"the blade isn't known" : @"no boss mesh"); return; }
    if (!meshBleeds(mesh)) { LOG(@"blood: %@ on %@: not a living enemy, no blood", what, ibfix_objname(objAt(mesh, "SkeletalMesh"))); return; }
    int head = -1, n = boneCount(mesh);
    for (int b = 0; kill && b < n && head < 0; b++) { NSString *s = boneNameOf(mesh, b); if (s && [s rangeOfString:@"Head" options:NSCaseInsensitiveSearch].length) head = b; }
    int bone = -1; float pt[3], f = 0;
    float dist = bladeNearest(mesh, head, &bone, pt, &f);
    if (bone < 0) return;
    gStab.mesh = (ObjRef){ mesh, *(int *)(mesh + 0x38), CLS(mesh) }; gStab.bone = bone; gStab.out = NO; gStab.kill = kill; gStab.at = worldTime();
    worldToBone(mesh, bone, pt, gStab.local); gStab.depth = 0;
    // a first spurt as the blade goes in, back along it and up
    float ax2[3]; vsub(gBladeH, gBladeT, ax2); vnorm(ax2); float up2[3] = { ax2[0] * 0.5f, ax2[1] * 0.5f, ax2[2] * 0.5f + 0.9f }; vnorm(up2);
    bloodSpray(pt, up2, 300, 0.25f, kill ? 40 : 24, kill ? 30 : 16, 2.4f);
    LOG(@"blood: %@ (%@): the wound at %@'s bone %@ (%@), the blade %.0f units from it at %.0f%% along", what, tag, ibfix_objname(mesh),
        boneNameOf(mesh, bone) ?: @"?", head >= 0 ? @"his head" : kill ? @"no head bone: the nearest" : @"nearest the blade", dist, 100 * f);
    if (!kill) {                                                // the killing stab's: as the blade comes out (stabTick)
        float ax[3]; vsub(gBladeT, gBladeH, ax); vnorm(ax);
        uint8_t *a = gStabSpot.actor; int oL = a && isLiveObject(a) && worldTime() - gStabSpot.at < 2 ? poff(CLS(a), "Location") : -1;
        if (oL >= 0) { float spot[3]; memcpy(spot, a + oL, 12); LOG(@"blood: the stab went in at the circle tapped, %@", ibfix_objname(a)); woundCut(mesh, ax, 9, NO, 2, spot); }
        else woundCut(mesh, ax, 9, NO, 1, NULL);
        gStabSpot.actor = NULL;
    }
}
static void stabTick(float now) {                               // waiting for the blade to come out of the wound
    if (!gStab.mesh.obj || gStab.out) return;
    if (!refLive(&gStab.mesh) || now - gStab.at > 6) { gStab.mesh.obj = NULL; return; }
    float w[3]; if (!boneToWorld(gStab.mesh.obj, gStab.bone, gStab.local, w)) return;
    // how far the blade's tip has gone past the wound along the blade (in: positive), from the hilt
    float ax[3]; vsub(gBladeT, gBladeH, ax); float L = vlen(ax); if (L < 1) return; vnorm(ax);
    float hw[3]; vsub(w, gBladeH, hw); float tipPast = L - vdot(hw, ax);
    float perp[3] = { hw[0] - ax[0] * vdot(hw, ax), hw[1] - ax[1] * vdot(hw, ax), hw[2] - ax[2] * vdot(hw, ax) };
    if (tipPast > gStab.depth) gStab.depth = tipPast;
    // the blade starting to come out (6 units back from the deepest), or well away from the wound: the fountain starts now
    BOOL out = gStab.depth > 8 && (gStab.depth - tipPast > 6 || vlen(perp) > 30);
    if (!out) return;
    gStab.out = YES;
    float up[3] = { -ax[0] * 0.6f, -ax[1] * 0.6f, -ax[2] * 0.6f + 0.8f }; vnorm(up);   // back along the blade and upward
    float local[3]; memcpy(local, gStab.local, 12);
    if (gStab.kill) {                                           // the stab wound where the fountain starts, and the fountain
        float wp[3]; if (boneToWorld(gStab.mesh.obj, gStab.bone, gStab.local, wp)) woundCut(gStab.mesh.obj, ax, 9, NO, 2, wp);
        addWound(gStab.mesh.obj, gStab.bone, local, up, now, kFountainBlows * kFountainBlow, 1.0f, 1);   // six blows of 0.45 s, full strength
        addWound(gStab.mesh.obj, gStab.bone, local, up, now + 1.5f, 2.5f, 0.05f, 0);
    } else {                                                    // a stab in the fight: two blows at half strength
        addWound(gStab.mesh.obj, gStab.bone, local, up, now, 2 * kFountainBlow, 0.5f, 1);
        addWound(gStab.mesh.obj, gStab.bone, local, up, now + 0.6f, 2.0f, 0.08f, 0);
    }
    LOG(@"blood: the blade came out of the %@ (it went %.0f units in): the %@", gStab.kill ? @"head" : @"stab wound", gStab.depth, gStab.kill ? @"fountain" : @"spurt");
}
static void woundsTick(float now, float dt) {
    for (int i = 0; i < gNWounds; ) {
        Wound *w = &gWounds[i];
        if (now > w->until || !refLive(&w->mesh)) { memmove(w, w + 1, sizeof(Wound) * (size_t)(gNWounds - i - 1)); gNWounds--; continue; }
        float p[3], o[3] = {0, 0, 0}, bw[3], dir[3];
        if (now >= w->start && boneToWorld(w->mesh.obj, w->bone, w->local, p)) {
            // the wound's outward direction moves with its bone too
            boneToWorld(w->mesh.obj, w->bone, o, bw);
            if (w->kind == 1) {
                // The fountain: blows of kFountainBlow, each starting sharply and dying away, each 0.85 of the last:
                // thick mist shooting up from the wound and billowing above him, and a jet of drops arcing up and
                // falling; the first blow opens with a gush. Strength (every): 1 for the head, 0.5 for a fight stab.
                float t = now - w->start, ph = t / kFountainBlow, str = w->every;
                float blow = floorf(ph), pulse = expf(-5 * (ph - blow)) * powf(0.85f, blow) * str;
                float d0[3] = { w->dir[0], w->dir[1], w->dir[2] }; vnorm(d0);
                if (w->next == w->start) { w->next = w->start + 1e4f; bloodSpray(p, d0, 480 * str + 120, 0.16f, (int)(90 * str), (int)(40 * str), 2.6f); }   // the gush
                int puffs = (int)(dt * 1400 * pulse + frand()), drops = (int)(dt * 520 * pulse + frand());
                for (int m = 0; m < puffs + drops; m++) {
                    BOOL drop = m >= puffs; float s = drop ? 0.14f : 0.16f;
                    float d[3] = { d0[0] + nrand() * s, d0[1] + nrand() * s, d0[2] + nrand() * s }; vnorm(d);
                    float sp = 520 * (0.7f + 0.6f * frand()) * (0.6f + 0.4f * fminf(1, pulse / fmaxf(str, 0.05f))) * (drop ? 1.0f : 1);
                    float v[3] = { d[0] * sp, d[1] * sp, d[2] * sp }, q[3] = { p[0] + nrand() * 2, p[1] + nrand() * 2, p[2] + nrand() * 2 };
                    if (drop) bloodAdd(q, v, 0.5f * expf(0.45f * nrand()), 1.6f, 0.3f, 1.0f, 0);   // arcs up and falls
                    else bloodAdd(q, v, 2.2f + 1.6f * frand(), 1.0f + 0.5f * frand(), 3.0f, 0.38f, 2);
                }
            } else if (now >= w->next) {                        // drips: a drop now and then, falling from the cut
                w->next = now + w->every * (0.6f + 0.8f * frand());
                vsub(p, bw, dir); vnorm(dir);
                float v[3] = { dir[0] * 25, dir[1] * 25, dir[2] * 25 - 10 };
                bloodAdd(p, v, 0.9f + 0.7f * frand(), 1.5f, 0.5f, 1.0f, 0);
            }
        }
        i++;
    }
}
// The swing trails (the big coloured ribbons): each attack's AnimNotify_Trails draws a ribbon between the weapon's
// sockets RSword_Bottom (41 units up the blade bone, b_MF_Weapon_R) and RSword_Top (114), bent through RSword_Control
// (72). Blood mode adds two sockets of the trails' own near the top (100 and 107 units up; copies of Bottom and Control
// on the knight's merged mesh) and points his trail notifies at them: a thin streak along the blade's edge. No socket of
// the game's moves: other effects hang on them (the Infinity Blade's strike glow on RSword_Bottom). The new sockets are
// named with two names the game already has (the trail's own property names), so no mesh has a socket called that.
static void *newFromTemplate(void *cls, void *outer, void *tmpl);   // 4v (the copy button)
static void *classObject(const char *name);
static const float kTrailBottomZ = 100, kTrailControlZ = 107;
static struct { uint8_t *n; int first[2], control[2]; } gTrailKept[256]; static int gNTrailKept;
static uint8_t *gSockDone;                                      // the knight's merged mesh the trails were set up on
static void bloodTrailRestore(void) {
    int put = 0;
    for (int i = 0; i < gNTrailKept; i++) if (isLiveObject(gTrailKept[i].n)) {
        void *c = CLS(gTrailKept[i].n); int oF = poff(c, "FirstEdgeSocketName"), oC = poff(c, "ControlPointSocketName");
        if (oF >= 0) memcpy(gTrailKept[i].n + oF, gTrailKept[i].first, 8);
        if (oC >= 0) memcpy(gTrailKept[i].n + oC, gTrailKept[i].control, 8);
        put++;
    }
    if (put) LOG(@"blood mode off: %d swing trails back on the game's own sockets", put);
    gNTrailKept = 0; gSockDone = NULL;
}
static void bloodTrailSockets(void) {
    uint8_t *const done = gSockDone; static int tries;
    uint8_t *pawn = playerPawn(), *mesh = pawn ? objAt(pawn, "Mesh") : NULL, *skel = mesh ? objAt(mesh, "SkeletalMesh") : NULL;
    if (!skel || skel == done || tries > 600) return;
    tries++;
    int oS = poff(CLS(skel), "Sockets");
    struct { uint8_t **data; int num, max; } *arr = oS >= 0 ? (void *)(skel + oS) : NULL;
    int bottom = nameIndex("RSword_Bottom"), control = nameIndex("RSword_Control");
    int ownB = nameIndex("FirstEdgeSocketName"), ownC = nameIndex("ControlPointSocketName");
    if (!arr || !arr->data || bottom < 0 || control < 0 || ownB < 0 || ownC < 0) return;
    // 1. the trails' own two sockets on this mesh (once per merged mesh: a new one is made at each change of equipment)
    uint8_t *srcB = NULL, *srcC = NULL; BOOL haveB = NO, haveC = NO;
    for (int i = 0; i < arr->num && i < 64; i++) {
        uint8_t *so = arr->data[i]; if (!plausibleObj(so)) continue;
        int oN = poff(CLS(so), "SocketName"); if (oN < 0) continue;
        int nm = *(int *)(so + oN);
        if (nm == bottom) srcB = so; else if (nm == control) srcC = so; else if (nm == ownB) haveB = YES; else if (nm == ownC) haveC = YES;
    }
    if (!srcB || !srcC) return;
    void *sockCls = classObject("SkeletalMeshSocket");
    for (int k = 0; k < 2; k++) {
        if (k ? haveC : haveB) continue;
        uint8_t *so = newFromTemplate(sockCls, skel, k ? srcC : srcB);
        if (!so) { LOG(@"blood mode: the swing trail's own socket couldn't be made: trails left as they are"); tries = 1000; return; }
        void *c = CLS(so); int oN = poff(c, "SocketName"), oL = poff(c, "RelativeLocation");
        if (oN < 0 || oL < 0) return;
        *(int *)(so + oN) = k ? ownC : ownB; *(int *)(so + oN + 4) = 0;
        ((float *)(so + oL))[2] = k ? kTrailControlZ : kTrailBottomZ;
        if (arr->num == arr->max) {
            void *(*appRealloc)(void *, uint32_t, uint32_t) = (void *(*)(void *, uint32_t, uint32_t))(IB1_APPREALLOC + _dyld_get_image_vmaddr_slide(0));
            uint8_t **d = appRealloc(arr->data, (uint32_t)((arr->max + 4) * sizeof(void *)), 8); if (!d) return;
            arr->data = d; arr->max += 4;
        }
        arr->data[arr->num++] = so;
    }
    // 2. the knight's trail notifies (in his own animation sets only: the bosses' trails stay on their sockets)
    int oAS = poff(CLS(mesh), "AnimSets");
    struct { uint8_t **data; int num, max; } *sets = oAS >= 0 ? (void *)(mesh + oAS) : NULL;
    void *found[1024]; int n = ibfix_objects_of_class("AnimNotify_Trails", found, 1024), pointed = 0;
    for (int i = 0; i < n; i++) {
        uint8_t *nt = found[i], *seq = *(uint8_t **)(nt + 0x40), *set = seq ? *(uint8_t **)(seq + 0x40) : NULL;
        BOOL his = NO;
        for (int j = 0; sets && sets->data && j < sets->num && j < 64 && !his; j++) his = sets->data[j] == set;
        if (!his) continue;
        void *c = CLS(nt); int oF = poff(c, "FirstEdgeSocketName"), oC = poff(c, "ControlPointSocketName");
        if (oF < 0 || oC < 0) continue;
        int *f = (int *)(nt + oF), *cp = (int *)(nt + oC);
        if (f[0] == ownB && cp[0] == ownC) { pointed++; continue; }   // done already
        if (f[0] != bottom || cp[0] != control) continue;
        BOOL kept = NO;
        for (int j = 0; j < gNTrailKept && !kept; j++) kept = gTrailKept[j].n == nt;
        if (!kept && gNTrailKept < 256) { gTrailKept[gNTrailKept].n = nt; memcpy(gTrailKept[gNTrailKept].first, f, 8); memcpy(gTrailKept[gNTrailKept].control, cp, 8); gNTrailKept++; }
        f[0] = ownB; f[1] = 0; cp[0] = ownC; cp[1] = 0; pointed++;
    }
    LOG(@"blood mode: %d of the knight's swing trails on their own sockets (%.0f and %.0f units up the blade; %d trail notifies in all)", pointed, kTrailBottomZ, kTrailControlZ, n);
    gSockDone = skel;
}
#ifdef IBFIX_SNAPS
// Test builds: Tough Enemy (settings key ibfixCheatTough): each boss gets 10 times his health when his fight starts,
// so a fight lasts long enough to see the cut limit.
static void toughBossTick(void) {
    static int on = -1; if (on < 0) { on = [[NSUserDefaults standardUserDefaults] boolForKey:@"ibfixCheatTough"]; if (on) LOG(@"test cheats: Tough Enemy on (10 times the health)"); }
    if (!on) return;
    uint8_t *pawn = playerPawn(), *enemy = pawn ? objAt(pawn, "Enemy") : NULL;
    if (!enemy || !plausibleObj(enemy)) return;
    void *cls = CLS(enemy); if (poff(cls, "StageTransitionHealth") < 0) return;
    static uint8_t *done[8]; static int nd;
    for (int i = 0; i < 8; i++) if (done[i] == enemy) return;
    int oH = poff(cls, "Health"), oM = poff(cls, "HealthMax"); if (oH < 0) return;
    int h = *(int *)(enemy + oH); if (h <= 0) return;
    *(int *)(enemy + oH) = h * 10; if (oM >= 0) *(int *)(enemy + oM) *= 10;
    done[nd++ % 8] = enemy;
    LOG(@"test cheats: Tough Enemy: %@'s health %d -> %d", ibfix_objname(enemy), h, h * 10);
}
#endif
static BloodDrop gOut[kBloodMax];
static void bloodTick(void) {                                   // every frame, after the camera's update
    bloodLoadSetting();
    if (!gBloodOn) return;
    static float last; float now = worldTime(), dt = now - last; last = now;
    static BOOL told;
    if (!told) {
        told = YES;
        uint8_t *wi = WORLD_INFO();
        int o = wi ? poff(CLS(wi), "WorldGravityZ") : -1;
        if (o >= 0 && *(float *)(wi + o) < -1) gGravity = *(float *)(wi + o);
        LOG(@"blood: on (test build): gravity %.0f units/s/s", gGravity);
    }
    if (dt < 0 || dt > 0.25f) dt = 0;                           // a jump in time (a load): nothing moves
    bloodTrailSockets();
#ifdef IBFIX_SNAPS
    toughBossTick();
    woundSideTest(bossMesh());
#endif
    cutsTick(now);
    bladeUpdate(now);
    stabTick(now);
    woundsTick(now, dt);
    int n = 0;
    for (int i = 0; i < gNBP; i++) {
        BloodP *b = &gBP[i];
        b->age += dt;
        if (dt > 0) {
            float k = expf(-b->drag * dt);
            for (int j = 0; j < 3; j++) b->v[j] *= k;
            b->v[2] += gGravity * dt * (b->kind == 0 ? 1.0f : b->kind == 1 ? 0.15f : 0.1f);
            for (int j = 0; j < 3; j++) b->p[j] += b->v[j] * dt;
            if (b->kind) b->r *= 1 + (b->kind == 1 ? 1.2f : 1.1f) * dt;   // mist spreads
        }
        if (b->age > b->life || b->p[2] < gFloorZ) continue;
        gBP[n++] = *b;
    }
    gNBP = n;
    for (int i = 0; i < n; i++) {
        BloodP *b = &gBP[i]; BloodDrop *d = &gOut[i];
        memcpy(d->p, b->p, 12); memcpy(d->v, b->v, 12); d->r = b->r; d->kind = b->kind;
        float sp = vlen(b->v);
        d->stretch = b->kind ? 1 : fminf(1 + sp / 55, 7.0f);     // a fast drop is a thin streak
        float fade = b->kind == 1 ? 1 - b->age / b->life                                   // slash mist
                   : b->kind == 2 ? fminf(1, b->age * 12) * powf(fmaxf(0, 1 - b->age / b->life), 1.3f)   // fountain mist
                   : fminf(1, (b->life - b->age) * 4);
        d->a = b->a * fmaxf(0, fade);
    }
    ibfix_blood_publish(gOut, n, 0.75f);
#ifdef IBFIX_SNAPS
    CFAbsoluteTime rt = CFAbsoluteTimeGetCurrent();
    if (gBloodShots > 0 && rt - gBloodShotAt >= 0.15) {
        gBloodShotAt = rt; ibfix_snap([NSString stringWithFormat:@"bloodhit%02d-%d-%03d", gBloodStrikes, 3 - gBloodShots, n]); gBloodShots--;
    }
    static BOOL fountainShots; static int fShots; static CFAbsoluteTime fAt;
    if (gStab.out && gStab.kill && !fountainShots) { fountainShots = YES; fShots = 32; }
    if (fShots > 0 && rt - fAt >= 0.06) { fAt = rt; ibfix_snap([NSString stringWithFormat:@"bloodfountain-%02d-%03d", 32 - fShots, n]); fShots--; }
#endif
}
// from the script-call hook: the knight's strike and stab effects (their camera shakes, as 7d reads them)
static void bloodFXCall(void *self, void *stack, int name) {
    if (!gBloodOn || !self) return;
    NAME_ONCE(nameShake, "ClientPlayCameraShake");
    if (name != nameShake) return;
    uint8_t *fn = *(uint8_t **)((uint8_t *)stack + 0x18), *loc = *(uint8_t **)((uint8_t *)stack + 0x30), *pawn = *(uint8_t **)((uint8_t *)stack + 0x20);
    static void *playFX; static int oIdx = -1;
    if (fn && fn != playFX && [ibfix_objname(fn) isEqualToString:@"PlayFX"]) { playFX = fn; oIdx = propertyOffset(fn, "PawnFXIndex"); }
    if (fn != playFX || oIdx < 0 || !loc || !plausibleObj(pawn) || pawn != playerPawn()) return;
    void *cls = CLS(pawn);
    if (gFxSize == -2) fxLayout(cls);
    int oArr = poff(cls, "FXArray"), idx = *(int *)(loc + oIdx);
    struct { uint8_t *data; int num, max; } *arr = oArr >= 0 ? (void *)(pawn + oArr) : NULL;
    if (!arr || !arr->data || gFxSize <= 0 || idx < 0 || idx >= arr->num) return;
    NSString *tag = fstrText(arr->data + (size_t)idx * gFxSize + gFxTag);
    if ([tag hasPrefix:@"Attack_"]) bloodStrike(tag);
    else if ([tag isEqualToString:@"Stab"] || [tag isEqualToString:@"Stab_BIG"]) bloodStab(tag, enemyDead());
}
// the knight's effects (his FXArray, each a SwordEffect: Tag, ParticleFX, ParticleScale, sound ...) once
// FinishEquippingItems has set them (defaults, then each item's SetupItemFX by tag), in blood mode: each Attack_ streak at
// kBloodSlashScale (PlayFX scales by ParticleScale, 0 meaning 1), the Stab and Stab_BIG bursts gone (their sounds kept),
// the blade's glow (SwordGlow) kept; the game's own values kept, to put back when the switch goes off. A slash effect
// drawn as a glowing copy of the blade itself (a mesh part whose mesh is a saber: Hit_Slice_InfiniGlow and InfiniStab,
// Laser_Infinitysaber01) keeps its size, or the copy no longer fits the blade (every other slash effect's mesh part is
// the slash arc SwordStrike01 or ice, from the game's packages).
static const float kBloodSlashScale = 0.35f;
static BOOL bladeGlow(uint8_t *ps) {
    static NSMutableDictionary<NSValue *, NSNumber *> *seen; if (!seen) seen = [NSMutableDictionary dictionary];
    NSNumber *known = seen[[NSValue valueWithPointer:ps]]; if (known) return known.boolValue;
    BOOL glow = NO;
    int oE = poff(CLS(ps), "Emitters");
    struct { uint8_t **data; int num, max; } *em = oE >= 0 ? (void *)(ps + oE) : NULL;
    for (int i = 0; em && em->data && i < em->num && i < 32 && !glow; i++) {
        uint8_t *e = em->data[i]; if (!plausibleObj(e)) continue;
        int oL = poff(CLS(e), "LODLevels");
        struct { uint8_t **data; int num, max; } *lod = oL >= 0 ? (void *)(e + oL) : NULL;
        uint8_t *l0 = lod && lod->data && lod->num > 0 ? lod->data[0] : NULL; if (!plausibleObj(l0)) continue;
        uint8_t *td = objAt(l0, "TypeDataModule"), *m = td ? objAt(td, "Mesh") : NULL;
        if (m && [ibfix_objname(m) rangeOfString:@"saber" options:NSCaseInsensitiveSearch].length) glow = YES;
    }
    seen[[NSValue valueWithPointer:ps]] = @(glow);
    return glow;
}
static struct { uint8_t *pawn; int n; struct { int i; float scale; void *ps; } e[64]; } gFXKept;
static BOOL fxRecords(uint8_t *pawn, uint8_t **data, int *num, int *oPS, int *oSc) {
    void *cls = CLS(pawn); int oArr = poff(cls, "FXArray");
    uint8_t *st = findStruct(cls, "SwordEffect"); *oPS = st ? propertyOffset(st, "ParticleFX") : -1; *oSc = st ? propertyOffset(st, "ParticleScale") : -1;
    if (gFxSize == -2) fxLayout(cls);
    struct { uint8_t *data; int num, max; } *arr = oArr >= 0 ? (void *)(pawn + oArr) : NULL;
    if (!arr || !arr->data || gFxSize <= 0 || *oPS < 0 || *oSc < 0) return NO;
    *data = arr->data; *num = arr->num; return YES;
}
static void bloodFXApply(uint8_t *pawn) {
    uint8_t *data; int num, oPS, oSc;
    if (!pawn || !fxRecords(pawn, &data, &num, &oPS, &oSc)) { LOG(@"blood mode: the knight's effects can't be read: left as they are"); return; }
    if (gFXKept.pawn == pawn && gFXKept.n) return;              // done already for this knight
    gFXKept.pawn = pawn; gFXKept.n = 0;
    int slashes = 0, stabs = 0; NSMutableString *names = [NSMutableString string];
    for (int i = 0; i < num && gFXKept.n < 64; i++) {
        uint8_t *r = data + (size_t)i * gFxSize; NSString *tag = fstrText(r + gFxTag);
        void **ps = (void **)(r + oPS); float *sc = (float *)(r + oSc);
        BOOL slash = [tag hasPrefix:@"Attack_"] && *ps, stab = ([tag isEqualToString:@"Stab"] || [tag isEqualToString:@"Stab_BIG"]) && *ps;
        if (!slash && !stab) continue;
        gFXKept.e[gFXKept.n].i = i; gFXKept.e[gFXKept.n].scale = *sc; gFXKept.e[gFXKept.n].ps = *ps; gFXKept.n++;
        if (slash && bladeGlow(*ps)) { gFXKept.n--; NSString *n = [ibfix_objname(*ps) stringByAppendingString:@" (the blade's own glow: its size kept)"]; if (![names containsString:n]) [names appendFormat:@" %@", n]; continue; }
        if (slash) { *sc = (*sc > 0 ? *sc : 1) * kBloodSlashScale; slashes++; NSString *n = ibfix_objname(*ps); if (![names containsString:n]) [names appendFormat:@" %@", n]; }
        else { *ps = NULL; stabs++; }
    }
    LOG(@"blood mode: %d slash streaks at %.0f%% of their size (%@ ), %d stab bursts left out", slashes, 100 * kBloodSlashScale, names, stabs);
}
static void bloodFXRestore(void) {
    uint8_t *data; int num, oPS, oSc;
    if (!gFXKept.pawn || !isLiveObject(gFXKept.pawn) || !fxRecords(gFXKept.pawn, &data, &num, &oPS, &oSc)) { gFXKept.pawn = NULL; gFXKept.n = 0; return; }
    for (int k = 0; k < gFXKept.n; k++) {
        if (gFXKept.e[k].i >= num) continue;
        uint8_t *r = data + (size_t)gFXKept.e[k].i * gFxSize; *(float *)(r + oSc) = gFXKept.e[k].scale; *(void **)(r + oPS) = gFXKept.e[k].ps;
    }
    LOG(@"blood mode off: the knight's %d effects put back as the game had them", gFXKept.n);
    gFXKept.pawn = NULL; gFXKept.n = 0;
}
static void bloodItemFX(void *self, void *stack, void *result) {
    ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);  // FinishEquippingItems: defaults, then each item's own (SetupItemFX)
    gFXKept.pawn = NULL; gFXKept.n = 0;                         // a fresh set: the game's own values again
    bloodFXApply(self);
}
// Options' Blood switch: the devs' unused debug check box handler OnUpdateFastForward (it set
// CommonSaveFile.bDebugAlwaysFastForward; our own code runs instead, so that is never touched). Off: no blood, no cuts,
// the weapon's effects and trails as the game made them. It takes effect at once.
static void bloodApply(uint8_t *pc, BOOL on) {
    if (on) { bloodFXApply(playerPawn()); gSockDone = NULL; }
    else {
        bloodFXRestore(); bloodTrailRestore(); gNBP = 0; gNWounds = 0; gStab.mesh.obj = NULL;
        for (int i = 0; i < gNWM; i++) cutsClear(gWM[i].skin);
        ibfix_blood_publish(NULL, 0, 0.75f);
    }
}
static void my_onBlood(void *self, void *stack, void *result) { optionSwitch(self, stack, gBloodFn, &gBloodOn, kBloodKey, "Blood", bloodApply); }
static BOOL bloodCall(void *self, void *stack, void *result, int name) {
    bloodLoadSetting();
    NAME_ONCE(nameFinishEquip, "FinishEquippingItems");
    if (gBloodOn && name == nameFinishEquip && self && isClass(self, "SwordPlayer")) { bloodItemFX(self, stack, result); return YES; }
    bloodFXCall(self, stack, name);
    return NO;
}
#endif
#ifdef IBFIX_SNAPS
// ---- 5d (continued). Test builds: the preview's capture, a skipped scene with its own sound (FIXES.md 82) ----
// Documents/ibfix-fftest.txt, "<the Mac's time> <now|soft> [<hold from> <hold for> <until> [well]]" (seconds after the
// tap; 2.5, 3 and 14 if not given; hold for 0: no hold; "well": Back to Gate first, then the well's tap instead of the
// door enemy's circle; one-shot, 15 minutes). Once resumed at the door's save point (SCM_10) for 4 s, OpenAL's output
// recorder (Apple's ALC_EXT_OUTPUT_CAPTURER) records 44.1 kHz stereo to Documents/ibfix-capture/ff-<run>.raw, drained
// every 20 ms (it keeps only about 0.1 s); 1 s later the circle is taken as its tap would (OnChoiceMade, then
// SeqEvent_MobileTouch_36's links: LoadBossBattle_12 "Start" and Interp_91's input 2), the robot holds skip as the file
// says, and pictures are taken 6 a second (ff-<run>-<n>-<seconds>). "now": other sounds as the devs made them
// (gFFSoftOff); "soft": the fix. Music isn't OpenAL's (AVAudioPlayer): the log's music lines give it to the Mac's mix.
#import <OpenAL/alc.h>
__attribute__((weak)) void ibfix_robot_hold(float x, float y, double seconds) { LOG(@"robot: a hold asked, robot.m not built in"); }
static const float kSkipX = 0.887f, kSkipY = 0.952f;            // the skip button, as fractions of the screen (robot/ff-test.txt)
static int gFFTest; static char gFFRun[8]; static float gFFHoldAt = 2.5f, gFFHoldFor = 3.0f, gFFUntil = 14.0f;
static BOOL gFFWell;                                            // "well": Back to Gate first, then the well's tap is the start
static volatile BOOL gCapOn; static double gCapStart;
static void ffTestRead(void) {
    NSString *path = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-fftest.txt"];
    NSArray *f = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (f.count < 2) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    double age = [NSDate date].timeIntervalSince1970 - [f[0] doubleValue];
    if (age < 0 || age > 15 * 60) { LOG(@"ff test: file %.0f s old: ignored", age); return; }
    gFFSoftOff = [f[1] isEqualToString:@"now"]; strlcpy(gFFRun, gFFSoftOff ? "now" : "soft", sizeof gFFRun); gFFTest = 1;
    if (f.count >= 5 && [f[4] length]) { gFFHoldAt = [f[2] floatValue]; gFFHoldFor = [f[3] floatValue]; gFFUntil = [f[4] floatValue]; }
    gFFWell = f.count >= 6 && [f[5] isEqualToString:@"well"];
    NSString *snaps = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-snaps"];
    for (NSString *x in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:snaps error:nil])      // this run's pictures only
        if ([x hasPrefix:[NSString stringWithFormat:@"ff-%s-", gFFRun]]) [[NSFileManager defaultManager] removeItemAtPath:[snaps stringByAppendingPathComponent:x] error:nil];
    LOG(@"ff test: on, run %s (%@), skip held from %.1f s for %.1f s, until %.0f s", gFFRun, gFFSoftOff ? @"other sounds as the devs made them" : @"other sounds softer while skip is held",
        gFFHoldAt, gFFHoldFor, gFFUntil);
}
static void capStart(void) {
    typedef void (*Prep)(ALCuint, ALCenum, ALCsizei); typedef void (*Fn)(void); typedef ALint (*Avail)(void); typedef void (*Samples)(void *, ALCsizei);
    Prep prep = (Prep)alcGetProcAddress(NULL, "alcOutputCapturerPrepare");
    Fn start = (Fn)alcGetProcAddress(NULL, "alcOutputCapturerStart"), stop = (Fn)alcGetProcAddress(NULL, "alcOutputCapturerStop");
    Avail avail = (Avail)alcGetProcAddress(NULL, "alcOutputCapturerAvailableSamples");
    Samples samples = (Samples)alcGetProcAddress(NULL, "alcOutputCapturerSamples");
    if (!prep || !start || !stop || !avail || !samples || !alcGetCurrentContext()) { LOG(@"ff test: OpenAL's output recorder isn't available"); return; }
    NSString *dir = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-capture"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"ff-%s.raw", gFFRun]];
    FILE *f = fopen(path.fileSystemRepresentation, "wb");
    if (!f) { LOG(@"ff test: can't write %@", path.lastPathComponent); return; }
    prep(44100, AL_FORMAT_STEREO16, 44100); start(); gCapStart = CFAbsoluteTimeGetCurrent(); gCapOn = YES;
    LOG(@"ff test: recording the game's sound (44.1 kHz stereo) to %@", path.lastPathComponent);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        static int16_t buf[44100 * 2]; long total = 0; int most = 0;
        while (gCapOn) {
            usleep(20000);
            ALint k = avail();
            if (k > most) most = k;
            if (k <= 0) continue;
            if (k > 44100) k = 44100;
            samples(buf, k); fwrite(buf, 4, k, f); total += k;
        }
        stop(); fclose(f);
        LOG(@"ff test: sound recorded, %.2f s in %.2f s (at most %d samples waiting at once)", total / 44100.0, CFAbsoluteTimeGetCurrent() - gCapStart, most);
    });
}
static void ffTestTick(void) {
    if (!gFFTest) return;
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    static CFAbsoluteTime since, t0, shot; static int shots, onFrames; static BOOL held, holdAsked;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    uint8_t *node = objAt(pc, "ChoiceNode"); NSString *n = node && isLiveObject(node) ? ibfix_objname(node) : @"";
    BOOL gate = [n isEqualToString:@"SeqAct_StartChoiceMode_23"] || [n isEqualToString:@"SeqAct_StartChoiceMode_25"];
    if (gFFTest == 1) {                                         // at the door for 4 s, the game resumed: the sound recorder starts
        // The save point is set already under the start-up film and title; its Back to Gate circle only once resumed.
        if (![n isEqualToString:@"SeqAct_StartChoiceMode_10"] || !gGateOn) { since = 0; return; }
        if (!since) { since = t; return; }
        if (t - since < 4) return;
        if (gFFWell) {                                          // (well) Back to Gate first, as its tap (4y's capture)
            gateTapped();
            BOOL a = fireInput("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_54", 0), b = fireInput("SeqAct_Interp", "SeqAct_Interp_87", 0);
            LOG(@"ff test: Back to Gate (%@)", a && b ? @"started" : @"NOT started");
            gFFTest = 4; since = 0; return;
        }
        capStart(); gFFTest = 2; since = t; return;
    }
    if (gFFTest == 4) {                                         // (well) at the gate for 4 s: the sound recorder starts
        if (!gate) { since = 0; return; }
        if (!since) { since = t; return; }
        if (t - since < 4) return;
        capStart(); gFFTest = 2; since = t; return;
    }
    if (gFFTest == 2) {                                         // 1 s later: the door enemy's circle, or the well's, as its tap
        if (t - since < 1) return;
        callNoArgs(node, "OnChoiceMade");
        BOOL a, b;
        if (gFFWell) { a = fireInput("SeqAct_StartCinematicMode", "SeqAct_StartCinematicMode_57", 0); b = fireInput("SeqAct_Interp", "SeqAct_Interp_90", 2); }
        else { a = fireInput("SeqAct_LoadBossBattle", "SeqAct_LoadBossBattle_12", 1); b = fireInput("SeqAct_Interp", "SeqAct_Interp_91", 2); }
        t0 = t; shot = 0; shots = 0; onFrames = 0; held = NO; holdAsked = NO;
        LOG(@"ff test: %@ taken (%@), %.3f s into the sound recording", gFFWell ? @"the well's circle" : @"the door enemy's circle", a && b ? @"started" : @"NOT started", t0 - gCapStart);
        gFFTest = 3; return;
    }
    double s = t - t0;
    if (!holdAsked && s >= gFFHoldAt) { holdAsked = YES; if (gFFHoldFor > 0) ibfix_robot_hold(kSkipX, kSkipY, gFFHoldFor); }
    BOOL on = skipOn();
    if (on) onFrames++;
    if (on != held) { held = on; LOG(@"ff test: skip %@ at %.2f s after the tap (%d frames with it on so far)", on ? @"on" : @"off", s, onFrames); }
    if (t - shot >= 1.0 / 6) { shot = t; ibfix_snap([NSString stringWithFormat:@"ff-%s-%03d-%05.2f", gFFRun, shots++, s]); }
    if (s > gFFUntil) { gCapOn = NO; LOG(@"ff test: done, run %s, %d pictures, %d frames with skip on", gFFRun, shots, onFrames); gFFTest = 0; }
}
// ---- 9b (test builds). The knight's turn after Start, photographed (FIXES.md 86) ----
// Documents/ibfix-starttest.txt, "<the Mac's time> <before|after>" (one-shot, 15 minutes): with a save at the title's
// save point (SCM_5), once "INTRO after title screen" (SeqAct_Interp_57) starts after Start, the knight's yaw is logged
// beside each film's and pictures are taken 10 times a second for its first 3.5 s (start-<run>-<n>-<film seconds>).
// "before" leaves his facing to the engine (gFacingFixOff), "after" is the fix.
static int gStartTest; static char gStartRun[8];
static void startTestRead(void) {
    NSString *docs = DOCUMENTS;
    NSString *path = [docs stringByAppendingPathComponent:@"ibfix-starttest.txt"];
    NSArray *f = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (f.count < 2) return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    double age = [NSDate date].timeIntervalSince1970 - [f[0] doubleValue];
    if (age < 0 || age > 15 * 60) { LOG(@"start test: file %.0f s old: ignored", age); return; }
    gFacingFixOff = [f[1] isEqualToString:@"before"]; strlcpy(gStartRun, gFacingFixOff ? "before" : "after", sizeof gStartRun); gStartTest = 1;
    NSString *snaps = [docs stringByAppendingPathComponent:@"ibfix-snaps"];
    for (NSString *x in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:snaps error:nil])
        if ([x hasPrefix:[NSString stringWithFormat:@"start-%s-", gStartRun]]) [[NSFileManager defaultManager] removeItemAtPath:[snaps stringByAppendingPathComponent:x] error:nil];
    LOG(@"start test: on, run %s (%@)", gStartRun, gFacingFixOff ? @"his facing left to the engine" : @"the facing fix on");
}
static void startTestTick(void) {
    if (!gStartTest) return;
    static ObjRef intro; static CFAbsoluteTime shot, first; static int shots;
    if (!refLive(&intro)) { intro = namedObjectIn("SeqAct_Interp", "SeqAct_Interp_57", @"Birthright_P"); if (!refLive(&intro)) return; }
    int oPos = poff(intro.cls, "Position");
    float pos = oPos >= 0 ? *(float *)(intro.obj + oPos) : 0;
    if (pos <= 0) return;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (!first) { first = t; LOG(@"start test: INTRO after title screen started"); }
    if (t - first > 3.5) { LOG(@"start test: done, run %s, %d pictures", gStartRun, shots); gStartTest = 0; return; }
    if (t - shot < 0.1) return;
    shot = t;
    ibfix_snap([NSString stringWithFormat:@"start-%s-%03d-%05.2f", gStartRun, shots++, pos]);
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL, *pawn = pc ? objAt(pc, "PlayerPawn") : NULL;
    int oR = pawn ? poff(CLS(pawn), "Rotation") : -1;
    if (oR >= 0) LOG(@"start test: film at %.2f s, the knight's yaw %.0f", pos, (*(int *)(pawn + oR + 4) & 65535) * 360.0f / 65536);
}
#endif
// ---- 4v. The devs' COPY button on Character Slots (26 October 2026; FIXES.md 72) ----
// The devs finished "copy a character to another slot" (SwordSaveGameScene.DoCopySaveGame, CopyBttnString and the
// pop-up's text), but the screen has only START and DELETE. Before its own InitMenuScene (so the game lays out every
// object itself), START and DELETE are moved and a third button is made from DELETE as the game's own script copies
// buttons (SwordInventoryScene's "new (self) Class'SwordInventoryBttnLevel' (Copy)"): the script command new (0x11) run
// through the command table, this screen the owner, DELETE the template. Usable when START is, never in "FIXED" saves
// mode. A tap (OnTouchMenuObject, sent through ProcessEvent, wrapped in the vtable of SwordMenuAnimScene, the native class
// of these screens, not the engine's MobileMenuScene) opens the game's own Yes/No pop-up, and DoCopySaveGame on Yes.
#define IB1_MENUSCENE_VTABLE   0x100b8b4e0ULL   // USwordMenuAnimScene, the native class of every Sword menu screen
#define IB1_OBJECT_PROCESSEVENT 0x10009e15cULL
#define EX_NEW 0x11
#define EX_OBJECTCONST 0x20
#define EX_NOTHING 0x0B
#define EX_SELF 0x17
static void (*gOrigScenePE)(void *, void *, void *, void *);
static ObjRef gCopyScene, gCopyBttn;
static void *classObject(const char *name) {                    // a script class by name
    int nm = nameIndex(name); if (nm < 0) return NULL;
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    for (int i = 0; i < objs->num; i++) {
        uint8_t *o = objs->data[i];
        if (o && *(int *)(o + 0x48) == nm && *(int *)(o + 0x4c) == 0 && [ibfix_objname(CLS(o)) isEqualToString:@"Class"]) return o;
    }
    return NULL;
}
// The script command new as the compiler writes it: 0x11, then outer, name, flags, class and template, each an
// expression (EX_Nothing when left out). Checked once against the game's own compiled "new (self) Class'...' (Copy)" in
// SwordInventoryScene.CreateUpgradeBttnX10 (its Script bytes are found by their content near the function's start).
static BOOL newLayoutChecked(void) {
    static int ok = -1;
    if (ok >= 0) return ok;
    ok = 0;
    void *cls = classObject("SwordInventoryScene");
    uint8_t *fn = NULL;
    for (uint8_t *f = cls ? *(uint8_t **)((uint8_t *)cls + 0x70) : NULL; f; f = *(uint8_t **)(f + 0x60))
        if ([ibfix_objname(f) isEqualToString:@"CreateUpgradeBttnX10"]) { fn = f; break; }
    for (int off = 0x70; fn && off <= 0xd0 && !ok; off += 8) {
        struct { uint8_t *data; int num, max; } *a = (void *)(fn + off);
        if (!a->data || a->num < 16 || a->num > 4096 || a->max < a->num || ((uintptr_t)a->data & 3)) continue;
        for (int i = 0; i + 13 < a->num; i++)
            if (a->data[i] == EX_NEW && a->data[i + 1] == EX_SELF && a->data[i + 2] == EX_NOTHING && a->data[i + 3] == EX_NOTHING && a->data[i + 4] == EX_OBJECTCONST) { ok = 1; break; }
    }
    LOG(@"copy button: the script command new %@ (checked in the game's own CreateUpgradeBttnX10)", ok ? @"is as expected" : @"NOT as expected: no button");
#ifdef IBFIX_SNAPS
    LOG(@"copy button: command table entry 0x11 at 0x%lx", (unsigned long)((uintptr_t)gNatives[EX_NEW].fn - _dyld_get_image_vmaddr_slide(0)));
#endif
    return ok;
}
static void *newFromTemplate(void *cls, void *outer, void *tmpl) {
    if (!cls || !outer || !tmpl || !gNatives || !newLayoutChecked()) return NULL;
    uint8_t code[48] = {0}; int k = 0;
    code[k++] = EX_NEW;
    code[k++] = EX_OBJECTCONST; memcpy(code + k, &outer, 8); k += 8;
    code[k++] = EX_NOTHING; code[k++] = EX_NOTHING;
    code[k++] = EX_OBJECTCONST; memcpy(code + k, &cls, 8); k += 8;
    code[k++] = EX_OBJECTCONST; memcpy(code + k, &tmpl, 8); k += 8;
    code[k++] = 0x16;                                                    // EX_EndFunctionParms, should anything look
    uint8_t frame[0x48] = {0};
    void *node = findFunction(outer, "InitMenuScene"); if (!node) node = findFunction(outer, "IsA");
    *(void **)(frame + 0x18) = node;                                     // Node: a real function of the owner
    *(void **)(frame + 0x20) = outer;
    *(uint8_t **)(frame + FFRAME_CODE) = code;
    void *made = NULL;
    stepExpr(frame, &made);
    return made && isLiveObject(made) && CLS(made) == cls ? made : NULL;
}
// A menu object by its Tag, as the game's own FindMenuObject finds them (the objects' own names are not their tags)
static uint8_t *menuObjectNamed(uint8_t *scene, NSString *tag, int *index) {
    int oM = poff(CLS(scene), "MenuObjects");
    if (oM < 0) return NULL;
    struct { uint8_t **data; int num, max; } *mo = (void *)(scene + oM);
    for (int i = 0; i < mo->num && i < 128; i++) {
        uint8_t *o = mo->data[i]; int oT = o ? poff(CLS(o), "Tag") : -1;
        if (oT >= 0 && [wstr(o, oT, oT + 8) isEqualToString:tag]) { if (index) *index = i; return o; }
    }
    return NULL;
}
static void setFloat(uint8_t *o, const char *prop, float v) { int off = poff(CLS(o), prop); if (off >= 0) *(float *)(o + off) = v; }
static void copyPreInit(uint8_t *scene) {                              // before the screen lays itself out
    int iDel = -1;
    uint8_t *start = menuObjectNamed(scene, @"StartBttn", NULL), *del = menuObjectNamed(scene, @"DeleteBttn", &iDel);
    void *cls = classObject("SwordScaleButton");
    if (!start || !del || !cls) { LOG(@"copy button: START or DELETE not found: no button"); return; }
    uint8_t *copy = newFromTemplate(cls, scene, del);
    if (!copy) { LOG(@"copy button: not made"); return; }
    setFloat(start, "Left", 112); setFloat(start, "Width", 220);
    setFloat(del, "Left", 628); setFloat(del, "Width", 220);
    setFloat(copy, "Left", 370); setFloat(copy, "Width", 220);
    int oTag = poff(CLS(copy), "Tag");
    if (oTag >= 0) { FStr t = makeFString("CopyBttn"); memcpy(copy + oTag, &t, sizeof t); }  // its own tag (the copy shared DELETE's)
    int oM = poff(CLS(scene), "MenuObjects");
    struct { uint8_t **data; int num, max; } *mo = (void *)(scene + oM);
    if (mo->num >= mo->max) {
        void *(*appRealloc)(void *, uint32_t, uint32_t) = (void *(*)(void *, uint32_t, uint32_t))(IB1_APPREALLOC + _dyld_get_image_vmaddr_slide(0));
        uint8_t **d = appRealloc(mo->data, (uint32_t)((mo->max + 4) * sizeof(void *)), 8);
        if (!d) { LOG(@"copy button: no room in the screen's list"); return; }
        mo->data = d; mo->max += 4;
    }
    memmove(&mo->data[iDel + 2], &mo->data[iDel + 1], (size_t)(mo->num - iDel - 1) * sizeof(void *));   // just after DELETE
    mo->data[iDel + 1] = copy; mo->num++;
    gCopyScene = (ObjRef){ scene, *(int *)(scene + 0x38), CLS(scene) };
    gCopyBttn = (ObjRef){ copy, *(int *)(copy + 0x38), CLS(copy) };
    LOG(@"copy button: made (%@), START and DELETE moved: START 112, COPY 370, DELETE 628, each 220 wide", ibfix_objname(copy));
}
static void copyPostInit(uint8_t *scene) {                             // after it: the devs' caption
    if (scene != gCopyScene.obj || !refLive(&gCopyBttn)) return;
    void *sc = CLS(scene); int oS = poff(sc, "CopyBttnString"), oC = poff(CLS(gCopyBttn.obj), "Caption");
    NSString *cap = oS >= 0 ? wstr(scene, oS, oS + 8) : nil;
    if (oC >= 0) { FStr c = makeFString(cap.length ? cap.UTF8String : "COPY"); memcpy((uint8_t *)gCopyBttn.obj + oC, &c, sizeof c); }
    LOG(@"copy button: caption \"%@\"", cap.length ? cap : @"COPY");
    // where the game laid the three out, in screen pixels (Left, Top, Width, Height after InitMenuObject)
    NSMutableString *at = [NSMutableString string];
    for (NSString *tag in @[@"StartBttn", @"CopyBttn", @"DeleteBttn"]) {
        uint8_t *o = menuObjectNamed(scene, tag, NULL); void *oc = o ? CLS(o) : NULL;
        if (!o) { [at appendFormat:@" %@ missing;", tag]; continue; }
        [at appendFormat:@" %@ %.0f,%.0f %.0fx%.0f;", tag, *(float *)(o + poff(oc, "Left")), *(float *)(o + poff(oc, "Top")),
            *(float *)(o + poff(oc, "Width")), *(float *)(o + poff(oc, "Height"))];
    }
    LOG(@"copy button: laid out:%@", at);
}
static void copyRender(uint8_t *scene) {                               // usable when START is (not the current game)
    if (scene != gCopyScene.obj || !refLive(&gCopyBttn)) return;
    BOOL fixed = NO, startOn = NO; boolGet(scene, "bFixedSaves", &fixed);
    uint8_t *start = objAt(scene, "StartBttn");
    if (start) boolGet(start, "bIsActive", &startOn);
    boolSet(gCopyBttn.obj, "bIsActive", startOn && !fixed);
}
static void copyAsk(uint8_t *scene) {                                  // the devs' Yes/No, as DELETE's
    void *sc = CLS(scene);
    int oT = poff(sc, "CopySaveSlotTitle"), oQ = poff(sc, "ConfirmCopyString");
    NSString *title = oT >= 0 ? wstr(scene, oT, oT + 8) : nil, *ask = oQ >= 0 ? wstr(scene, oQ, oQ + 8) : nil;
    uint8_t *list = objAt(scene, "OptionList"), *pc = objAt(scene, "SwordPC");
    uint8_t *getSel = list ? findFunction(list, "GetSelected") : NULL;
    int oR = getSel ? propertyOffset(getSel, "ReturnValue") : -1;
    if (!title.length || !ask.length || !pc || oR < 0) { LOG(@"copy button: its text, the list or the controller not found"); return; }
    uint8_t parms[64] = {0}; processEvent(list, getSel, parms);
    uint8_t *selected = *(uint8_t **)(parms + oR);
    int oSlot = selected ? poff(CLS(selected), "SlotIndex") : -1;
    if (oSlot < 0) { LOG(@"copy button: no slot chosen"); return; }
    int slot = *(int *)(selected + oSlot);
    NSString *msg = [ask stringByReplacingOccurrencesOfString:@"%Slot%" withString:[NSString stringWithFormat:@"%d", slot + 1]];
    uint8_t *open = findFunction(pc, "OpenPopupScreen"); void *yesNo = classObject("SwordYesNoPopup");
    int oPC = open ? propertyOffset(open, "PopupClass") : -1, oPR = open ? propertyOffset(open, "ReturnValue") : -1;
    if (oPC < 0 || oPR < 0 || !yesNo || *(uint16_t *)(open + 0xe2) > 96) { LOG(@"copy button: OpenPopupScreen not found"); return; }
    uint8_t p2[96] = {0}; *(void **)(p2 + oPC) = yesNo; processEvent(pc, open, p2);
    uint8_t *popup = *(uint8_t **)(p2 + oPR);
    uint8_t *init = popup ? findFunction(popup, "Init") : NULL;
    int oTi = init ? propertyOffset(init, "Title") : -1, oTx = init ? propertyOffset(init, "Text") : -1, oD = init ? propertyOffset(init, "ClickDelegate") : -1;
    if (oTi < 0 || oTx < 0 || oD < 0 || *(uint16_t *)(init + 0xe2) > 128) { LOG(@"copy button: the pop-up's Init not found"); return; }
    uint8_t p3[128] = {0};
    FStr ft = makeFString(title.UTF8String), fm = makeFString(msg.UTF8String);
    memcpy(p3 + oTi, &ft, sizeof ft); memcpy(p3 + oTx, &fm, sizeof fm);
    *(void **)(p3 + oD) = scene; *(int *)(p3 + oD + 8) = nameIndex("DoCopySaveGame"); *(int *)(p3 + oD + 12) = 0;   // the delegate: object, function name
    processEvent(popup, init, p3);
    LOG(@"copy button: asked to copy the current game into slot %d", slot + 1);
}
static void *gAchBttn;                                          // 4af: the pause menu's ACHIEVEMENTS button (compared)
static void achOpenMenu(uint8_t *pause);
static void my_scenePE(void *obj, void *fn, void *parms, void *res) {
    NAME_ONCE(nTouch, "OnTouchMenuObject");
    BOOL ask = NO;
    if (fn && obj == gCopyScene.obj && refLive(&gCopyBttn) && *(int *)((uint8_t *)fn + 0x48) == nTouch) {
        int oS = propertyOffset(fn, "Sender"), oE = propertyOffset(fn, "EventType");
        BOOL touched = NO, active = NO;
        if (oS >= 0 && oE >= 0 && *(void **)((uint8_t *)parms + oS) == gCopyBttn.obj && *((uint8_t *)parms + oE) == 3 &&
            boolGet(gCopyBttn.obj, "bIsTouched", &touched) && touched && boolGet(gCopyBttn.obj, "bIsActive", &active) && active) ask = YES;
    }
    BOOL achOpen = NO;                                          // 4af: the pause menu's ACHIEVEMENTS tapped
    if (fn && gAchBttn && *(int *)((uint8_t *)fn + 0x48) == nTouch && isClass(obj, "SwordPauseMenuScene")) {
        int oS = propertyOffset(fn, "Sender"), oE = propertyOffset(fn, "EventType");
        BOOL touched = NO;
        if (oS >= 0 && oE >= 0 && *(void **)((uint8_t *)parms + oS) == gAchBttn && *((uint8_t *)parms + oE) == 3 &&
            boolGet(gAchBttn, "bIsTouched", &touched) && touched) achOpen = YES;
    }
#ifdef IBFIX_SNAPS
    if (fn && *(int *)((uint8_t *)fn + 0x48) == nTouch) {       // 3i (test builds): where the corner button takes taps
        int oS = propertyOffset(fn, "Sender"), oE = propertyOffset(fn, "EventType"), oX = propertyOffset(fn, "TouchX"), oY = propertyOffset(fn, "TouchY");
        void *sender = oS >= 0 ? *(void **)((uint8_t *)parms + oS) : NULL;
        if (sender && oE >= 0 && *((uint8_t *)parms + oE) == 3 && isClass(sender, "SwordBackBttn"))
            LOG(@"menu shapes: the corner button tapped at %.0f,%.0f (region px; the region ends at %.0f, the screen's edge is %.0f beyond it)",
                oX >= 0 ? *(float *)((uint8_t *)parms + oX) : -1, oY >= 0 ? *(float *)((uint8_t *)parms + oY) : -1,
                gViewportWidth * 2250 / 2622, (gViewportWidth - gViewportWidth * 2250 / 2622) / 2);
    }
#endif
    gOrigScenePE(obj, fn, parms, res);
    if (ask) copyAsk(obj);
    if (achOpen) achOpenMenu(obj);
}
static void hookCopyButton(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **pe = (void **)(IB1_MENUSCENE_VTABLE + slide + VT_PROCESSEVENT);
    if (*pe != (void *)(IB1_OBJECT_PROCESSEVENT + slide)) { LOG(@"copy button OFF: the menu screens' vtable is not as expected"); return; }
    gOrigScenePE = (void (*)(void *, void *, void *, void *))*pe; *pe = (void *)my_scenePE;
    LOG(@"copy button ON");
}
static void hookCircleTaps(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **a = (void **)(IB1_PLAYERINPUT_VTABLE + slide + VT_PROCESSWORLDTOUCH);
    void **b = (void **)(IB1_SWORDPLAYERINPUT_VTABLE + slide + VT_PROCESSWORLDTOUCH);
    void *orig = (void *)(IB1_PROCESSWORLDTOUCH + slide);
    if (*a != orig || *b != orig) { LOG(@"circle taps OFF: the input classes' vtables are not as expected"); return; }
    gOrigWorldTouch = (WorldTouchFn)orig; *a = (void *)my_processWorldTouch; *b = (void *)my_processWorldTouch;
    LOG(@"circle taps ON: every circle taps where it is drawn");
}
static void hookGodKingCircle(void) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    void **pe = (void **)(IB1_TOUCHACTOR_PE_SLOT + slide);
    if (*pe != (void *)(IB1_ACTOR_PROCESSEVENT + slide)) { LOG(@"God King circle OFF: the circles' vtable is not as expected"); return; }
    gOrigTouchActorPE = (void (*)(void *, void *, void *, void *))*pe; *pe = (void *)my_touchActorPE;
    LOG(@"God King circle ON");
}

// ---- 4p. The lessons the devs finished but never showed (FIXES.md 65; 25 October 2026) ----
// Finished pages in SwordTutorial.ini no code opens (study/unused-content.md), shown with the game's own ShowTutorial and
// HideTutorial, only when the devs' lessons would be (SwordPC.ShouldDoTutorials), and never over another lesson:
//   Mega Hit, Ultra Hit  after the devs' combo lesson, whose end (SwordBoss.AlertForHit -> ClearComboTutorial) is
//                        stepped over twice: MEGA HIT until a 4-swipe combo lands, then ULTRA HIT until a 5-swipe one
//                        (SwordPlayer.ComboCounter's length at OnDoCombo), then the game's own call runs; also after 40 s.
//   Stab                 the first weak spots (SwordBoss.bWeakPointActive); closed a second after the last goes, or 10 s.
//   Info2                when "!" ends the devs' Info lesson (ToggleBossPopup -> FinishInfoTutorial), until it closes.
//   Menu                 at a save point once gold first reaches 400; closed by a circle's tap or the pause menu closing.
// Stab and Menu come once per character: NSUserDefaults keeps the slot and its fight count when each was shown, so a new
// character in that slot (fewer fights) sees them again. Test app: the Options switch "New Lessons On This Character"
// runs all five once on any character, at the real moments.
static NSString *const kLessonsShown = @"ibfixLessonsShown";
#ifdef IBFIX_SNAPS
static BOOL gLessonTest, gTestCombo, gTestInfo, gTestSeenStab, gTestSeenMenu;
#endif
static void *lessonPC(void) { uint8_t *hud = ffHud(); return hud ? objAt(hud, "PlayerOwner") : NULL; }
static BOOL lessonsOn(uint8_t *pc) {                            // the devs' own check, SwordPC.ShouldDoTutorials
#ifdef IBFIX_SNAPS
    if (gLessonTest) return YES;
#endif
    uint8_t *fn = findFunction(pc, "ShouldDoTutorials");
    int oRet = fn ? propertyOffset(fn, "ReturnValue") : -1;
    if (!fn || oRet < 0 || *(uint16_t *)(fn + 0xe2) > 16) return NO;
    uint8_t parms[16] = {0};
    processEvent(pc, fn, parms);
    return parms[oRet] != 0;
}
static ObjRef gLessonScene;                                     // the page this section opened, while it is up
static NSString *gLessonTag;
static BOOL popupUp(uint8_t *pc, void *scene, const char *cls) {   // that scene, or any of that class, on SwordPC.PopupStack
    int o = poff(CLS(pc), "PopupStack");
    if (o < 0) return NO;
    struct { void **data; int num, max; } *st = (void *)(pc + o);
    for (int i = 0; i < st->num && i < 32; i++) {
        void *s = st->data[i];
        if (!s) continue;
        if (scene && s == scene) return YES;
        if (cls && isClass(s, cls)) return YES;
    }
    return NO;
}
static BOOL ourLessonUp(uint8_t *pc) { return gLessonTag && refLive(&gLessonScene) && popupUp(pc, gLessonScene.obj, NULL); }
static void showLesson(uint8_t *pc, NSString *tag, BOOL closeOnPauseExit) {
    uint8_t *fn = findFunction(pc, "ShowTutorial");
    int oName = fn ? propertyOffset(fn, "TutorialName") : -1, oRet = fn ? propertyOffset(fn, "ReturnValue") : -1, oClose; uint32_t mClose;
    if (!fn || oName < 0 || oRet < 0 || !boolProp(fn, "bCloseOnPauseExit", &oClose, &mClose) || *(uint16_t *)(fn + 0xe2) > 64) {
        LOG(@"lessons: ShowTutorial not as expected"); return;
    }
    uint8_t parms[64] = {0};
    FStr s = makeFString(tag.UTF8String);
    memcpy(parms + oName, &s, sizeof s);
    if (closeOnPauseExit) *(uint32_t *)(parms + oClose) |= mClose;
    processEvent(pc, fn, parms);
    uint8_t *scene = *(uint8_t **)(parms + oRet);
    gLessonTag = plausibleObj(scene) ? tag : nil;
    if (gLessonTag) gLessonScene = (ObjRef){ scene, *(int *)(scene + 0x38), CLS(scene) };
    LOG(@"lessons: %@ shown%@", tag, gLessonTag ? @"" : @" (no page came up: tutorials switched off?)");
}
static void hideLesson(uint8_t *pc, NSString *why) {            // only the page this section opened
    if (!gLessonTag) return;
    if (ourLessonUp(pc)) {
        uint8_t *fn = findFunction(pc, "HideTutorial"); uint8_t parms[32] = {0};
        if (fn && *(uint16_t *)(fn + 0xe2) <= 32) processEvent(pc, fn, parms);
        LOG(@"lessons: %@ closed (%@)", gLessonTag, why);
    }
    gLessonTag = nil;
}
// Once per character (Stab, Menu).
static void lessonCharacter(uint8_t *pc, int *slot, int *fights) {
    uint8_t *save = objAt(pc, "CommonSaveFile"), *pawn = objAt(pc, "PlayerPawn");
    int oS = save ? poff(CLS(save), "SwordSaveIndex") : -1, oF = pawn ? poff(CLS(pawn), "PlayThroughFightFinishedCount") : -1;
    *slot = oS >= 0 ? *(int *)(save + oS) : -1;
    *fights = oF >= 0 ? *(int *)(pawn + oF) : 0;
}
static BOOL lessonSeen(uint8_t *pc, NSString *tag) {
#ifdef IBFIX_SNAPS
    if (gLessonTest) return [tag isEqualToString:@"Stab"] ? gTestSeenStab : gTestSeenMenu;
#endif
    int slot, fights; lessonCharacter(pc, &slot, &fights);
    NSArray *e = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kLessonsShown][tag];
    return e.count == 2 && [e[0] intValue] == slot && [e[1] intValue] <= fights;
}
static void lessonMarkSeen(uint8_t *pc, NSString *tag) {
#ifdef IBFIX_SNAPS
    if (gLessonTest) { if ([tag isEqualToString:@"Stab"]) gTestSeenStab = YES; else gTestSeenMenu = YES; return; }
#endif
    int slot, fights; lessonCharacter(pc, &slot, &fights);
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *d = [[ud dictionaryForKey:kLessonsShown] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[tag] = @[@(slot), @(fights)]; [ud setObject:d forKey:kLessonsShown];
}

// Mega Hit and Ultra Hit, after the devs' combo lesson.
static int gComboTier; static CFAbsoluteTime gComboTierAt;     // the last combo the game awarded: its swipes, and when
static int gComboLesson; static CFAbsoluteTime gComboSince;    // 1: MEGA HIT up, 2: ULTRA HIT up
static ObjRef gComboBoss;
static void lessonComboAwarded(uint8_t *player) {              // SwordPlayer's OnDoCombo, before it runs
    int o = plausibleObj(player) ? poff(CLS(player), "ComboCounter") : -1;
    if (o < 0) return;
    gComboTier = *(int *)(player + o + 8); gComboTierAt = CFAbsoluteTimeGetCurrent();
    if (gComboLesson) LOG(@"lessons: a %d-swipe combo landed", gComboTier);
}
static BOOL lessonComboClear(uint8_t *boss, void *stack) {     // SwordBoss.ClearComboTutorial: YES if stepped over
    void *caller = *(void **)((uint8_t *)stack + 0x18);
    uint8_t **code = (uint8_t **)((uint8_t *)stack + FFRAME_CODE);
    BOOL fromHit = caller && [ibfix_objname(caller) isEqualToString:@"AlertForHit"];
    uint8_t *pc = lessonPC();
    if (!fromHit || (*code)[8] != 0x16 || !pc || !lessonsOn(pc)) {
        if (gComboLesson) LOG(@"lessons: the combo lesson ended by %@", caller ? ibfix_objname(caller) : @"?");
        gComboLesson = 0; return NO;
    }
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    BOOL fresh = t - gComboTierAt < 2;
    if (gComboLesson == 0) {
        showLesson(pc, @"MegaHit", NO);
        gComboLesson = 1; gComboSince = t; gComboBoss = (ObjRef){ boss, *(int *)(boss + 0x38), CLS(boss) };
    } else if (gComboLesson == 1 && fresh && gComboTier == 4) {
        showLesson(pc, @"UltraHit", NO);
        gComboLesson = 2; gComboSince = t;
    } else if ((gComboLesson == 2 && fresh && gComboTier == 5) || t - gComboSince > 40) {
        LOG(@"lessons: %@", t - gComboSince > 40 ? @"40 s on the page without the combo: the game ends its lesson" : @"ULTRA HIT done: the game ends its lesson");
        gComboLesson = 0; gLessonTag = nil;
        return NO;                                              // the game's own ClearComboTutorial (and HideTutorial)
    }
    *code += 9;                                                 // stepped over: the FName, then EX_EndFunctionParms
    return YES;
}

// Every frame (from the camera's update): the safety exit, Stab, Info2's end, Menu, and the test button's pages.
static BOOL gInfo2Up; static CFAbsoluteTime gInfo2At;
static BOOL gStabUp; static CFAbsoluteTime gStabAt, gStabLastSpot;
static BOOL gMenuUp; static CFAbsoluteTime gCirclesSince;
static void lessonInfoOpened(uint8_t *pc) {                    // FinishInfoTutorial, called by ToggleBossPopup, has run
    if (!lessonsOn(pc)) return;                                 // (the game's ShowTutorial closes the Info page itself)
    showLesson(pc, @"Info2", NO);
    gInfo2Up = gLessonTag != nil; gInfo2At = CFAbsoluteTimeGetCurrent();
}
static BOOL circlesShowing(uint8_t *hud) {                     // a save point's circles (SwordMobileTouchActor) on screen
    int o = poff(CLS(hud), "PostRenderedActors");
    if (o < 0) return NO;
    struct { void **data; int num, max; } *a = (void *)(hud + o);
    for (int i = 0; i < a->num && i < 64; i++)
        if (plausibleObj(a->data[i]) && [ibfix_objname(CLS(a->data[i])) isEqualToString:@"SwordMobileTouchActor"]) return YES;
    return NO;
}
#ifdef IBFIX_SNAPS
// Test app: the devs' own Info lesson at the next save point with an enemy, and the super move kept charged.
static void lessonTestTick(uint8_t *pc, uint8_t *hud, BOOL fight, BOOL circles, CFAbsoluteTime t) {
    if (gTestCombo && fight) {
        uint8_t *pawn = objAt(pc, "PlayerPawn");
        int o = pawn ? poff(CLS(pawn), "CurrentSuperLevel") : -1;
        if (o >= 0 && *(float *)(pawn + o) < 1) { *(float *)(pawn + o) = 1; static int n; if (++n <= 3) LOG(@"lessons (test): super move charged"); }
    }
    uint8_t *node = objAt(pc, "ChoiceNode");
    BOOL bossNode = NO;
    if (gTestInfo && circles && !gLessonTag && t - gCirclesSince > 1.0 && node && boolGet(node, "bIsBossChoiceNode", &bossNode) && bossNode &&
        !objAt(pc, "CachedMobileActor") && !popupUp(pc, NULL, "SwordTutorialPopup") && !popupUp(pc, NULL, "SwordBossInfoPopupScene")) {
        int o = poff(CLS(hud), "PostRenderedActors");
        struct { void **data; int num, max; } *a = (void *)(hud + o);
        void *circle = NULL;
        for (int i = 0; o >= 0 && i < a->num && i < 64 && !circle; i++)
            if (plausibleObj(a->data[i]) && [ibfix_objname(CLS(a->data[i])) isEqualToString:@"SwordMobileTouchActor"]) circle = a->data[i];
        uint8_t *fn = circle ? findFunction(pc, "HandleInfoTutorial") : NULL;
        int oA = fn ? propertyOffset(fn, "A") : -1;
        if (fn && oA >= 0 && *(uint16_t *)(fn + 0xe2) <= 16) {
            uint8_t parms[16] = {0}; *(void **)(parms + oA) = circle;
            processEvent(pc, fn, parms);
            gTestInfo = NO;
            LOG(@"lessons (test): the devs' Info lesson started at %@ (tap \"!\" for Info2)", ibfix_objname(node));
        }
    }
}
static void lessonTestArm(uint8_t *pc, BOOL on) {
    gTestCombo = gTestInfo = on; gTestSeenStab = gTestSeenMenu = NO;
    LOG(@"lessons (test): %@", on ? @"armed: super move charged in the next fight, then the combo lesson; Info at the next save point with an enemy; Stab and Menu once" : @"off");
}
static void *gLessonTestFn;
static NSString *const kLessonTest = @"ibfixLessonTest";
static void my_lessonTest(void *self, void *stack, void *result) { optionSwitch(self, stack, gLessonTestFn, &gLessonTest, kLessonTest, "New Lessons On This Character", lessonTestArm); }
// The super move (SwordPlayer.ActivateSuperMode -> DoSuperGloryMode) has run: the devs' combo lesson, as in the third fight.
static void lessonTestSuper(uint8_t *player) {
    uint8_t *pc = lessonPC(), *boss = pc ? objAt(pc, "CurrentBoss") : NULL;
    uint8_t *fn = boss ? findFunction(boss, "SetupComboTutorial") : NULL;
    if (!fn || *(uint16_t *)(fn + 0xe2) > 16) { LOG(@"lessons (test): SetupComboTutorial not found"); return; }
    uint8_t parms[16] = {0};
    processEvent(boss, fn, parms);
    gTestCombo = NO;
    LOG(@"lessons (test): super move used: the devs' combo lesson starts in 2 s");
}
#endif
static void lessonsTick(void) {
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    BOOL fight = NO; boolGet(pc, "bInBossFight", &fight);
    if (gLessonTag && !ourLessonUp(pc)) { LOG(@"lessons: %@ was closed by the game", gLessonTag); gLessonTag = nil; }
    // Mega Hit / Ultra Hit: should the fight end, or no big hit come for 45 s, the game's own ClearComboTutorial ends it.
    if (gComboLesson && (!fight || t - gComboSince > 45)) {
        uint8_t *fn = refLive(&gComboBoss) ? findFunction(gComboBoss.obj, "ClearComboTutorial") : NULL;
        LOG(@"lessons: combo pages ended (%@)", fight ? @"45 s without a combo" : @"the fight is over");
        gComboLesson = 0;
        if (fight && fn && *(uint16_t *)(fn + 0xe2) <= 16) { uint8_t parms[16] = {0}; processEvent(gComboBoss.obj, fn, parms); }
        else hideLesson(pc, @"fight over");
    }
    // Info2: until the enemy's info closes (60 s at most).
    if (gInfo2Up && (!popupUp(pc, NULL, "SwordBossInfoPopupScene") || t - gInfo2At > 60)) { hideLesson(pc, @"the enemy's info closed"); gInfo2Up = NO; }
    // Stab: the first weak spot of a character's first bloodline.
    uint8_t *boss = fight ? objAt(pc, "CurrentBoss") : NULL;
    BOOL spot = NO;
    if (boss && boolGet(boss, "bWeakPointActive", &spot) && spot) {
        gStabLastSpot = t;
        if (!gStabUp && !gLessonTag && !popupUp(pc, NULL, "SwordTutorialPopup") && lessonsOn(pc) && !lessonSeen(pc, @"Stab")) {
            showLesson(pc, @"Stab", NO);
            if (gLessonTag) { gStabUp = YES; gStabAt = t; lessonMarkSeen(pc, @"Stab"); }
        }
    }
    if (gStabUp && (!fight || t - gStabLastSpot > 1.0 || t - gStabAt > 10)) { hideLesson(pc, @"the weak spots are gone"); gStabUp = NO; }
    // Menu: a save point with its circles up for a second, nothing else on screen, 400 gold or more.
    BOOL circles = !fight && circlesShowing(hud);
    gCirclesSince = circles ? (gCirclesSince ? gCirclesSince : t) : 0;
    if (gMenuUp && (!circles || !gLessonTag)) { hideLesson(pc, circles ? @"pause menu" : @"a circle was tapped"); gMenuUp = NO; }
    BOOL menuWait = NO;
#ifdef IBFIX_SNAPS
    menuWait = gLessonTest && gTestInfo;                        // the test switch: the Info lesson first, then Menu
#endif
    if (circles && !gMenuUp && !gLessonTag && !menuWait && t - gCirclesSince > 1.0) {
        static CFAbsoluteTime lastLook;
        if (t - lastLook > 1.0) {                               // the checks below, once a second at most
            lastLook = t;
            uint8_t *pawn = objAt(pc, "PlayerPawn");
            int oGold = pawn ? poff(CLS(pawn), "CurrentGold") : -1;
            int gold = oGold >= 0 ? *(int *)(pawn + oGold) : 0;
            if (gold >= 400 && !objAt(pc, "CachedMobileActor") && !popupUp(pc, NULL, "SwordTutorialPopup") &&
                !popupUp(pc, NULL, "SwordBossInfoPopupScene") && lessonsOn(pc) && !lessonSeen(pc, @"Menu")) {
                showLesson(pc, @"Menu", YES);
                if (gLessonTag) { gMenuUp = YES; lessonMarkSeen(pc, @"Menu"); LOG(@"lessons: Menu at %d gold", gold); }
            }
        }
    }
#ifdef IBFIX_SNAPS
    if (gLessonTest) lessonTestTick(pc, hud, fight, circles, t);
#endif
}

#ifdef IBFIX_SNAPS
// ---- 4o. Test builds only: the cheat rows (25 October 2026) ----
// The devs' unused debug handlers in the options list's script (SwordUserOptionsList), as rows at the top of the test
// app's Options list, made with the game's own AddOption (addOptionRows, 7c; FIXES.md 62). The table below names each
// row's handler; where the devs' handler asked the console (this build has no cheat manager), ours acts directly:
//   Magic Always Full   switch, on until turned off: SwordPlayer.CurrentMagicLevel set full each frame it's below
//   God Mode            switch: the controller's bGodMode each frame, which the engine's Pawn.TakeDamage honours
//   Enemy Won't Attack  switch: the boss's bDontInitiateAttack each frame of a fight
//   Full Health, Kill The Enemy   SwordPC.SetPlayerFullHealth, SwordPC.ExitBossFight (the boss's KillBoss)
//   Gold To 99,999,999, Five Levels Up   the devs' own handlers, as they are
//   Back To Last Save Point  the devs' SwordPC.LoadLastSavePoint, and the God King circle back for this run (4q)
// The switches are kept across launches (NSUserDefaults). The real app never has any of it.
static NSString *const kCheatMagic = @"ibfixCheatMagic", *const kCheatGod = @"ibfixCheatGod", *const kCheatNoAttack = @"ibfixCheatNoAttack";
static BOOL gCheatMagic = YES, gCheatGod, gCheatNoAttack;
static void *gCheatMagicFn, *gCheatGodFn, *gCheatNoAttackFn, *gCheatHealthFn, *gCheatKillFn;
static uint8_t *cheatBoss(uint8_t *pc) {                       // the boss being fought, if a fight is on
    BOOL fight;
    return boolGet(pc, "bInBossFight", &fight) && fight ? objAt(pc, "CurrentBoss") : NULL;
}

// Every frame: the switches that are on.
static void cheatTick(void) {
    static BOOL loaded;
    if (!loaded) {
        loaded = YES;
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([d objectForKey:kCheatMagic]) gCheatMagic = [d boolForKey:kCheatMagic];
        gCheatGod = [d boolForKey:kCheatGod]; gCheatNoAttack = [d boolForKey:kCheatNoAttack];
        LOG(@"test cheats: Magic Always Full %@, God Mode %@, Enemy Won't Attack %@", gCheatMagic ? @"on" : @"off", gCheatGod ? @"on" : @"off", gCheatNoAttack ? @"on" : @"off");
    }
    if (!gCheatMagic && !gCheatGod && !gCheatNoAttack) return;
    uint8_t *hud = ffHud(), *pc = hud ? objAt(hud, "PlayerOwner") : NULL;
    if (!pc) return;
    if (gCheatMagic) {
        uint8_t *pawn = objAt(pc, "PlayerPawn");
        int oMag = pawn ? poff(CLS(pawn), "CurrentMagicLevel") : -1;
        if (oMag >= 0 && *(float *)(pawn + oMag) < 1) {
            *(float *)(pawn + oMag) = 1;
            static int n; if (++n <= 5 || n % 20 == 0) LOG(@"test cheats: magic gauge filled (%d)", n);
        }
    }
    BOOL on;
    if (gCheatGod && boolGet(pc, "bGodMode", &on) && !on) { boolSet(pc, "bGodMode", YES); LOG(@"test cheats: God Mode set on the controller"); }
    if (gCheatGod) {                                            // to check it holds: any health lost while it's on
        uint8_t *pawn = objAt(pc, "PlayerPawn");
        int oH = pawn ? poff(CLS(pawn), "Health") : -1;
        static int last = -1;
        if (oH >= 0) { int h = *(int *)(pawn + oH); if (last >= 0 && h < last) LOG(@"test cheats: God Mode on, but health went from %d to %d", last, h); last = h; }
    }
    uint8_t *boss = gCheatNoAttack ? cheatBoss(pc) : NULL;
    if (boss && boolGet(boss, "bDontInitiateAttack", &on) && !on) { boolSet(boss, "bDontInitiateAttack", YES); LOG(@"test cheats: %@ won't attack", ibfix_objname(boss)); }
}

static void godApply(uint8_t *pc, BOOL on) { if (!on) boolSet(pc, "bGodMode", NO); }
static void noAttackApply(uint8_t *pc, BOOL on) { uint8_t *boss = on ? NULL : cheatBoss(pc); if (boss) boolSet(boss, "bDontInitiateAttack", NO); }
static void my_cheatMagic(void *self, void *stack, void *result)    { optionSwitch(self, stack, gCheatMagicFn, &gCheatMagic, kCheatMagic, "Magic Always Full", NULL); }
static void my_cheatGod(void *self, void *stack, void *result)      { optionSwitch(self, stack, gCheatGodFn, &gCheatGod, kCheatGod, "God Mode", godApply); }
static void my_cheatNoAttack(void *self, void *stack, void *result) { optionSwitch(self, stack, gCheatNoAttackFn, &gCheatNoAttack, kCheatNoAttack, "Enemy Won't Attack", noAttackApply); }
// The buttons: on a tap, one of the player controller's own functions (no arguments).
static void cheatButton(uint8_t *list, void *stack, void *fn, const char *call) {
    BOOL bInit;
    if (!handlerArgs(stack, fn, &bInit) || bInit) return;
    uint8_t *pc = objAt(list, "SwordPC"), *f = pc ? findFunction(pc, call) : NULL;
    if (!f || *(uint16_t *)(f + 0xe2) > 64) { LOG(@"test cheats: %s not found", call); return; }
    uint8_t parms[64] = {0};
    processEvent(pc, f, parms);
    LOG(@"test cheats: %s", call);
}
static void my_cheatHealth(void *self, void *stack, void *result) { cheatButton(self, stack, gCheatHealthFn, "SetPlayerFullHealth"); }
static void my_cheatKill(void *self, void *stack, void *result)   { cheatButton(self, stack, gCheatKillFn, "ExitBossFight"); }
// Back To Last Save Point: the devs' OnUpdateLastSavePoint (SwordPC.LoadLastSavePoint), and the God King circle back (4q).
static void *gCheatLastSaveFn;
static void my_cheatLastSave(void *self, void *stack, void *result) {
    BOOL bInit;
    if (!handlerArgs(stack, gCheatLastSaveFn, &bInit) || bInit) return;
    uint8_t *pc = objAt(self, "SwordPC"), *f = pc ? findFunction(pc, "LoadLastSavePoint") : NULL;
    if (pc) godKingForget(pc);
    if (!f || *(uint16_t *)(f + 0xe2) > 64) { LOG(@"test cheats: LoadLastSavePoint not found"); return; }
    uint8_t parms[64] = {0};
    processEvent(pc, f, parms);
    LOG(@"test cheats: LoadLastSavePoint");
}

static void *gAchTestFn; static void my_achTest(void *self, void *stack, void *result);   // 4ae
static void addCheatOptions(uint8_t *list) {
    static const OptionRow rows[] = {
        { "Magic Always Full", "OnResetFPSChart", YES, (void *)my_cheatMagic, &gCheatMagicFn },
        { "God Mode (Can't Be Hurt)", "OnUpdateToggleGodMode", YES, (void *)my_cheatGod, &gCheatGodFn },
        { "Enemy Won't Attack", "OnToggleBossAttacks", YES, (void *)my_cheatNoAttack, &gCheatNoAttackFn },
        { "Full Health", "OnDumpFPSChart", NO, (void *)my_cheatHealth, &gCheatHealthFn },
        { "Kill The Enemy", "OnUpdateKillBoss", NO, (void *)my_cheatKill, &gCheatKillFn },
        { "Gold To 99,999,999", "OnUpdateGiveGold", NO, NULL, NULL },
        { "Five Levels Up", "OnUpdateBloodline", NO, NULL, NULL },
        { "Back To Last Save Point", "OnUpdateLastSavePoint", NO, (void *)my_cheatLastSave, &gCheatLastSaveFn },
        { "New Lessons On This Character", "OnUpdateEncryption", YES, (void *)my_lessonTest, &gLessonTestFn },   // 4p
        { "Show An Achievement", "OnRebalancePlayerStats", NO, (void *)my_achTest, &gAchTestFn } };   // 4ae
    addOptionRows(list, rows, sizeof rows / sizeof rows[0], NULL, "test cheats");
}
#endif

// ---- 4ad. A tap reaches the list row drawn under the finger (FIXES.md 94; from Infinity Blade 2's FIXES.md 45; every build) ----
// The engine's MobileMenuList draws its rows from where it was scrolled to, part rows included (RenderObject: the selected
// row at Top + SelectedOffset + SelectedItem.Offset), but finds the row under a finger without the part row
// (GetItemClickPosition: the touch minus SelectedOffset only). A tap that stops a flick's glide leaves the list resting
// part-way (no line-up), so until the next drag a tap near a row's edge reached the row above or below. Every list in
// the game is this code, so one rule covers all: for the length of the call SelectedOffset carries the part row too (with
// no part row, nothing changes). Test builds log every list tap: the row taken, where it's drawn, and which row the old
// code would have taken (FIXES.md 94, "The test").
static BOOL listClickCall(void *self, void *stack, void *result, int name) {
    NAME_ONCE(nameClickPos, "GetItemClickPosition");
    if (name != nameClickPos || nameClickPos < 0 || !self) return NO;
    void *cls = CLS(self);
    int oSO = poff(cls, "SelectedOffset"), oSel = poff(cls, "SelectedItem");
    if (oSO < 0 || oSel < 0) return NO;                         // not a MobileMenuList: left to the game
    float *so = (float *)((uint8_t *)self + oSO), keep = *so;
    float part = *(float *)((uint8_t *)self + oSel + 4);         // SelectedMenuItem: Index (int, +0), Offset (float, +4)
#ifdef IBFIX_SNAPS
    BOOL vert = YES; boolGet(self, "bIsVerticalList", &vert);
    float touch = NAN;                                          // the finger along the list, before the call moves Code on
    {
        uint8_t *arg = *(uint8_t **)((uint8_t *)stack + FFRAME_CODE) + 8;   // after the FName: (TouchX, TouchY), both locals
        uint8_t *a = !vert ? arg : arg[0] == 0x00 ? arg + 9 : NULL;   // EX_LocalVariable: 1 byte and a property pointer
        uint8_t *locals = *(uint8_t **)((uint8_t *)stack + 0x30);
        if (a && a[0] == 0x00 && locals) {
            uint8_t *prop; memcpy(&prop, a + 1, sizeof prop);
            if (prop) touch = *(float *)(locals + *(int *)(prop + 0x7c));
        }
    }
#endif
    *so = keep + part;
    ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
    *so = keep;
    static int n; if (fabsf(part) > 0.5f && ++n <= 20)
        LOG(@"lists: a tap on %@ measured with its part-row scroll as drawn (%.0f px)", ibfix_objname(self), part);
#ifdef IBFIX_SNAPS
    // The witness: the row taken, as drawn this frame (RenderObject sets each drawn row's VpPos and VpSize). The finger
    // must be inside it; the old code took the same row only if the finger plus the part row is inside it too.
    static int nt; if (++nt <= 300) {
        int oItems = poff(cls, "Items"), oEdge = poff(cls, vert ? "Top" : "Left");
        uint8_t *got = *(uint8_t **)result;
        float at = oEdge >= 0 && !isnan(touch) ? touch + *(float *)((uint8_t *)self + oEdge) : NAN;   // OnTouch took the edge off
        int gotIdx = -1; NSString *span = @"", *verdict = @"";
        if (got && oItems >= 0) { uint8_t *data = *(uint8_t **)((uint8_t *)self + oItems); int num = *(int *)((uint8_t *)self + oItems + 8);
            for (int i = 0; data && i < num; i++) if (*(uint8_t **)(data + 8 * i) == got) { gotIdx = i; break; } }
        void *ic = got ? CLS(got) : NULL;
        int oPos = ic ? poff(ic, "VpPos") : -1, oSize = ic ? poff(ic, "VpSize") : -1;
        if (oPos >= 0 && oSize >= 0 && !isnan(at)) {
            float p = *(float *)(got + oPos + (vert ? 4 : 0)), s = *(float *)(got + oSize + (vert ? 4 : 0));
            span = [NSString stringWithFormat:@", drawn %.0f-%.0f", p, p + s];
            BOOL inside = at >= p && at < p + s, oldSame = at + part >= p && at + part < p + s;
            verdict = !inside ? @": FINGER OUTSIDE THE ROW TAKEN" : oldSame ? @": the finger inside it; the old code the same row"
                    : at + part < p ? (vert ? @": the finger inside it; the old code: THE ROW ABOVE" : @": the finger inside it; the old code: THE ROW TO THE LEFT")
                    : (vert ? @": the finger inside it; the old code: THE ROW BELOW" : @": the finger inside it; the old code: THE ROW TO THE RIGHT");
        }
        LOG(@"lists: TEST %@ tap at %.0f (a %@ list, part-row scroll %.0f px): took row %d %@%@%@",
            ibfix_objname(self), at, vert ? @"vertical" : @"sideways", part, gotIdx, got ? ibfix_objname(got) : @"(none)", span, verdict);
    }
#endif
    return YES;
}

// ---- 4ae. Achievements without Game Center: kept on the device, shown with the devs' own pop-up (5 November 2026; FIXES.md 95) ----
// The game's 64 achievements (SwordBasePC.eAchievements) are unlocked by UnlockAchievement(id, bSilent) from the fights,
// the store and the levels' Kismet; the devs' function waits for Game Center (bAchievementsCached) for each name and
// description, so without it nothing fires. Its UFunction gets native code here (as section 7's handlers): script calls
// bring the arguments in the caller's code, the console in the function's Locals. The record is kept on the device
// (Documents/ibfix-achievements.plist, all character slots); a new one not silent plays CheevioSound and shows the devs'
// pop-up (ShowAchievement) with Game Center's name and description (kAch). bAchievementsCached is set at once, or
// CheckForMissingAchievements re-arms a timer for ever and the devs' re-check (every lifetime count a save has passed)
// never runs. Jackpot! (29) only at 100 chests, as its description says (by choice, FIXES.md 95); the game asks at 30.
static const struct { const char *code, *name, *desc; } kAch[65] = {   // 4ae: names and descriptions as on Game Center (study/achievements.md)
    { "A_NONE", "", "" },
    { "A_DefeatUnder60", "Minuteman", "Defeat an enemy in under 60 seconds." },   // 1
    { "A_DefeatNoDamage", "Inconceivable!", "Defeat an enemy without taking any damage." },   // 2
    { "A_Fight10GuysSPT", "Last one standing", "Fight ten enemies in a single playthrough." },   // 3
    { "A_Level4", "Higher and higher", "Reach Level 45." },   // 4
    { "A_Level5", "Level un-capped", "Reach Level 100." },   // 5
    { "A_Block1", "Cinderblock", "Block 10 attacks." },   // 6
    { "A_Block2", "Brick wall", "Block 100 attacks." },   // 7
    { "A_Combo1", "All right, little man", "Perform a Combo Attack." },   // 8
    { "A_Combo2", "Now THIS happens", "Perform 50 Combo Attacks." },   // 9
    { "A_Combo3", "The bigger they are", "Perform 200 Combo Attacks." },   // 10
    { "A_Combo4", "The harder they fall", "Perform 1000 Combo Attacks." },   // 11
    { "A_OneOfEachComboInBattle", "Variety is the spice", "Do each type of combo in the same battle." },   // 12
    { "A_Parry1", "En Garde!", "Perform 10 Parries." },   // 13
    { "A_Parry2", "A reed in the wind", "Perform 50 Parries." },   // 14
    { "A_Parry3", "You've got the touch", "Perform 200 Parries." },   // 15
    { "A_Parry4", "Epic!", "Perform 1000 Parries." },   // 16
    { "A_Dodge1", "Roger dodger", "Dodge 10 times." },   // 17
    { "A_Dodge2", "Artful dodger", "Dodge 100 times." },   // 18
    { "A_Stab1", "Full of holes", "Perform 5 Stab Attacks." },   // 19
    { "A_Stab2", "Like Swiss cheese", "Perform 100 Stab Attacks." },   // 20
    { "A_Magic1", "Wizard!", "Cast a magic spell." },   // 21
    { "A_Magic2", "You shall not pass!", "Cast 100 magic spells." },   // 22
    { "A_Super1", "Warriors only", "Perform a Super Attack." },   // 23
    { "A_Super2", "No, THIS is Sparta", "Perform 50 Super Attacks." },   // 24
    { "A_Gold1", "Working hard", "Acquire 1,000 gold pieces." },   // 25
    { "A_Gold2", "Hardly working", "Acquire 25,000 gold pieces." },   // 26
    { "A_Gold3", "It's own reward", "Acquire 100,000 gold pieces." },   // 27
    { "A_Treasure1", "Payday!", "Open 5 treasure chests." },   // 28
    { "A_Treasure2", "Jackpot!", "Open 100 treasure chests." },   // 29
    { "A_FindAllWorldItems", "Waste not, want not", "Find all world treasures in a play-through." },   // 30
    { "A_Purchase", "Only what ya see", "Purchase an inventory item." },   // 31
    { "A_Items1", "Well-equipped", "Increase your inventory to at least 10 items." },   // 32
    { "A_Items2", "Bag of holding", "Increase your inventory to at least 50 items." },   // 33
    { "A_Master1", "If ya got it, use it", "Master an inventory item." },   // 34
    { "A_Master2", "Master of disaster", "Master 10 inventory items." },   // 35
    { "A_Master3", "Intimately familiar", "Master 50 inventory items." },   // 36
    { "A_Level1", "Ding!", "Reach level 5." },   // 37
    { "A_Level2", "There is no try", "Reach level 10." },   // 38
    { "A_Level3", "Like dustin' crops", "Reach level 20." },   // 39
    { "A_BloodLines1", "Prodigal son", "Complete 1 Bloodline." },   // 40
    { "A_BloodLines2", "Skips a generation", "Complete 2 Bloodlines." },   // 41
    { "A_BloodLines3", "Back in my day", "Complete 5 Bloodlines." },   // 42
    { "A_BloodLines4", "This is on a phone!", "Complete 20 Bloodlines." },   // 43
    { "A_WinWODodgeBlock", "Don't back down", "Win a battle without dodging or blocking." },   // 44
    { "A_WinWOSlashing", "Pen is mightier", "Win a battle without swinging your sword." },   // 45
    { "A_DefeatDarkLord", "Now stay down!", "Defeat the God-King." },   // 46
    { "A_JoinDarkLord", "Not in Kansas", "Get the alternate ending in the game." },   // 47
    { "A_DefeatDarkLordWRuin", "Insult to injury", "Kill the god king with Ruin." },   // 48
    { "A_Combo4x", "Four on the floor", "Perform a four-hit combo." },   // 49
    { "A_Combo5x", "Fists of fury", "Perform a five-hit combo." },   // 50
    { "A_Gold4", "1 million dollars!", "Acquire 1,000,000 gold pieces." },   // 51
    { "A_Items3", "My preciouses", "Increase your inventory to at least 100 items." },   // 52
    { "A_MasterX2", "Keeps on giving", "Master any inventory item twice." },   // 53
    { "A_NewGamePlus", "New game plus", "Start a new game plus." },   // 54
    { "A_DefeatDeathless", "Master your domain", "Defeat all the Deathless." },   // 55
    { "A_DefeatZero", "All good things...", "Get the final ending of the game." },   // 56
    { "A_NegativeBloodline1", "How'd you do that?", "Reach Bloodline -1." },   // 57
    { "A_NegativeBloodline2", "Delved too deeply", "Reach Bloodline -10." },   // 58
    { "A_Survival1", "Survivor", "Survive 5 Arena rounds in Survivor mode." },   // 59
    { "A_Survival2", "Eye of the tiger", "Survive 20 Arena rounds in Survivor mode." },   // 60
    { "A_Multiplayer1", "Playing with friends", "Complete 5 matches in Arena Multiplayer." },   // 61
    { "A_Multiplayer2", "Contender", "Win 10 matches in Arena Multiplayer." },   // 62
    { "A_Multiplayer3", "Titan destroyer", "Win 100 matches in Arena Multiplayer as a Knight." },   // 63
    { "A_Multiplayer4", "Knight destroyer", "Win 100 matches in Arena Multiplayer as a Titan." },   // 64
};
static NSMutableDictionary *gAchGot;                           // "<id>" -> the date it was earned
static void *gUnlockFn;                                         // SwordBasePC.UnlockAchievement
static NSString *achPath(void) {
    return [DOCUMENTS stringByAppendingPathComponent:@"ibfix-achievements.plist"];
}
static NSMutableDictionary *achGot(void) {
    if (!gAchGot) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:achPath()];
        gAchGot = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
        LOG(@"achievements: %lu of 64 earned on this device (%@)", (unsigned long)gAchGot.count, d ? @"read" : @"none yet");
    }
    return gAchGot;
}
BOOL ibfix_achievement_earned(int id) { return id >= 1 && id <= 64 && achGot()[[NSString stringWithFormat:@"%d", id]] != nil; }
// The devs' pop-up and sound, for one achievement (also the test row's).
static void achShow(uint8_t *pc, int id) {
    uint8_t *hud = objAt(pc, "myHUD");
    uint8_t *show = hud ? findFunction(hud, "ShowAchievement") : NULL;
    int oName = show ? propertyOffset(show, "AchievementName") : -1, oDesc = show ? propertyOffset(show, "AchievementDesc") : -1;
    if (oName < 0 || oDesc < 0 || *(uint16_t *)(show + 0xe2) > 64) { LOG(@"achievements: the HUD's ShowAchievement not found (HUD %@)", hud ? ibfix_objname(hud) : @"none"); return; }
    uint8_t parms[64] = {0};
    *(FStr *)(parms + oName) = makeFString(kAch[id].name);
    *(FStr *)(parms + oDesc) = makeFString(kAch[id].desc);
    processEvent(hud, show, parms);
    uint8_t *sound = objAt(pc, "CheevioSound"), *play = findFunction(pc, "PlayUiSound");
    int oSound = play ? propertyOffset(play, "Sound") : -1;
    if (sound && oSound >= 0 && *(uint16_t *)(play + 0xe2) <= 64) { uint8_t p2[64] = {0}; *(void **)(p2 + oSound) = sound; processEvent(pc, play, p2); }
    else LOG(@"achievements: no sound (CheevioSound %@, PlayUiSound %@)", sound ? @"found" : @"missing", play ? @"found" : @"missing");
}
// why: who asked (the log's). force: our own Jackpot check (29 at 100 chests).
static void achUnlock(uint8_t *pc, int id, BOOL silent, NSString *why, BOOL force) {
    if (id < 1 || id > 64 || !pc) return;
    if (id == 29 && !force) {                                   // the game asks at 30 chests: only at 100 (by choice, FIXES.md 95)
        uint8_t *pawn = objAt(pc, "PlayerPawn"); int oChest = pawn ? poff(CLS(pawn), "TotalTreasureChest") : -1;
        int chests = oChest >= 0 ? *(int *)(pawn + oChest) : 0;
        if (chests < 100) { LOG(@"achievements: 29 Jackpot! asked by %@ at %d chests: held for 100 (by choice)", why, chests); return; }
    }
    NSString *key = [NSString stringWithFormat:@"%d", id];
    if (achGot()[key]) return;
    achGot()[key] = silent ? @{ @"date": [NSDate date], @"quiet": @YES } : @{ @"date": [NSDate date] };   // quiet: from the re-check
    BOOL saved = [achGot() writeToFile:achPath() atomically:YES];
    LOG(@"achievements: %d %s earned (%s; by %@, %@)%@", id, kAch[id].name, kAch[id].code, why, silent ? @"quietly" : @"shown", saved ? @"" : @"; NOT SAVED");
    if (!silent) achShow(pc, id);
}
// The native in UnlockAchievement's place: (byte AchievementId, optional bool bSilent).
static void my_unlockAchievement(void *self, void *stack, void *result) {
    int id = 0; BOOL silent = NO; NSString *why;
    if (*(void **)((uint8_t *)stack + 0x18) == gUnlockFn) {    // through ProcessEvent (the console): its own Locals
        uint8_t *locals = *(uint8_t **)((uint8_t *)stack + 0x30);
        int oId = propertyOffset(gUnlockFn, "AchievementId"), oS = propertyOffset(gUnlockFn, "bSilent");
        if (locals && oId >= 0) id = locals[oId];
        if (locals && oS >= 0) silent = *(uint32_t *)(locals + oS) != 0;
        why = @"the console";
    } else {                                                    // a script call: from the caller's code
        uint32_t a[4] = {0}, b[4] = {0};
        void *caller = *(void **)((uint8_t *)stack + 0x18);
        stepExpr(stack, a);
        stepExpr(stack, b);                                     // an omitted bSilent leaves 0
        (*(uint8_t **)((uint8_t *)stack + FFRAME_CODE))++;      // P_FINISH (EX_EndFunctionParms)
        id = a[0] & 0xff; silent = b[0] != 0;
        why = caller ? ibfix_objname(caller) : @"?";
    }
    achUnlock(self, id, silent, why, NO);
}
static void achInstall(uint8_t *pc) {
    static BOOL tried; if (tried) return; tried = YES;
    if (!gFuncOff || !pointHandler(pc, "UnlockAchievement", (void *)my_unlockAchievement, &gUnlockFn)) { LOG(@"achievements OFF: UnlockAchievement not as expected"); return; }
    BOOL ok = boolSet(pc, "bAchievementsCached", YES);
    LOG(@"achievements ON: UnlockAchievement kept on the device (%lu earned so far); bAchievementsCached %@", (unsigned long)achGot().count, ok ? @"set" : @"NOT FOUND");
}
// ---- 4al. Achievements a save clearly proves, granted quietly (10 November 2026; FIXES.md 102) ----
// The devs' re-check at each load (SwordPlayer.CheckForMissingAchievements) grants what a save's counts show, but not the
// achievements the game notices only as they happen, so those popped up again for a player who had them. After that
// re-check, the ones a save clearly proves are granted quietly too (by choice, FIXES.md 102): 49 and 50 (a four- and a five-hit
// combo) from 200 combos; 1, 2 and 3 (under 60 seconds, no damage, ten in one playthrough) from level 20. Not 31 (buying
// an item: many players sell what they buy); the rest (feats and endings) stay to be earned in play, with the pop-up.
// A count the pawn keeps itself plus the saved total's (CurrentTotalTrackingStats, a struct whose type is at +0xb8 of its
// property), as the game adds them.
static int achCount(uint8_t *pawn, const char *name) {
    void *cls = CLS(pawn);
    int own = poff(cls, name), oStats = poff(cls, "CurrentTotalTrackingStats");
    int n = own >= 0 ? *(int *)(pawn + own) : 0;
    static void *statsStruct; static BOOL looked;
    if (!looked) {
        looked = YES;
        for (uint8_t *st = cls; st && !statsStruct; st = *(uint8_t **)(st + 0x68))
            for (uint8_t *f = *(uint8_t **)(st + 0x70); f; f = *(uint8_t **)(f + 0x60))
                if ([ibfix_objname(f) isEqualToString:@"CurrentTotalTrackingStats"]) { statsStruct = *(void **)(f + 0xb8); break; }
    }
    int inStats = statsStruct ? propertyOffset(statsStruct, name) : -1;
    if (oStats >= 0 && inStats >= 0) n += *(int *)(pawn + oStats + inStats);
    return (own < 0 && inStats < 0) ? -1 : n;
}
static void achInferCheck(uint8_t *pawn) {
    uint8_t *pc = objAt(pawn, "PC");
    int oLevel = poff(CLS(pawn), "PawnLevel");
    int combos = achCount(pawn, "TotalComboCount"), level = oLevel >= 0 ? *(int *)(pawn + oLevel) : -1;
    if (!pc) return;
    if (combos >= 200) for (int id = 49; id <= 50; id++) achUnlock(pc, id, YES, @"the save (200 or more combos)", NO);
    if (level >= 20) for (int id = 1; id <= 3; id++) achUnlock(pc, id, YES, @"the save (level 20 or above)", NO);
    static int said; if (said++ < 3) LOG(@"achievements: the save's proof: %d combos, level %d (%lu of 64 earned now)", combos, level, (unsigned long)achGot().count);
}
// After each chest (SwordPlayer.GiveReward): Jackpot! at 100.
static void achChestCheck(uint8_t *pawn) {
    int oChest = poff(CLS(pawn), "TotalTreasureChest");
    if (oChest >= 0 && *(int *)(pawn + oChest) >= 100) achUnlock(objAt(pawn, "PC"), 29, NO, @"the 100th chest", YES);
}
#ifdef IBFIX_SNAPS
// Test builds: "Show An Achievement" earns the first one not yet earned (or shows the first again), through the same
// path as the levels' console commands (ProcessEvent), to see the pop-up.
static void *gAchTestFn;
static int gAchSnapFrames;
static void my_achTest(void *self, void *stack, void *result) {
    BOOL bInit;
    if (!handlerArgs(stack, gAchTestFn, &bInit) || bInit) return;
    uint8_t *pc = objAt(self, "SwordPC");
    if (!pc || !gUnlockFn) { LOG(@"achievements: test row without the controller or the hook"); return; }
    // Documents/ibfix-achtest.txt, ids such as "10 63": each tap shows the next of them, earned or not (FIXES.md 109)
    static NSArray *pick; static NSUInteger next;
    if (!pick) pick = [[NSString stringWithContentsOfFile:[DOCUMENTS stringByAppendingPathComponent:@"ibfix-achtest.txt"]
                         encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@" "] ?: @[];
    int want = pick.count ? [pick[next++ % pick.count] intValue] : 0;
    if (want >= 1 && want <= 64) { LOG(@"achievements: test row shows %d (ibfix-achtest.txt)", want); achShow(pc, want); gAchSnapFrames = 1; return; }
    int id = 1; while (id <= 64 && (ibfix_achievement_earned(id) || id == 29 || id > 60)) id++;
    if (id > 64) { LOG(@"achievements: test row: all earned, showing 1 again"); achShow(pc, 1); return; }
    uint8_t parms[16] = {0};
    int oId = propertyOffset(gUnlockFn, "AchievementId");
    if (oId < 0 || *(uint16_t *)((uint8_t *)gUnlockFn + 0xe2) > 16) { LOG(@"achievements: test row: UnlockAchievement's arguments not as expected"); return; }
    parms[oId] = (uint8_t)id;
    processEvent(pc, gUnlockFn, parms);
    LOG(@"achievements: test row asked for %d", id);
    gAchSnapFrames = 1;                                         // photograph the pop-up (below)
}
// The pop-up photographed full size as it comes in, holds and goes (it runs from the HUD's next draw: the menus stop the
// HUD drawing), counted in the HUD's own calls of DrawAchievement, once a frame.
// Each menu screen photographed full size once per launch, 45 frames after it first draws (its opening animation done).
// The results screen filmed once per launch (FIXES.md 98): from its first frame, a picture every 0.045 s (half size), for
// 40 s or 800 pictures. Labels: res-<n>-<seconds since the screen opened>-<the screen drawing>, read by
// tools/framediff.py. Reading frames back halves the frame rate, so it films only when the Mac has switched it on: a file
// Documents/ibfix-film-results with "on" in it (tools/captures.sh film on|off).
static void resultsFilm(NSString *cls) {
    static CFAbsoluteTime start, last; static int n; static int armed = -1;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (!start) {
        if (![cls isEqualToString:@"SwordBattleResultsScene"]) return;
        if (armed < 0) {
            NSString *f = [DOCUMENTS stringByAppendingPathComponent:@"ibfix-film-results"];
            armed = [[NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:NULL] hasPrefix:@"on"];   // off: emptied
            LOG(@"results film: %@", armed ? @"switched on (Documents/ibfix-film-results)" : @"off (tools/captures.sh film on switches it on)");
        }
        if (!armed) return;
        start = t; LOG(@"results film: started");
    }
    if (n >= 800 || t - start > 40) { if (n >= 0) { LOG(@"results film: ended, %d pictures", n); n = -1; } return; }
    if (n < 0 || t - last < 0.045) return;
    last = t;
    ibfix_snap([NSString stringWithFormat:@"res-%04d-%06.2f-%@", n++, t - start, cls]);
}
static void sceneSnap(uint8_t *scene) {
    static NSMutableDictionary *frames;
    if (!frames) frames = [NSMutableDictionary dictionary];
    NSString *cls = ibfix_objname(CLS(scene));
    resultsFilm(cls);
    int n = [frames[cls] intValue] + 1;
    if (n > 46) return;
    frames[cls] = @(n);
    if (n == 45 && ibfix_auto_photos()) { ibfix_snap([NSString stringWithFormat:@"full-scene-%@", cls]); LOG(@"achievements: the %@ screen photographed", cls); }
}
static void achSnapTick(void) {
    if (!gAchSnapFrames) return;
    int f = gAchSnapFrames++;
    if (f == 8 || f == 90 || f == 205) { ibfix_snap([NSString stringWithFormat:@"full-achievement-%d", f]); LOG(@"achievements: pop-up photographed at frame %d of the HUD's drawing", f); }
    if (f > 205) gAchSnapFrames = 0;
}
#endif

// ---- 4ai. The achievements' own badges in the list and the box (6 November 2026; FIXES.md 100) ----
// Game Center's badges (Epic's art): the 64 and a locked one for rows not earned are one 2048 x 2048 sheet
// (assets/ibfix-badges.rgba, tools/badges_sheet.py): cell i (badge i + 1; i 64 the locked one) 204 px square at column
// i % 10, row i / 10, the badge's 192 px at 6 px in. The game has no picture to hold it, so the add-on asks the engine for
// a new one (Texture2D.Create, the first time the list opens) and keeps it for the session (the root set, as fix 47's
// logo); when the engine sends that empty picture to the graphics chip, the sheet goes in its place (badgeUpload, 3e's
// interposers). The badges are drawn with the engine's own tile routine (menuPiece) inside the game's own drawing, so its
// clipping and fading apply as to everything else:
//   a row: just before its PostRenderItem (which covers whatever passes the list's top or bottom with black), at the
//          caption's old place, its caption moved right by the badge and 40 px (achFillList)
//   the box a tap on an earned row opens (the game's SwordOkPopup): its title moved right by half the badge and gap, so
//          the pair stays centred, and the badge drawn just after the box, fading in with it (its Opacity)
#define BADGE_CELL 204
#define BADGE_PAD 6
#define BADGE_PX 192
static void *gBadgeTex;                                         // the engine picture holding the sheet
static void *gAchRows[65];                                      // the achievements list's rows by number (achFillList)
static int gAchBoxId; static void *gAchBox; static CFAbsoluteTime gAchBoxAt, gAchBoxSeen; static BOOL gAchBoxShifted;
static float numPropEarly(void *o, const char *name) {
    int off = o ? poff(CLS(o), name) : -1;
    if (off <= 0) return -1;
    int iv = *(int *)((uint8_t *)o + off);
    return (iv > -100000 && iv < 100000) ? (float)iv : *(float *)((uint8_t *)o + off);
}
static void badgesMake(void) {
    static BOOL tried;
    if (gBadgeTex || tried || !gAnyTexture) return;
    tried = YES;
    uint8_t *f = findFunction(gAnyTexture, "Create");
    int oX = f ? propertyOffset(f, "InSizeX") : -1, oY = f ? propertyOffset(f, "InSizeY") : -1, oF = f ? propertyOffset(f, "InFormat") : -1;
    int oR = f ? propertyOffset(f, "ReturnValue") : -1;
    if (oX < 0 || oY < 0 || oR < 0 || *(uint16_t *)(f + 0xe2) > 32) { LOG(@"badges OFF: Texture2D.Create not as expected"); return; }
    uint8_t parms[32] = {0};
    *(int32_t *)(parms + oX) = 2048; *(int32_t *)(parms + oY) = 2048;
    if (oF >= 0) parms[oF] = 2;                                 // PF_A8R8G8B8
    gBadgeAskedAt = CFAbsoluteTimeGetCurrent();
    processEvent(gAnyTexture, f, parms);
    void *t = *(void **)(parms + oR);
    if (!t) { gBadgeAskedAt = 0; LOG(@"badges OFF: Texture2D.Create made nothing"); return; }
    *(uint64_t *)((uint8_t *)t + 0x10) |= 0x4000;              // RF_RootSet: kept for the session
    // Texture2D.Create sizes the picture but makes no resource (Resource, +0x100, stays 0), so nothing would reach the
    // chip. UTexture::UpdateResource does that: vtable slot 0x270, file address 0x10026df88 (it releases the old resource,
    // makes one through slot 0x278, CreateResource, stores it at +0x100 and starts its upload); called only if it's there.
    {
        intptr_t slide = _dyld_get_image_vmaddr_slide(0); void **vt = *(void ***)t;
        if ((intptr_t)vt[0x270 / 8] - slide == 0x10026df88) ((void (*)(void *))vt[0x270 / 8])(t);
        else LOG(@"badges: UpdateResource not where expected (%#lx); the picture may never reach the chip", (unsigned long)((intptr_t)vt[0x270 / 8] - slide));
    }
    gBadgeTex = t;
#ifdef IBFIX_SNAPS
    {   // for finding UTexture::UpdateResource: the vtable's texture part, as file addresses
        intptr_t slide = _dyld_get_image_vmaddr_slide(0); void **vt = *(void ***)t;
        NSMutableString *m = [NSMutableString string];
        for (int off = 0x250; off <= 0x2c0; off += 8) [m appendFormat:@" %#x:%#lx", off, (unsigned long)((intptr_t)vt[off / 8] - slide)];
        LOG(@"badges: Texture2D vtable %#lx:%@ | SizeX %.0f SizeY %.0f", (unsigned long)((intptr_t)vt - slide), m, numPropEarly(t, "SizeX"), numPropEarly(t, "SizeY"));
    }
#endif
    LOG(@"badges: a 2048 x 2048 picture made for the sheet (%@, its resource %p)", ibfix_objname(t), *(void **)((uint8_t *)t + 0x100));
}
static void badgeDraw(void *canvas, int cell, float x, float y, float size, float alpha) {
    if (!gBadgeTex || !canvas || size <= 0 || alpha <= 0) return;
    if (!gBadgeUp) {
        // The engine makes a picture on the graphics chip only when something first draws with it: a speck of it, 2 px at
        // alpha 0.004 (invisible), until the sheet is in; the swap is armed again while it waits.
        if (!gBadgeAskedAt) gBadgeAskedAt = CFAbsoluteTimeGetCurrent();
        const float faint[4] = { 1, 1, 1, 0.004f };
        menuPiece(canvas, gBadgeTex, x, y, 2, 2, 100, 100, 2, 2, faint, 2);
        static int said; if (!said) { said = 1; LOG(@"badges: waiting for the sheet: the picture drawn once, faintly, so the engine makes it (its resource %p)", *(void **)((uint8_t *)gBadgeTex + 0x100)); }
        return;
    }
    const float col[4] = { 1, 1, 1, alpha };
    menuPiece(canvas, gBadgeTex, x, y, size, size, (cell % 10) * BADGE_CELL + BADGE_PAD, (cell / 10) * BADGE_CELL + BADGE_PAD, BADGE_PX, BADGE_PX, col, 2);
}
// the canvas's own size (the HUD region): its ClipX/ClipY change as text draws (SwordDrawText.Render's SetClip)
static BOOL canvasSize(void *canvas, float *w, float *h) {
    static int oX = -2, oY = -2;
    if (!canvas) return NO;
    if (oX == -2) { oX = poff(CLS(canvas), "SizeX"); oY = poff(CLS(canvas), "SizeY"); }
    if (oX <= 0 || oY <= 0) return NO;
    *w = *(int *)((uint8_t *)canvas + oX); *h = *(int *)((uint8_t *)canvas + oY);
    return *w > 0 && *h > 0;
}
#ifdef IBFIX_SNAPS
// Test builds: the whole path proved on the title screen, so a check launch shows it: 70 s after launch (past the start-up
// film), the badge picture is made (from the title's picture) and its speck drawn until the sheet is in.
static void badgeTitleTest(void *canvas, void *tex) {
    if (gBadgeUp || !tex || CFAbsoluteTimeGetCurrent() - gLaunchTime < 70) return;
    if (!gAnyTexture && isClass(tex, "Texture2D")) gAnyTexture = tex;
    badgesMake();
    badgeDraw(canvas, 64, 0, 0, 2, 1);
}
#endif
static float numProp(void *o, const char *name, float dflt) {    // a property read as an int or a float (whichever it is)
    int off = o ? poff(CLS(o), name) : -1;
    if (off <= 0) return dflt;
    int iv = *(int *)((uint8_t *)o + off);
    return (iv > -100000 && iv < 100000) ? (float)iv : *(float *)((uint8_t *)o + off);
}
// 4aj: 61-64, the multiplayer achievements, can't be earned now (multiplayer ran through Game Center:
// study/achievements.md, "Can't be earned now"). Unless a save already earned one (by choice, FIXES.md 101): the
// name, greyed, "(unavailable)" (longer words don't fit), their own badge greyed (the sheet's cells 65-68,
// tools/badges_sheet.py), no tap and no button (Opacity 0, leaving the words its room), and the count out of 60 plus any
// of the four earned.
static BOOL achGone(int id) { return id >= 61 && id <= 64 && !ibfix_achievement_earned(id); }
// a row of the list, just before its PostRenderItem: the canvas's origin is the row's corner
static void achRowBadge(void *row) {
    int id = 0;
    for (int i = 1; i <= 64 && !id; i++) if (gAchRows[i] == row) id = i;
    if (!id || !gLastCanvas) return;
    uint8_t *c = gLastCanvas;
    float orgX = *(float *)(c + 0x68), orgY = *(float *)(c + 0x6c), clipX, clipY;
    float H = numProp(row, "Height", 0), alpha = numProp(row, "BackgroundAlpha", 1);
    if (H < 20 || !canvasSize(c, &clipX, &clipY)) return;
    float bs = roundf(H * 0.825f);
    badgeDraw(c, ibfix_achievement_earned(id) ? id - 1 : achGone(id) ? 64 + id - 60 : 64, orgX + 15 * clipX / 960, orgY + (H - bs) / 2, bs, alpha > 0 ? alpha : 1);
    static int said; if (!said && gBadgeUp) { said = 1; LOG(@"badges: drawn in the list (row %d, %.0f px, at %.0f,%.0f)", id, bs, orgX + 15 * clipX / 960, orgY + (H - bs) / 2); }
#ifdef IBFIX_TEST_TOOLS
    static BOOL goneSaid[4];                                      // 4aj: the four rows' writing at one size
    uint8_t *cap = achGone(id) && !goneSaid[id - 61] ? objAt(row, "Caption") : NULL;
    int oDS = cap ? poff(CLS(cap), "DrawScale") : -1, oDZ = cap ? poff(CLS(cap), "DrawSize") : -1;
    if (oDS > 0 && oDZ > 0 && *(float *)(cap + oDS) > 0) {
        goneSaid[id - 61] = YES;
        LOG(@"achievements list: row %d's writing at scale %.3f, %.0f px wide, from %.0f (the row's right edge at %.0f)", id,
            *(float *)(cap + oDS), *(float *)(cap + oDZ), orgX + numProp(cap, "BoundingBoxPos", 0) * clipX / 960, orgX + clipX);
    }
#endif
}
// ---- 4am. The achievement pop-up: ACHIEVEMENT UNLOCKED, the achievement's badge, a banner (10 November 2026; FIXES.md 102) ----
// The devs' pop-up (queued by SwordHudBase.ShowAchievement, shown by DrawAchievement on B_Info's strip at the top right)
// read like a hint. Chosen, design B: a dark banner under the top with gold lines, the badge on a gold glow, then
// ACHIEVEMENT UNLOCKED, the name and the description. The devs' queue and timing still run it (one at a time, held 3 s,
// out over 1 s; our entrance 0.35 s): before their DrawAchievement their strip is moved off the screen, and after it the
// banner is drawn from their state, its lines with their own two text objects (DrawTitle, DrawDesc: the game's font and
// shadow), its shapes from the badge sheet (cells 69-75, tools/badges_sheet.py). Sizes as the preview's on the iPhone 17
// (1206 px high), in proportion on any screen. Anything not as expected leaves the devs' own pop-up.
#define POP_REF 1206.0f
static int oPopState = -2, oPopElapsed, oPopIncoming, oPopCleanup, oPopDrawPos, oPopTitle, oPopDesc;
static int oTxHeight, oTxColor, oTxPos, oTxSize, oTxJustH, oTxJustV, oTxDrawSize, oTxString;
static int gPopId, gPopPrevState; static BOOL gPopLaid; static float gPopW[3], gPopH[3];
static NSString *gPopName, *gPopDesc; static float gPopLastH;
// a field of a struct property: its offset in the object (the struct's type is at +0xb8 of its property)
static int structFieldOff(void *cls, const char *prop, const char *field) {
    int o = poff(cls, prop);
    if (o < 0) return -1;
    for (uint8_t *st = cls; st; st = *(uint8_t **)(st + 0x68))
        for (uint8_t *f = *(uint8_t **)(st + 0x70); f; f = *(uint8_t **)(f + 0x60))
            if (!strcmp(ibfix_objname(f).UTF8String, prop)) {
                void *type = *(void **)(f + 0xb8); int i = type ? propertyOffset(type, field) : -1;
                return i < 0 ? -1 : o + i;
            }
    return -1;
}
static BOOL achPopReady(uint8_t *hud) {
    if (oPopState == -1) return NO;
    if (oPopState == -2) {
        void *cls = CLS(hud);
        oPopState = structFieldOff(cls, "Achievement", "State"); oPopElapsed = structFieldOff(cls, "Achievement", "ElapsedTime");
        oPopIncoming = structFieldOff(cls, "Achievement", "IncomingTime"); oPopCleanup = structFieldOff(cls, "Achievement", "CleanupTime");
        oPopDrawPos = structFieldOff(cls, "Achievement", "DrawPos"); oPopTitle = structFieldOff(cls, "Achievement", "DrawTitle");
        oPopDesc = structFieldOff(cls, "Achievement", "DrawDesc");
        if (oPopState < 0 || oPopElapsed < 0 || oPopIncoming < 0 || oPopCleanup < 0 || oPopDrawPos < 0 || oPopTitle < 0 || oPopDesc < 0) {
            LOG(@"achievement pop-up OFF: the HUD's Achievement not as expected (the devs' own pop-up stays)"); oPopState = -1; return NO;
        }
    }
    return YES;
}
static BOOL achPopTextReady(uint8_t *t) {
    static void *cls; static BOOL ok;
    if (cls == CLS(t)) return ok;
    cls = CLS(t);
    oTxHeight = poff(cls, "TextHeight"); oTxColor = poff(cls, "TextColor"); oTxPos = poff(cls, "BoundingBoxPos");
    oTxSize = poff(cls, "BoundingBoxSize"); oTxJustH = poff(cls, "JustifyHorz"); oTxJustV = poff(cls, "JustifyVert");
    oTxDrawSize = poff(cls, "DrawSize"); oTxString = poff(cls, "TextString");
    ok = oTxHeight > 0 && oTxColor > 0 && oTxPos > 0 && oTxSize > 0 && oTxJustH > 0 && oTxJustV > 0 && oTxDrawSize > 0 && oTxString > 0;
    if (!ok) LOG(@"achievement pop-up: its text not as expected (the devs' own pop-up stays)");
    return ok;
}
// one line through a SwordDrawText: set up at (x, y), h px high, left and top justified; measured (returns its width) or drawn
static float achPopLine(uint8_t *t, NSString *str, float x, float y, float h, const uint8_t rgb[3], uint8_t *canvas, float alpha) {
    if (![fstrText(t + oTxString) isEqualToString:str]) setText(t, str.UTF8String);
    boolSet(t, "bPixelsAreScaled", YES); boolSet(t, "bMultiLine", NO);
    float *pos = (float *)(t + oTxPos), *size = (float *)(t + oTxSize);
    pos[0] = x; pos[1] = y; size[0] = 4000; size[1] = h;
    *(float *)(t + oTxHeight) = h;
    t[oTxJustH] = 1; t[oTxJustV] = 1;                             // left, top
    uint8_t *c = t + oTxColor; c[0] = rgb[2]; c[1] = rgb[1]; c[2] = rgb[0]; c[3] = 255;   // a Color: B G R A
    boolSet(t, "bDirty", YES);
    if (alpha < 0) {                                              // measure: the text's own layout
        uint8_t *f = findFunction(t, "UpdateDrawData"); int oC = f ? propertyOffset(f, "Canvas") : -1;
        if (oC < 0 || *(uint16_t *)(f + 0xe2) > 32) return 0;
        uint8_t parms[32] = {0}; *(void **)(parms + oC) = canvas; processEvent(t, f, parms);
        gPopLastH = ((float *)(t + oTxDrawSize))[1];
        return *(float *)(t + oTxDrawSize);
    }
    uint8_t *r = findFunction(t, "Render");
    int oC = r ? propertyOffset(r, "Canvas") : -1, oA = r ? propertyOffset(r, "AlphaVal") : -1;
    int oX = r ? propertyOffset(r, "OffsetX") : -1, oY = r ? propertyOffset(r, "OffsetY") : -1;
    if (oC < 0 || oA < 0 || oX < 0 || oY < 0 || *(uint16_t *)(r + 0xe2) > 32) return 0;
    uint8_t parms[32] = {0}; *(void **)(parms + oC) = canvas; *(float *)(parms + oA) = alpha;
    processEvent(t, r, parms);
    return 0;
}
static void popPiece(uint8_t *canvas, int cell, float x, float y, float w, float h, const float col[4], BOOL inset) {
    float u = (cell % 10) * BADGE_CELL + BADGE_PAD, v = (cell / 10) * BADGE_CELL + BADGE_PAD;
    menuPiece(canvas, gBadgeTex, x, y, w, h, u + (inset ? 2 : 0), v, BADGE_PX - (inset ? 4 : 0), BADGE_PX, col, 2);
}
static void achPopBefore(uint8_t *hud) {
    if (!achPopReady(hud)) return;
    uint8_t *canvas = objAt(hud, "Canvas");
    if (!gBadgeTex) badgesMake();                                 // the badges' picture, for the pop-up's badge
    if (!gBadgeUp && canvas) { badgeDraw(canvas, 0, 0, 0, 2, 0.004f); return; }   // (a faint speck until it's up)
    if (hud[oPopState] == 0) return;
    float *dp = (float *)(hud + oPopDrawPos); dp[0] = -20000; dp[1] = -20000;    // the devs' strip off the screen
    *(float *)(hud + oPopIncoming) = 0.35f;                       // B's entrance
}
static void achPopAfter(uint8_t *hud) {
    if (oPopState < 0 || !gBadgeUp) return;
    uint8_t state = hud[oPopState], *canvas = objAt(hud, "Canvas");
    uint8_t *title = *(uint8_t **)(hud + oPopTitle), *desc = *(uint8_t **)(hud + oPopDesc);
    if (state == 0 || !canvas || !title || !desc || !achPopTextReady(title)) { gPopPrevState = state; return; }
    if (state >= 2 && gPopPrevState < 2) {                        // a new one: the devs have just set its name and description
        gPopName = fstrText(title + oTxString); gPopDesc = fstrText(desc + oTxString); gPopId = 0; gPopLaid = NO;
        for (int i = 1; i <= 64 && gPopName; i++) if ([gPopName isEqualToString:@(kAch[i].name)]) gPopId = i;
        LOG(@"achievement pop-up: %@ (%d) shown as ACHIEVEMENT UNLOCKED", gPopName, gPopId);
    }
    gPopPrevState = state;
    if (!gPopName || !gPopDesc) return;
    float sx = 0, sy = 0;
    if (!canvasSize(canvas, &sx, &sy) || sy <= 0) return;
    float k = sy / POP_REF, el = *(float *)(hud + oPopElapsed);
    float inc = fmaxf(*(float *)(hud + oPopIncoming), 0.01f), clean = fmaxf(*(float *)(hud + oPopCleanup), 0.01f);
    float t = state == 2 ? fminf(el / inc, 1) : 1;
    float a = state == 2 ? t * t : state == 3 ? 1 : 1 - powf(fminf(el / clean, 1), 4);
    if (a <= 0.001f) return;
    static const uint8_t kGold[3] = { 240, 196, 92 }, kWhite[3] = { 255, 255, 255 }, kOrange[3] = { 247, 148, 46 };
    // sizes: the game draws its capitals to the edges of each line's box and its g, j, p, q and y below it (the menu
    // font's deepest, 10/32 of a capital), so the name and the description get that room under their boxes, and the
    // lines are stacked with clear gaps, the stack centred in the banner; the heading as the preview's (FIXES.md 109)
    float hH = 40 * k, hN = 82 * k, hD = 50 * k, g1 = 18 * k, g2 = 12 * k, dN = hN * 10 / 32, dD = hD * 10 / 32;
    if (!gPopLaid) {
        gPopW[0] = achPopLine(title, @"ACHIEVEMENT UNLOCKED", 0, 0, hH, kGold, canvas, -1); gPopH[0] = fmaxf(gPopLastH, hH);
        gPopW[1] = achPopLine(title, gPopName, 0, 0, hN, kWhite, canvas, -1); gPopH[1] = fmaxf(gPopLastH, hN) + dN;
        gPopW[2] = achPopLine(desc, gPopDesc, 0, 0, hD, kOrange, canvas, -1); gPopH[2] = fmaxf(gPopLastH, hD) + dD;
        gPopLaid = YES;
        LOG(@"achievement pop-up: laid out (lines %.0f, %.0f, %.0f px wide, %.0f, %.0f, %.0f high, on a %.0f x %.0f canvas)",
            gPopW[0], gPopW[1], gPopW[2], gPopH[0], gPopH[1], gPopH[2], sx, sy);
    }
    // a banner too wide for the screen (the longest descriptions on the iPad's squarer screen) is drawn smaller, all of
    // it, so its badge and text keep 150 px (of 1206) clear of each edge (FIXES.md 109)
    float wMax = fmaxf(gPopW[0], fmaxf(gPopW[1], gPopW[2])), f = fminf(1, (sx - 300 * k) / (280 * k + wMax)), q = k * f;
    hH *= f; hN *= f; hD *= f; g1 *= f; g2 *= f;
    float H0 = gPopH[0] * f, H1 = gPopH[1] * f, H2 = gPopH[2] * f, bs = 230 * q, gap = 50 * q, margin = 240 * q;
    float ph = fmaxf(290 * q, H0 + g1 + H1 + g2 + H2 + 70 * q);   // room for the stack and the gold lines
    float cw = bs + gap + wMax * f;
    float pw = fminf(cw + 2 * margin, sx), x0 = (sx - pw) / 2, bx = (sx - cw) / 2;
    float y0 = 135 * k - (state == 2 ? (1 - t) * 24 * k : 0), by = y0 + (ph - bs) / 2;
    float m = fminf(margin, (pw - cw) / 2);                      // the band's ends fade only outside the badge and text
    const float band[4] = { 0, 0, 0, 0.84f * a }, gold[4] = { 240 / 255.f, 196 / 255.f, 92 / 255.f, 0.9f * a };
    popPiece(canvas, 72, x0, y0, m, ph, band, YES); popPiece(canvas, 71, x0 + m, y0, pw - 2 * m, ph, band, YES);
    popPiece(canvas, 73, x0 + pw - m, y0, m, ph, band, YES);
    for (int i = 0; i < 2; i++) {                                 // the gold lines, above and below
        float ly = i == 0 ? y0 + 4 * q : y0 + ph - 7 * q, lh = fmaxf(3 * q, 2);
        popPiece(canvas, 70, x0, ly, m, lh, gold, YES);
        popPiece(canvas, 75, x0 + m, ly, pw - 2 * m, lh, gold, YES);   // plain white, tinted (a badge's middle is dark)
        popPiece(canvas, 74, x0 + pw - m, ly, m, lh, gold, YES);
    }
    const float glowc[4] = { 240 / 255.f, 196 / 255.f, 92 / 255.f, 0.7f * a };
    float r = 230 * q;
    popPiece(canvas, 69, bx + bs / 2 - r, by + bs / 2 - r, 2 * r, 2 * r, glowc, NO);
    if (gPopId) badgeDraw(canvas, gPopId - 1, bx, by, bs, a);
    float tx = bx + bs + gap, stack = H0 + g1 + H1 + g2 + H2, ty = y0 + (ph - stack) / 2;
    achPopLine(title, @"ACHIEVEMENT UNLOCKED", tx, ty, hH, kGold, canvas, a);
    achPopLine(title, gPopName, tx, ty + H0 + g1, hN, kWhite, canvas, a);
    achPopLine(desc, gPopDesc, tx, ty + H0 + g1 + H1 + g2, hD, kOrange, canvas, a);
}

// ---- 4ak. Every box's message room as on the devs' screens; our boxes' messages fitted to it (6 November 2026; FIXES.md 101) ----
// SwordGenericPopup.InitMenuScene gives the message the room from TextTop = 2 BorderY + TitleText.TextHeight x RatioY
// down to BorderY above the buttons, its lines centred in it; but TextHeight is already x RatioY (screen height / 480), so
// the title counts twice, and on taller screens the room shrank until messages ran over the buttons
// (tools/achievements_box_fit.py). Restored for every box the game opens (each SwordGenericPopup: OK, Yes/No...): TextTop
// with the title x 4/3, as on the devs' 960 x 640 screens; a box whose message isn't where that formula puts it (a box
// without a title) is left alone.
static void boxRoom(uint8_t *scene) {
    static int warned, said;
    void *cls = scene ? CLS(scene) : NULL;
    int oBY = cls ? poff(cls, "BorderY") : -1;
    if (oBY <= 0 || !gLastCanvas) return;
    uint8_t *msg = objAt(scene, "MessageText"), *title = msg ? objAt(scene, "TitleText") : NULL;
    if (!msg || !title) return;
    int oP = poff(CLS(msg), "BoundingBoxPos"), oS = poff(CLS(msg), "BoundingBoxSize");
    int oTH = poff(CLS(title), "TextHeight");
    float sx = 0, sy = 0;
    if (oP <= 0 || oS <= 0 || oTH <= 0 || !canvasSize(gLastCanvas, &sx, &sy) || sy <= 0) return;
    float by = *(float *)(scene + oBY), th = *(float *)(title + oTH);
    float oldTop = 2 * by + th * sy / 480, newTop = 2 * by + th * 4 / 3;
    float *py = (float *)(msg + oP + 4), *hy = (float *)(msg + oS + 4);
    if (fabsf(*py - newTop) < 1) return;                          // done already
    if (fabsf(*py - oldTop) > 2) {
        if (warned++ < 3) LOG(@"boxes: %@'s message at %.0f, not at %.0f: left as the game has it", ibfix_objname(cls), *py, oldTop);
        return;
    }
    *hy += *py - newTop; *py = newTop;
    boolSet(msg, "bDirty", YES);
    if (said++ < 4) LOG(@"boxes: %@'s message room from %.0f (the game's %.0f) down %.0f px", ibfix_objname(cls), newTop, oldTop, *hy);
}
// Our achievement boxes then fitted, as the devs fitted their one long message (SwordGenericPopup.Opened,
// "GameWonPlayPlus": its room a quarter of the screen wider, its text 0.8 the height): wider in two steps first, then 0.9
// smaller in steps down to 0.7, laid out each time by the text's own UpdateDrawData until its lines fit the room.
static void achBoxFit(uint8_t *scene) {
    uint8_t *msg = objAt(scene, "MessageText");
    void *mc = msg ? CLS(msg) : NULL;
    uint8_t *f = msg ? findFunction(msg, "UpdateDrawData") : NULL;
    int oP = mc ? poff(mc, "BoundingBoxPos") : -1, oS = mc ? poff(mc, "BoundingBoxSize") : -1;
    int oD = mc ? poff(mc, "DrawSize") : -1, oTH = mc ? poff(mc, "TextHeight") : -1, oC = f ? propertyOffset(f, "Canvas") : -1;
    float sx = 0, sy = 0;
    if (oP <= 0 || oS <= 0 || oD <= 0 || oTH <= 0 || oC < 0 || *(uint16_t *)(f + 0xe2) > 32 || !canvasSize(gLastCanvas, &sx, &sy)) {
        LOG(@"achievements: the box's message not as expected: not fitted"); return;
    }
    float th0 = *(float *)(msg + oTH), adj = 0, need = 0, room = 0; int step;
    for (step = 0; step < 12; step++) {
        boolSet(msg, "bDirty", YES);
        uint8_t parms[32] = {0}; *(void **)(parms + oC) = gLastCanvas;
        processEvent(msg, f, parms);
        need = *(float *)(msg + oD + 4); room = *(float *)(msg + oS + 4);
        if (need <= room) break;
        if (adj < 0.25f * sx - 1) { float a = 0.125f * sx; *(float *)(msg + oP) -= a / 2; *(float *)(msg + oS) += a; adj += a; }
        else if (*(float *)(msg + oTH) > th0 * 0.71f) *(float *)(msg + oTH) *= 0.9f;
        else break;
    }
    boolSet(msg, "bDirty", YES);
    LOG(@"achievements: box %d's message %@ (%d steps: %.0f px wider, text at %.0f%%; %.0f of %.0f px high)", gAchBoxId,
        need <= room ? @"fits" : @"STILL TOO TALL", step, adj, 100 * *(float *)(msg + oTH) / th0, need, room);
}
// 4ak: our box is known by its title, our achievement's name, not by being drawn recently (a screenshot on the iPad sends
// the game to the background for about 3 s). Only a box with another title (a later box at the same address) isn't ours.
static BOOL achBoxIsOurs(void *scene) {
    uint8_t *title = gAchBoxId > 0 && gAchBoxId <= 64 ? objAt(scene, "TitleText") : NULL;
    int o = title ? poff(CLS(title), "TextString") : -1;
    NSString *s = o > 0 ? fstrText(title + o) : nil;
    return s && [s isEqualToString:[@(kAch[gAchBoxId].name) uppercaseString]];
}
// the box: noted at its first draw after a tap opened it; its title moved right once; its badge drawn after it
static void achBoxBefore(void *scene) {
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (gAchBox && scene == gAchBox && !achBoxIsOurs(scene)) { gAchBox = NULL; gAchBoxId = 0; }   // another box now: not ours
    if (!gAchBox && gAchBoxId && t - gAchBoxAt < 2 && isClass(scene, "SwordOkPopup") && achBoxIsOurs(scene)) {
        gAchBox = scene; gAchBoxShifted = NO;
        // 4ak: no dark panel behind our box (by choice, FIXES.md 101): SwordPopupScene.RenderScene draws B_Info's strip (972,635,
        // 20 x 389) tinted black across the box, fading over its outer fifths, so long lines ran into its faded sides.
        // The game's other boxes keep theirs.
        int oBT = poff(CLS(scene), "BackgroundTexture");
        if (oBT > 0) *(void **)((uint8_t *)scene + oBT) = NULL;
        static int said; if (!said++) LOG(@"achievements: the box's dark panel %@", oBT > 0 ? @"left out" : @"NOT FOUND (still drawn)");
    }
    if (scene != gAchBox || !gAchBoxId) return;
    gAchBoxSeen = t;
    // 4ak: everything behind our box darkened evenly (by choice, FIXES.md 101), drawn just before the box, whose own RenderScene then
    // dims the screen with black at 150 of 255: black at 0.6, fading in with the box, so a sixth of the brightness behind
    // is left, about what the panel's middle left. Drawn with the badge sheet's opaque middle (cell 0, around 100,100).
    float dsx = 0, dsy = 0;
    if (gBadgeUp && gLastCanvas && canvasSize(gLastCanvas, &dsx, &dsy)) {
        float op = numProp(scene, "Opacity", 1);
        const float dark[4] = { 0, 0, 0, 0.6f * fminf(1, fmaxf(0, op)) };
        menuPiece(gLastCanvas, gBadgeTex, 0, 0, dsx, dsy, 100, 100, 4, 4, dark, 2);
    }
    if (gAchBoxShifted || !gLastCanvas) return;
    gAchBoxShifted = YES;
    uint8_t *title = objAt(scene, "TitleText");
    int oP = title ? poff(CLS(title), "BoundingBoxPos") : -1;
    if (oP <= 0) { LOG(@"badges: the box's title not found; its badge left out"); gAchBoxId = 0; return; }
    float clipX = 0, clipY = 0;
    if (!canvasSize(gLastCanvas, &clipX, &clipY)) return;
    BOOL scaled = NO; boolGet(title, "bPixelsAreScaled", &scaled);
    float bs = roundf(clipY * 0.146f), gap = roundf(clipY * 0.036f), ratio = scaled || clipX <= 0 ? 1 : clipX / 960;
    *(float *)(title + oP) += (bs + gap) / 2 / ratio;            // the name right by half the badge and gap
    boolSet(title, "bDirty", YES);
    achBoxFit(scene);                                             // 4ak: its message clear of the tick button
}
static void achBoxAfter(void *scene) {
    if (!gAchBox || scene != gAchBox || !gAchBoxId || !gLastCanvas) return;
    uint8_t *title = objAt(scene, "TitleText");
    int oP = title ? poff(CLS(title), "DrawPos") : -1, oS = title ? poff(CLS(title), "DrawSize") : -1;
    if (oP <= 0 || oS <= 0) return;
    float clipX = 0, clipY = 0;
    if (!canvasSize(gLastCanvas, &clipX, &clipY)) return;
    float bs = roundf(clipY * 0.146f), gap = roundf(clipY * 0.036f);
    float px = numProp(scene, "Left", 0) + *(float *)(title + oP), py = numProp(scene, "Top", 0) + *(float *)(title + oP + 4);
    float h = *(float *)(title + oS + 4), alpha = numProp(scene, "Opacity", 1);
    badgeDraw(gLastCanvas, gAchBoxId - 1, px - gap - bs, py + h / 2 - bs / 2, bs, alpha);
    static int said; if (!said && gBadgeUp) { said = 1; LOG(@"badges: drawn in the box (badge %d, %.0f px, beside the name at %.0f,%.0f)", gAchBoxId, bs, px, py); }
}

// ---- 4af. The pause menu's ACHIEVEMENTS: the 64 in a list, question marks until earned (5 November 2026; FIXES.md 95) ----
// The devs' button (Pause_Achievements) opened Game Center's list and is greyed out without it:
// SwordPauseMenuScene.RenderScene sets AchievementsBttn.bIsActive from Game Center's sign-in each frame, just before
// drawing, so it's lit again at its own draw (its RenderObject call). Its tap (OnTouchMenuObject, through the menu
// screens' ProcessEvent, my_scenePE, as the COPY button's) opens the game's own Options screen as the pause menu does, in
// achievements mode: when its list is made (InitMenuObject) the options rows are taken out and 64 button rows put in.
// One unused devs' handler (OnUpdateDeleteSave) serves every row: a tap on an earned one opens the game's own message
// box (SwordPC.GenericPopupMessage) with its name, how it's earned and the day it was.
static int gAchMenuPending;                                     // set while the pause menu opens the list in this mode
static void *gAchRowFn;
static NSString *achCaption(int id) {
    if (achGone(id)) return [NSString stringWithFormat:@"%d.   %s   (unavailable)", id, kAch[id].name];   // 4aj
    if (!ibfix_achievement_earned(id)) return [NSString stringWithFormat:@"%d.   ? ? ? ? ? ? ? ?", id];
    return [NSString stringWithFormat:@"%d.   %s", id, kAch[id].name];
}
static int achTotal(void) { int n = 60; for (int i = 61; i <= 64; i++) n += !achGone(i); return n; }   // 4aj
static int achEarnedCount(void) { int n = 0; for (int i = 1; i <= 64; i++) n += ibfix_achievement_earned(i); return n; }
static void my_achRow(void *self, void *stack, void *result) {
    BOOL bInit;
    void *item = handlerArgs(stack, gAchRowFn, &bInit);
    if (!item || bInit) return;
    int oItems = propertyOffset(CLS(self), "Items"), id = 0;
    struct { void **data; int num, max; } *items = oItems > 0 ? (void *)((uint8_t *)self + oItems) : NULL;
    for (int i = 0; items && i < items->num; i++) if (items->data[i] == item) { id = i + 1; break; }
    if (id < 1 || id > 64) return;
    if (!ibfix_achievement_earned(id)) { LOG(@"achievements: row %d tapped, not earned yet", id); return; }
    // Earned in play: its day. Granted quietly by the devs' re-check (the save already showed it, earned before the
    // record was kept): the day achievements came back, said as such.
    NSObject *rec = achGot()[[NSString stringWithFormat:@"%d", id]];
    NSDictionary *d = [rec isKindOfClass:[NSDictionary class]] ? (NSDictionary *)rec : nil;
    NSDate *when = [rec isKindOfClass:[NSDate class]] ? (NSDate *)rec : d[@"date"];
    BOOL quiet = [d[@"quiet"] boolValue];
    NSDateFormatter *df = [NSDateFormatter new]; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"]; df.dateFormat = @"d MMMM yyyy";
    NSString *day = [when isKindOfClass:[NSDate class]] ? [df stringFromDate:when] : nil;
    NSString *msg = quiet ? [NSString stringWithFormat:@"%s\n\nAlready earned when achievements came back%@.", kAch[id].desc, day ? [@" on " stringByAppendingString:day] : @""]
                          : [NSString stringWithFormat:@"%s\n\nEarned %@.", kAch[id].desc, day ?: @"before this list was kept"];
    uint8_t *pc = objAt(self, "SwordPC"), *f = pc ? findFunction(pc, "GenericPopupMessage") : NULL;
    int oT = f ? propertyOffset(f, "Title") : -1, oM = f ? propertyOffset(f, "Message") : -1;
    if (oT < 0 || oM < 0 || *(uint16_t *)(f + 0xe2) > 64) { LOG(@"achievements: the message box not found"); return; }
    uint8_t parms[64] = {0};
    *(FStr *)(parms + oT) = makeFString([[NSString stringWithUTF8String:kAch[id].name] uppercaseString].UTF8String);
    *(FStr *)(parms + oM) = makeFString(msg.UTF8String);
    gAchBoxId = id; gAchBox = NULL; gAchBoxAt = CFAbsoluteTimeGetCurrent();   // 4ai: its badge beside the name
    processEvent(pc, f, parms);
    LOG(@"achievements: row %d tapped: %s shown", id, kAch[id].name);
}
// A row not earned yet, as in the approved preview: its writing grey (the caption's SetTextColor: NewColor, DropColor, each
// a Color, B G R A) and its button inactive, the game's own dimmed look, which also takes no tap.
static void achRowLocked(uint8_t *item, uint8_t *caption, BOOL gone) {
    uint8_t *f = findFunction(caption, "SetTextColor");
    int oN = f ? propertyOffset(f, "NewColor") : -1, oD = f ? propertyOffset(f, "DropColor") : -1;
    if (oN >= 0 && *(uint16_t *)(f + 0xe2) <= 16) {
        uint8_t parms[16] = {0};
        // grey: the engine turns a Color into light (about the 2.2 power) before drawing, so 200 comes out about mid-grey
        parms[oN] = parms[oN + 1] = parms[oN + 2] = 200; parms[oN + 3] = 255;
        if (oD >= 0) parms[oD + 3] = 255;                                                // its shadow black, as before
        processEvent(caption, f, parms);
    }
    // the row's button is the first of the row's own MenuObjects (SwordOptionListItem.RenderItem draws them; there is no
    // "Button" property)
    uint8_t *button = NULL;
    int moOff = propertyOffset(CLS(item), "MenuObjects");
    if (moOff > 0) {
        struct { void **data; int num, max; } *mo = (void *)(item + moOff);
        for (int i = 0; i < mo->num && !button; i++) { BOOL on = NO; if (mo->data[i] && boolGet(mo->data[i], "bIsActive", &on) && on) button = mo->data[i]; }
    }
    if (button) boolSet(button, "bIsActive", NO);
    if (button && gone) setFloat(button, "Opacity", 0);                                // 4aj: no button at all
    static BOOL said; if (!said) { said = YES; LOG(@"achievements list: rows not earned greyed (SetTextColor %@, button %@)", oN >= 0 ? @"found" : @"NOT FOUND", button ? @"found" : @"NOT FOUND"); }
}
// The options list being made in achievements mode (from the InitMenuObject hook, after the game's own rows).
static BOOL achFillList(uint8_t *list) {
    if (!gAchMenuPending) return NO;
    gAchMenuPending = 0;
    uint8_t *addOption = findFunction(list, "AddOption");
    int itemsOff = propertyOffset(CLS(list), "Items");
    if (!addOption || *(uint16_t *)(addOption + 0xe2) != 0x30 || itemsOff <= 0 || !handlerShapeOK(list, "OnUpdateDeleteSave")) { LOG(@"achievements list OFF: options list not as expected"); return NO; }
    struct { void **data; int num, max; } *items = (void *)(list + itemsOff);
    void *buttonClass = NULL;
    for (int i = 0; i < items->num && !buttonClass; i++) {
        void *cls = CLS(items->data[i]);
        if ([ibfix_objname(cls) isEqualToString:@"SwordOptionListButton"]) buttonClass = cls;
    }
    if (!buttonClass || !pointHandler(list, "OnUpdateDeleteSave", (void *)my_achRow, &gAchRowFn)) { LOG(@"achievements list OFF: no button row, or the handler not replaced"); return NO; }
    items->num = 0;                                             // the options rows out (the engine's objects, freed by it)
    badgesMake();                                               // 4ai: the badges' picture (the first time)
    memset(gAchRows, 0, sizeof gAchRows);
    // 4ai: each caption moved right by the badge (82.5% of a row's 110 units of height) and 40 px, in the caption's 960 units
    float bcx = 0, bcy = 0; canvasSize(gLastCanvas, &bcx, &bcy);
    float capShift = bcx > 0 && bcy > 0 ? (roundf(110 * bcy / 640 * 0.825f) + 40) * 960 / bcx : 0;
    for (int id = 1; id <= 64; id++) {
        struct { void *cls; void *delObj; int32_t delName, delNum; FStr caption; void *ret; } parms =
            { buttonClass, list, nameIndex("OnUpdateDeleteSave"), 0, { NULL, 0, 0 }, NULL };
        processEvent(list, addOption, &parms);
        int capOff = parms.ret ? propertyOffset(CLS(parms.ret), "Caption") : -1;
        void *caption = capOff > 0 ? *(void **)((uint8_t *)parms.ret + capOff) : NULL;
        if (caption) setText(caption, achCaption(id).UTF8String);
        gAchRows[id] = parms.ret;
        int oBB = caption && gBadgeTex ? poff(CLS(caption), "BoundingBoxPos") : -1;
        if (oBB > 0 && capShift > 0) { *(float *)((uint8_t *)caption + oBB) += capShift; boolSet(caption, "bDirty", YES); }
        if (caption && parms.ret && !ibfix_achievement_earned(id)) achRowLocked(parms.ret, caption, achGone(id));
        // 4aj: 61-64's writing all one size. The game shrinks a caption wider than its room (SwordDrawText.UpdateDrawData:
        // the smaller of the room's width and height over the text's); each room is 50 units wider (the button's place,
        // hidden) and in proportion to its own writing's width in the game's font (61 the widest;
        // tools/achievements_box_fit.py), so any shrink is the same for all four.
        int oBS = caption && achGone(id) ? poff(CLS(caption), "BoundingBoxSize") : -1;
        if (oBS > 0) {
            static const float kGoneW[4] = { 1.0f, 0.7696f, 0.9162f, 0.9553f };   // 61-64's writing over 61's
            float *bw = (float *)((uint8_t *)caption + oBS); *bw = (*bw + 50) * kGoneW[id - 61];
            boolSet(caption, "bDirty", YES);
        }
    }
    LOG(@"achievements list: 64 rows (%d earned of %d; %d of 61-64 no longer available)", achEarnedCount(), achTotal(), 64 - achTotal());
    return YES;
}
static void achOpenMenu(uint8_t *pause) {
    uint8_t *open = findFunction(pause, "OpenChildMenu");
    int oMenu = open ? propertyOffset(open, "Menu") : -1, oMode = open ? propertyOffset(open, "Mode") : -1, oRet = open ? propertyOffset(open, "ReturnValue") : -1;
    if (oMenu < 0 || oMode < 0 || *(uint16_t *)(open + 0xe2) > 64) { LOG(@"achievements: OpenChildMenu not as expected"); return; }
    uint8_t *ds = findFunction(pause, "DisableSubtitles");
    if (ds && *(uint16_t *)(ds + 0xe2) <= 64) { uint8_t p0[64] = {0}; processEvent(pause, ds, p0); }
    uint8_t parms[64] = {0};
    *(FStr *)(parms + oMenu) = makeFString("SwordGame.SwordUserOptionsScene");
    *(FStr *)(parms + oMode) = makeFString("");
    gAchMenuPending = 1;
    processEvent(pause, open, parms);
    gAchMenuPending = 0;
    uint8_t *child = oRet >= 0 ? *(uint8_t **)(parms + oRet) : objAt(pause, "ChildMenu");
    uint8_t *title = child ? objAt(child, "ScreenTitle") : NULL;
    if (title) setText(title, [NSString stringWithFormat:@"ACHIEVEMENTS  %d / %d", achEarnedCount(), achTotal()].UTF8String);
    uint8_t *pc = objAt(pause, "SwordPC"), *player = pc ? objAt(pc, "Player") : NULL, *vc = player ? objAt(player, "ViewportClient") : NULL;
    if (vc) boolSet(vc, "bDisableWorldRendering", YES);
    LOG(@"achievements: the list opened from the pause menu (%@)", child ? ibfix_objname(child) : @"no screen");
}
// The pause menu's button lit at its own draw (the menu greys it each frame first, then draws it); gAchBttn is the
// pause menu's AchievementsBttn, noted as its RenderScene starts.
static void achButtonDraw(uint8_t *button) {
    static BOOL said;
    boolSet(button, "bIsActive", YES);
    if (!said) { said = YES; LOG(@"achievements: the pause menu's ACHIEVEMENTS button lit"); }
}

// ---- 4ag. No Facebook button on the pause menu (5 November 2026; FIXES.md 96) ----
// The pause menu's IB3Upsell (a Facebook logo at the bottom right) opened a box about Infinity Blade III on Facebook; its
// neighbours BookUpsell and IB2Upsell (bottom left and middle) draw nothing today but would still take a tap. The devs'
// own switches, bShowIB3Upsell, bShowIB2Upsell and bShowBookUpsell (true in the game's settings), are set off before the
// menu sets itself up (InitMenuScene), so its own code hides each button and takes its taps away.
static void noUpsells(uint8_t *pause) {
    static BOOL said;
    BOOL a = boolSet(pause, "bShowIB3Upsell", NO), b = boolSet(pause, "bShowIB2Upsell", NO), c = boolSet(pause, "bShowBookUpsell", NO);
    if (!said) { said = YES; LOG(@"pause menu: the Facebook button (IB3Upsell) %@, the book and IB2 ones %@", a ? @"off" : @"NOT FOUND", b && c ? @"off" : @"NOT FOUND"); }
}

// ---- 4ah. No Live Text button on the films (5 November 2026; FIXES.md 99) ----
// The game plays its films with the old MPMoviePlayerController, which today's iOS runs on AVPlayerViewController;
// since iOS 16 that player looks for writing in any paused or ended frame (allowsVideoFrameAnalysis, on by default) and
// puts its Live Text button over the picture's bottom right, so it came up beside Start on the start-up film's last
// frame, the logo. Off on every AVPlayerViewController the game makes: each as it appears (viewWillAppear:, hooked on
// that class alone), and any already on screen at each of the film's notifications (MediaPlayer loads AVKit only when a
// film starts).
static IMP gOrigPlayerWillAppear;
static void noFrameAnalysis(UIViewController *vc, const char *when) {
    SEL set = NSSelectorFromString(@"setAllowsVideoFrameAnalysis:"), get = NSSelectorFromString(@"allowsVideoFrameAnalysis");
    if (![vc respondsToSelector:set] || ![vc respondsToSelector:get]) {
        static BOOL said; if (!said) { said = YES; LOG(@"films: this iOS's player has no frame analysis switch (no Live Text there)"); }
        return;
    }
    if (!((BOOL (*)(id, SEL))objc_msgSend)(vc, get)) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(vc, set, NO);
    BOOL now = ((BOOL (*)(id, SEL))objc_msgSend)(vc, get);
    static int logged; if (logged < 6) { logged++; LOG(@"films: Live Text %@ on a film player (%s)", now ? @"STILL ON" : @"switched off", when); }
}
static void my_playerWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    noFrameAnalysis(self, "as it appeared");
    ((void (*)(id, SEL, BOOL))gOrigPlayerWillAppear)(self, _cmd, animated);
}
static void noLiveText(void) {
    Class c = NSClassFromString(@"AVPlayerViewController");
    if (!c || ![NSThread isMainThread]) return;
    static BOOL hooked;
    if (!hooked) {
        hooked = YES;
        gOrigPlayerWillAppear = hookMethod(c, @selector(viewWillAppear:), (IMP)my_playerWillAppear);
        LOG(@"films: no Live Text %@", gOrigPlayerWillAppear ? @"ON (every film player as it appears)" : @"OFF (viewWillAppear: not found)");
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {    // any player already there: by its controllers and views
        NSMutableArray *vcs = [NSMutableArray array]; if (w.rootViewController) [vcs addObject:w.rootViewController];
        while (vcs.count) {
            UIViewController *vc = vcs.lastObject; [vcs removeLastObject];
            if ([vc isKindOfClass:c]) noFrameAnalysis(vc, "on screen");
            [vcs addObjectsFromArray:vc.childViewControllers];
            if (vc.presentedViewController) [vcs addObject:vc.presentedViewController];
        }
        NSMutableArray *views = [NSMutableArray arrayWithObject:w];
        while (views.count) {
            UIView *v = views.lastObject; [views removeLastObject];
            if ([v.nextResponder isKindOfClass:c]) noFrameAnalysis((UIViewController *)v.nextResponder, "on screen");
            [views addObjectsFromArray:v.subviews];
        }
    }
}

// ---- 4k. A skipped ending stays skipped (FIXES.md 50) ----
// After the God King's death, the skip's "Yes" (SwordPC.OnSkipFinalCutsceneSequence) fades to black and finishes the
// battle (SwordBossSpawnPoint.OnFinishBossBattle), but never stops the ending's film, which went on out of sight: his
// lines played over the black end screen, and in time "SCENE 7" would open the credits and "SCENE 7A" finish the battle
// again. So when OnFinishBossBattle is called from OnSkipFinalCutsceneSequence (the caller's frame, Node at +0x18), every
// film playing in that boss's arena (the outermost of SpawnPoint.Helper, as in 4f) is held where it is (PlayRate 0: no
// more keys, events or end) and its sound tracks' sounds are stopped (InterpTrackInstSound.PlayAudioComp.Stop()). The
// level is reloaded with the next bloodline, so nothing is left changed.
static void stopSkippedEnding(uint8_t *sp) {
    int oH = poff(CLS(sp), "Helper");
    uint8_t *arena = oH >= 0 ? *(uint8_t **)(sp + oH) : NULL;
    while (arena && *(uint8_t **)(arena + 0x40)) arena = *(uint8_t **)(arena + 0x40);
    if (!arena) { LOG(@"ending skipped: no arena found for %@: films left as they were", ibfix_objname(sp)); return; }
    int held = 0;
    for (int f = 0; f < gNumFilms; f++) {
        Film *fl = &gFilms[f];
        if (!refLive(&fl->ref)) continue;
        uint8_t *film = fl->ref.obj, *top = film;
        int oGI = poff(fl->ref.cls, "GroupInst"), oPos = poff(fl->ref.cls, "Position"), oRate = poff(fl->ref.cls, "PlayRate");
        struct { uint8_t **data; int num, max; } *gi = (void *)(film + oGI);
        if (oGI < 0 || oPos < 0 || oRate < 0 || gi->num <= 0 || gi->num > 64) continue;   // not playing
        while (*(uint8_t **)(top + 0x40)) top = *(uint8_t **)(top + 0x40);
        if (top != arena) continue;
        *(float *)(film + oRate) = 0;
        int stopped = 0;
        for (int g = 0; g < gi->num; g++) {
            GROUP_TRACKS(gi, g);
            for (int t = 0; t < ti->num && t < 256; t++) {
                uint8_t *tr = ti->data[t];
                int oA = tr ? poff(CLS(tr), "PlayAudioComp") : -1;
                uint8_t *comp = oA >= 0 ? *(uint8_t **)(tr + oA) : NULL;
                void *fn = comp ? findFunction(comp, "Stop") : NULL;
                if (fn) { uint8_t parms[16] = {0}; processEvent(comp, fn, parms); stopped++; }
            }
        }
        LOG(@"ending skipped: %@ of %@ held at %.2f s, %d sounds stopped (it would have gone on out of sight)", ibfix_objname(film),
            ibfix_objname(arena), *(float *)(film + oPos), stopped);
        held++;
    }
    if (!held) LOG(@"ending skipped: no film of %@ playing", ibfix_objname(arena));
}

#ifdef IBFIX_SNAPS
// Test builds: every effect a boss asks for (SwordPawn.PlayFX(index, ...), the God King's hand flames 39/40, sword 33, shield
// 37, the finishing stab 41/42; FIXES.md 48), with the game time, to tell a cue that never fired from an effect not seen;
// and for each effect it spawns on itself (EmitterPool.SpawnEmitterMeshAttachment), whether it was drawn within 0.6 s.
static int gBossFX = -1;                                        // the boss effect being played (inside its PlayFX)
typedef struct { ObjRef psc; int fx; float at; double due; } SpawnCheck;
static SpawnCheck gSpawnChecks[8]; static int gNumSpawnChecks;
static NSString *pscState(uint8_t *psc, float since) {
    void *c = CLS(psc);
    int oT = poff(c, "Template"), oO = poff(c, "Owner"), oL = poff(c, "LastRenderTime"), oS = poff(c, "Scale"), oE = poff(c, "EmitterInstances");
    float drawn = oL >= 0 ? *(float *)(psc + oL) : -1;
    return [NSString stringWithFormat:@"%@ (%@) on %@, scale %.2f, %d emitters, %@", ibfix_objname(psc), oT >= 0 ? ibfix_objname(*(void **)(psc + oT)) : @"?",
            oO >= 0 ? ibfix_objname(*(void **)(psc + oO)) : @"?", oS >= 0 ? *(float *)(psc + oS) : -1, oE >= 0 ? *(int *)(psc + oE + 8) : -1,
            drawn >= since ? [NSString stringWithFormat:@"drawn %.2f s after it started", drawn - since] : @"NOT DRAWN since it started"];
}
static void effectSpawned(void *psc, int fx) {
    float now = worldTime();
    if (!psc) { LOG(@"boss effect %d: the emitter pool gave nothing", fx); return; }
    LOG(@"boss effect %d spawned: %@", fx, pscState(psc, now));
    if (gNumSpawnChecks < 8)
        gSpawnChecks[gNumSpawnChecks++] = (SpawnCheck){ { psc, *(int *)((uint8_t *)psc + 0x38), CLS(psc) }, fx, now, CFAbsoluteTimeGetCurrent() + 0.6 };
}
static void spawnCheckTick(void) {
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < gNumSpawnChecks; ) {
        SpawnCheck *s = &gSpawnChecks[i];
        if (t < s->due) { i++; continue; }
        if (refLive(&s->psc)) LOG(@"boss effect %d after 0.6 s: %@", s->fx, pscState(s->psc.obj, s->at));
        else LOG(@"boss effect %d after 0.6 s: gone", s->fx);
        *s = gSpawnChecks[--gNumSpawnChecks];
    }
}
static void bossEffectAsked(void *pawn, int index) {
    void *cls = CLS(pawn);
    if (poff(cls, "StageTransitionHealth") < 0) return;          // bosses only
    BossStage st; BOOL ok = bossStage(pawn, &st);
    LOG(@"boss effect %d asked by %@ (game time %.2f, health %d)", index, ibfix_objname(pawn), ok ? st.now : worldTime(), ok ? st.health : -1);
}
static void titleLogoCheck(void) {                             // test builds: is the end screen's logo still loaded? (2c)
    static CFAbsoluteTime last; static int idx = -1; static void *cls;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (!gTitleLogo || t - last < 60) return;
    last = t;
    if (idx < 0) {                                             // (in the root set, so never freed; checked all the same)
        if (!isLiveObject(gTitleLogo)) { LOG(@"end screen logo: GONE"); return; }
        idx = *(int *)((uint8_t *)gTitleLogo + 0x38); cls = CLS(gTitleLogo);
    }
    ObjRef r = { gTitleLogo, idx, cls };
    LOG(@"end screen logo: %@", refLive(&r) && (*(uint64_t *)((uint8_t *)gTitleLogo + 0x10) & 0x4000) ? @"still in memory" : @"GONE");
}
static void objCheckRate(void) {                               // test builds: how many kernel reads the object checks make
    static CFAbsoluteTime since; static unsigned long from;    // (FIXES.md 90), logged once a minute
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (!since) { since = t; from = gObjChecks; return; }
    if (t - since < 60) return;
    LOG(@"object checks: %.0f a second, each one kernel read (about 0.5 us)", (double)(gObjChecks - from) / (t - since));
    since = t; from = gObjChecks;
}
#endif

static void my_execVirtualFunction(void *self, void *stack, void *result) {
    int name = *(int *)*(uint8_t **)((uint8_t *)stack + FFRAME_CODE);   // the operand: the function's FName
    if (gNameUpdateViewTarget == -2) gNameUpdateViewTarget = nameIndex("UpdateViewTarget");
    if (name == gNameUpdateViewTarget && self && isSwordCamera(self)) {
        uint8_t *arg = *(uint8_t **)((uint8_t *)stack + FFRAME_CODE) + 8;   // after the FName
        uint8_t *vt = NULL;
        if (arg[0] == 0x01) { uint8_t *prop = *(uint8_t **)(arg + 1); if (prop) vt = (uint8_t *)self + *(int *)(prop + 0x7c); }
        ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
#ifdef IBFIX_SNAPS
        gViewCamera = self;
#endif
        fixFilmMoves();
        savePointTick();
        heldStageTick();
        ffHeldTick();                                           // 4l
        lessonsTick();                                          // 4p
        godKingTick();                                          // 4q
        faunTick();                                             // 4s
        speechGapTick();                                        // 4t
        ffSpeechTick();                                         // 4w
        gateTick();                                             // 4u
        placesTick();                                           // 4x
        wellReturnTick();                                       // 4y
        lightFollowTick();                                      // 4z
        filmHapticsTick();                                      // 7d
        { static BOOL once; if (!once && gNatives) { once = YES; newLayoutChecked(); } }   // 4v: checked early, read-only
#ifdef IBFIX_SNAPS
        faunSnapTick();
        ffTestTick();                                           // 5d: the preview's capture, test builds
        startTestTick();                                        // 9b: the knight's turn after Start, test builds
        diasTestTick();                                         // 4aa: the Dias's pictures, test builds
#endif
#ifdef IBFIX_SNAPS
        filmCueTick();                                          // 4i: watching only, test builds
        cheatTick();                                            // 4o: test builds only
        titleLogoCheck();
        objCheckRate();                                         // FIXES.md 90
        spawnCheckTick();
#endif
        if (vt) fixViewTargetFOV(vt);
#if defined(IBFIX_SNAPS) && defined(IBFIX_BLOODCAP)
        bloodSnapTick(vt);                                      // 4ab: the blood mock-ups' pictures, after the view is final
#endif
#ifdef IBFIX_BLOOD
        bloodTick();                                            // 4ac: blood in the 3D scene
#endif
        return;
    }
    if (!gNoStoreTried && self && [ibfix_objname(CLS(self)) isEqualToString:@"SwordPC"]) { patchNoStore(self); achInstall(self); }   // 4ae
#ifdef IBFIX_SNAPS
    skipZoneStateWatch();
#endif
    static int nameInitScene = -2, nameRenderScene = -2;           // 4v: the Character Slots screen's COPY button
    if (nameInitScene == -2) { nameInitScene = nameIndex("InitMenuScene"); nameRenderScene = nameIndex("RenderScene"); }
    BOOL slotsInit = NO;
    if (name == nameRenderScene && self && isClass(self, "SwordPauseMenuScene")) gAchBttn = objAt(self, "AchievementsBttn");   // 4af
    NAME_ONCE(nameRenderObject, "RenderObject");
    if (name == nameRenderObject && self && self == gAchBttn) achButtonDraw(self);                 // 4af: lit at its own draw
#ifdef IBFIX_SNAPS
    if (name == nameRenderScene && self) sceneSnap(self);       // 4ae (test builds): each menu screen photographed once
#endif
    if (name == nameInitScene && self && isClass(self, "SwordPauseMenuScene")) noUpsells(self);   // 4ag: no Facebook button
    if ((name == nameInitScene || name == nameRenderScene) && self && isClass(self, "SwordSaveGameScene")) {
        if (name == nameInitScene) { copyPreInit(self); slotsInit = YES; } else copyRender(self);
    }
    NAME_ONCE(nameZoneAdded, "OnMobileInputZoneAdded");
    void *zoneArg = (name == nameZoneAdded && self) ? localObjectArg(stack) : NULL;   // before the call moves Code on
    NAME_ONCE(nameBossEvent, "TriggerBossEvent_Internal");
    int bossEvent = (name == nameBossEvent && self) ? localByteArg(stack) : -1;
    NAME_ONCE(nameCheckStage, "CheckForStageTransition");
    BossStage stageBefore; BOOL stageCheck = name == nameCheckStage && self && bossStage(self, &stageBefore);
#ifdef IBFIX_SNAPS
    NAME_ONCE(nameMobileTouch, "OnMobileTouch");                    // 4r: a tap a circle takes in a fight (the HUD's script calls it)
    if (name == nameMobileTouch && self && *(void **)self == (void *)(IB1_TOUCHACTOR_VTABLE + _dyld_get_image_vmaddr_slide(0)))
        LOG(@"circle taps: %@ taken (the game's fight test, against the drawn circle)", circleName(self));
#endif
#ifdef IBFIX_BLOOD
    NAME_ONCE(nameTouched, "OnMobileTouch");                                // 4ac: a weak spot's circle tapped (the stab's wound goes there)
    if (name == nameTouched && self && gBloodOn && isClass(self, "SwordBossTouchActor")) bloodStabSpot(self);
#endif
    NAME_ONCE(nameFinishBattle, "OnFinishBossBattle");
    NAME_ONCE(nameGiveReward, "GiveReward");                             // 4x: a chest's treasure given (from its SeqAct_AwardTreasure)
    if (name == nameGiveReward && self) {
        uint8_t *giver = *(uint8_t **)((uint8_t *)stack + 0x20);  // the calling frame's object
        if (giver && isLiveObject(giver) && isClass(giver, "SeqAct_AwardTreasure")) chestTreasureGiven(giver);
    }
    if (ffRestartBlocked(self, stack)) return;                  // 4l: fast-forward only while held
    static int nameClearCombo = -2, nameDoCombo = -2, nameFinishInfo = -2;
    if (nameClearCombo == -2) { nameClearCombo = nameIndex("ClearComboTutorial"); nameDoCombo = nameIndex("OnDoCombo"); nameFinishInfo = nameIndex("FinishInfoTutorial"); }
    if (name == nameClearCombo && self && lessonComboClear(self, stack)) return;   // 4p: Mega Hit, Ultra Hit
    if (name == nameDoCombo && self) lessonComboAwarded(self);                     // 4p: which combo
    void *infoCaller = name == nameFinishInfo && self ? *(void **)((uint8_t *)stack + 0x18) : NULL;
#ifdef IBFIX_SNAPS
    NAME_ONCE(nameSuperGlory, "DoSuperGloryMode");
    void *superCaller = gTestCombo && name == nameSuperGlory && self ? *(void **)((uint8_t *)stack + 0x18) : NULL;
    BOOL superUsed = superCaller && [ibfix_objname(superCaller) isEqualToString:@"ActivateSuperMode"];
#endif
    BOOL infoOpened = infoCaller && [ibfix_objname(infoCaller) isEqualToString:@"ToggleBossPopup"];
    if (hiddenDraw(self, stack, result, name)) return;          // 7c: Hide The HUD, Hide Combat Text
    noteLastBoss(self, name);                                   // 7d: the boss, for haptics and blood
#ifdef IBFIX_BLOOD
    if (bloodCall(self, stack, result, name)) return;           // 4ac: the knight's strikes and stabs; blood mode's quieter item effects
#endif
    if (hapticCall(self, stack, result, name)) return;          // 7d: haptics
    if (padNumberCall(self, stack, result, name)) return;       // 3g: the iPad's health numbers
    if (listClickCall(self, stack, result, name)) return;       // 4ad: a tap reaches the list row drawn under the finger
    if (name == nameGiveReward && self && isClass(self, "SwordPlayer")) { ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result); achChestCheck(self); return; }   // 4ae: Jackpot! at 100
    NAME_ONCE(nameMissing, "CheckForMissingAchievements");
    if (name == nameMissing && self && isClass(self, "SwordPlayer")) { ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result); achInferCheck(self); return; }   // 4al
#ifdef IBFIX_SNAPS
    NAME_ONCE(nameDrawAch, "DrawAchievement");
    if (name == nameDrawAch) achSnapTick();                    // 4ae: the test row's pictures of the pop-up
#endif
    NAME_ONCE(nameMatSAP, "MAT_SetAnimPosition");
    if (name == nameMatSAP) { cutsceneCueThreshold(self, stack); loopWrap(self, stack); }   // 4m: cutscene cues always fire; looping animations loop
    if (name == nameMatSAP) keyBladeCall(self, stack);          // 4aa: the Infinity Blade fits the Dias's slot
#ifdef IBFIX_SNAPS
    if (name == nameMatSAP && animWatchCall(self, stack, result)) return;   // 4m: and the watch, test builds
    NAME_ONCE(nameSetSpeed, "SetGameSpeed");
    if (name == nameSetSpeed && self) {                        // 4l, test builds: who sets the game's speed, and to what
        void *caller = *(void **)((uint8_t *)stack + 0x18);
        ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
        uint8_t *wi = WORLD_INFO();
        int oTD = wi ? poff(CLS(wi), "TimeDilation") : -1;
        uint8_t *hud = ffHud(); int oLast = hud ? poff(CLS(hud), "LastGameSpeed") : -1;
        LOG(@"game speed set to %.2f by %@ (button %@; the HUD's noted normal speed %.2f)", oTD >= 0 ? *(float *)(wi + oTD) : -1,
            caller ? ibfix_objname(caller) : @"?", skipHeld() ? @"held" : @"not held", oLast >= 0 ? *(float *)(hud + oLast) : -1);
        return;
    }
#endif
    if (name == nameFinishBattle && self) {                    // 4k: from the skip's "Yes"?
        void *caller = *(void **)((uint8_t *)stack + 0x18);
        if (caller && [ibfix_objname(caller) isEqualToString:@"OnSkipFinalCutsceneSequence"]) stopSkippedEnding(self);
    }
#ifdef IBFIX_SNAPS
    NAME_ONCE(namePlayFX, "PlayFX");
    int askedFX = (name == namePlayFX && self) ? intArg(stack) : -1;   // before the call moves Code on
    if (askedFX >= 0) filmCueAsked(self, askedFX);             // 4i: watching only, test builds
    if (name == namePlayFX && self) bossEffectAsked(self, askedFX);
    NAME_ONCE(nameSpawnAttach, "SpawnEmitterMeshAttachment");
    BOOL spawnCheck = name == nameSpawnAttach && gBossFX >= 0;
    int outerFX = gBossFX;
    if (askedFX >= 0 && poff(CLS(self), "StageTransitionHealth") >= 0) gBossFX = askedFX;
#endif
    NAME_ONCE(namePostRenderItem, "PostRenderItem");
    if (name == namePostRenderItem && self && gBadgeTex) achRowBadge(self);   // 4ai: a row's badge, under the list's edge cover
    NAME_ONCE(nameDrawPop, "DrawAchievement");
    if (name == nameDrawPop && self) achPopBefore(self);                       // 4am: the devs' strip off the screen
    if (name == nameRenderScene && self) boxRoom(self);                        // 4ak: every box's message room
    if (name == nameRenderScene && self && gAchBoxId) achBoxBefore(self);      // 4ai: the box's title moved for its badge
    void *prevScene = gMenuScene, *prevObj = gMenuObj;          // 3h: which menu screen and object is drawing
    if (name == nameRenderScene && self) { gMenuScene = self; gMenuObj = NULL; }
    if (name == nameRenderObject && self) gMenuObj = self;
    // 3i: the pause screen's mask reaches the screen's right edge (its Width, read only by its mask while it draws, one
    // margin wider for this call), so ARENA MODE's panel slides in from the screen's edge; its left stays masked
    int oPauseW = -1; float pauseW = 0;
    if (name == nameRenderScene && self && gViewportWidth > 0 && isClass(self, "SwordPauseMenuScene")) {
        oPauseW = poff(CLS(self), "Width");
        if (oPauseW > 0) {
            pauseW = *(float *)((uint8_t *)self + oPauseW);
            float m = (gViewportWidth - pauseW) / 2;
            if (m >= 1 && pauseW > 0) *(float *)((uint8_t *)self + oPauseW) = pauseW + m; else oPauseW = -1;
        }
    }
    ((NativeFn)gOrigVirtualFunction.fn)(self, stack, result);
    if (oPauseW > 0) *(float *)((uint8_t *)self + oPauseW) = pauseW;
    if (name == nameRenderScene && self) menuBandLeft(self);   // 3i: the band's left end, outside the mask
    if (name == nameRenderScene && self && gAchBoxId) achBoxAfter(self);       // 4ai: the box's badge
    if (name == nameDrawPop && self) achPopAfter(self);                        // 4am: ACHIEVEMENT UNLOCKED
    gMenuScene = prevScene; gMenuObj = prevObj;
#ifdef IBFIX_SNAPS
    gBossFX = outerFX;
    if (spawnCheck) effectSpawned(*(void **)result, outerFX);
#endif
    if (stageCheck) stageChecked(self, &stageBefore);              // after the boss's own check (4h)
    if (infoOpened) lessonInfoOpened(self);                    // 4p: Info2, after the game's FinishInfoTutorial
#ifdef IBFIX_SNAPS
    if (superUsed) lessonTestSuper(self);                      // 4p, test switch: the combo lesson after the super move
#endif
    if (bossEvent >= 0) stageMusic(self, bossEvent);           // after the arena's own script (4f)
    if (bossEvent == 4) faunPlayerDeath(self);                 // 4s: "Player Death"
    if (zoneArg) blockZoneAdded(self, zoneArg);                // after the game's own code (dodge sizes, swipe set-up)
    if (slotsInit) copyPostInit(self);                         // 4v
    if (name != gNameInitMenuObject || !self) return;
    void *cls = CLS(self);
    if (!gOptionsListClass && [ibfix_objname(cls) isEqualToString:@"SwordUserOptionsList"]) gOptionsListClass = cls;
    if (cls == gOptionsListClass && achFillList(self)) return;   // 4af: the list in achievements mode
    if (cls == gOptionsListClass) addVolumeSliders(self);
    if (cls == gOptionsListClass) addDisplayOptions(self);     // 7c
#ifdef IBFIX_SNAPS
    if (cls == gOptionsListClass) addCheatOptions(self);  // 4o: test builds only
#endif
}

// Run once the engine is up (from the first DrawTile, on the game thread): GNatives is filled by
// the game's own start-up code, after this library's constructors.
static void installVolumeSliders(void *canvas) {
    static BOOL done; if (done) return; done = YES;
    uint8_t *drawTile = findFunction(canvas, "DrawTile");
    for (size_t off = 0x40; drawTile && off < 0x200; off += 8)
        if (*(void **)(drawTile + off) == (void *)my_execDrawTile) { gFuncOff = off; break; }
    gNameInitMenuObject = nameIndex("InitMenuObject");
    MemberFn *vf = &gNatives[EX_VIRTUALFUNCTION];
    if (!gFuncOff || gNameInitMenuObject < 0 || !vf->fn || vf->adj != 0) { LOG(@"volume sliders OFF (func %#zx name %d)", gFuncOff, gNameInitMenuObject); return; }
    gOrigVirtualFunction = *vf;
    vf->fn = (void *)my_execVirtualFunction;
    LOG(@"volume sliders ON (UFunction::Func at %#zx)", gFuncOff);
}

static void hookVolumes(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:kMasterVolumeKey]) ibfix_master_volume = [ud floatForKey:kMasterVolumeKey];
    if ([ud objectForKey:kMusicVolumeKey]) gMusicVolume = [ud floatForKey:kMusicVolumeKey];
    if ([ud objectForKey:kBlockSizeKey]) gBlockSlider = fminf(fmaxf([ud floatForKey:kBlockSizeKey], 0), 1);
    if ([ud objectForKey:kWithMusicKey]) gWithMusicSlider = fminf(fmaxf([ud floatForKey:kWithMusicKey], 0), 1);
    LOG(@"volume sliders: Game Sound (My Music) %.2f%@", gWithMusicSlider, [ud objectForKey:kWithMusicKey] ? @"" : @" (not yet set: half)");
    oSetVolume = hookMethod([AVAudioPlayer class], @selector(setVolume:), (IMP)m_setVolume);
}

// ---- Set-up ------------------------------------------------------------------------------


// ---- 4e. Home swipes kept from the game -------------------------------------------------------
// Since the bottom edge is claimed (section 4), a swipe home reaches the game as an ordinary touch, and was read as
// "look up" (FIXES.md 35). Now a touch that starts in the bottom strip reaches the game at once only on one of its
// buttons there (a small zone of the input's current group: the skip, dodge and block buttons); anywhere else in the
// strip a tap reaches it when the finger lifts, and a swipe, or a touch iOS cancels for going home, never reaches it.
// The game's views (EAGLView, and TouchView, its touch layer over it, which passes on to it) hand every touch to
// HandleTouches (0x1008efa20), which reads each touch's own phase, so a tap is passed on lift by having that one touch
// report "began" for one call.

static UITouch *gPhaseTouch; static UITouchPhase gPhaseAs;      // one touch told to report another phase (main thread)
static IMP gOrigPhase;
static UITouchPhase my_touchPhase(UITouch *self, SEL _cmd) {
    return self == gPhaseTouch ? gPhaseAs : ((UITouchPhase (*)(id, SEL))gOrigPhase)(self, _cmd);
}

// Is p a live engine object? Checked without trusting it: an address at all (aligned, in the range the heap uses,
// so never characters of a string), then its own slot number (+0x38) in the object table pointing back at it. An object
// that went with an unloaded level can have had its memory given back to the system, and reading it then stops the
// game, so the slot number is copied by the kernel (vm_read_overwrite), which refuses memory that's gone instead of
// crashing (FIXES.md 90). plausibleObj, objAt and every kept pointer's check come through here.
static BOOL isLiveObject(const void *p) {
    uintptr_t u = (uintptr_t)p;
    if ((u & 7) || u < 0x100000000ULL || u > 0xFFFFFFFFFULL) return NO;
#ifdef IBFIX_SNAPS
    gObjChecks++;
#endif
    int i = -1; vm_size_t got = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)(u + 0x38), sizeof i, (vm_address_t)&i, &got) != KERN_SUCCESS || got != sizeof i) return NO;
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    return i >= 0 && i < objs->num && objs->data[i] == p;
}

// For flare.m: the live objects of a class (or one coming from it), found by comparing class pointers (quick), up to
// max; and a placed component's world location (its LocalToWorld's translation, the matrix's last row).
int ibfix_objects_of_class(const char *name, void **out, int max) {
    static NSMutableDictionary<NSString *, NSValue *> *classes;
    if (!classes) classes = [NSMutableDictionary dictionary];
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    void *cls = classes[@(name)].pointerValue;
    if (!cls || !isLiveObject(cls)) {
        int nm = nameIndex(name); cls = NULL; if (nm < 0) return 0;
        for (int i = 0; i < objs->num && !cls; i++) {
            uint8_t *o = objs->data[i];
            if (o && *(int *)(o + 0x48) == nm && *(int *)(o + 0x4c) == 0 && [ibfix_objname(CLS(o)) isEqualToString:@"Class"]) cls = o;
        }
        if (!cls) return 0;
        classes[@(name)] = [NSValue valueWithPointer:cls];
    }
    int n = 0;
    for (int i = 0; i < objs->num && n < max; i++) {
        uint8_t *o = objs->data[i]; if (!o) continue;
        void *c = CLS(o);
        for (int d = 0; c && c != cls && d < 6; d++) c = *(void **)((uint8_t *)c + 0x68);
        if (c == cls && ![ibfix_objname(o) hasPrefix:@"Default__"]) out[n++] = o;
    }
    return n;
}
BOOL ibfix_component_location(void *comp, float out[3]) {
    if (!isLiveObject(comp)) return NO;
    int o = poff(CLS(comp), "LocalToWorld"); if (o < 0) return NO;
    const float *m = (const float *)((uint8_t *)comp + o);
    out[0] = m[12]; out[1] = m[13]; out[2] = m[14];
    return YES;
}

// The game's MobilePlayerInput: the first object whose class is, or comes from, GameFramework's MobilePlayerInput
// (found by comparing class pointers, quick enough for a touch; checked by slot, as it can be replaced).
static uint8_t *mobileInput(void) {
    static ObjRef in; static void *mpiClass; static CFAbsoluteTime lastScan;
    if (in.obj && !refLive(&in)) in.obj = NULL;
    if (in.obj) return in.obj;
    CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent(); if (tn - lastScan < 1) return NULL;
    lastScan = tn;
    ObjArray *objs = (void *)(IB1_GOBJOBJECTS + _dyld_get_image_vmaddr_slide(0));
    if (!mpiClass) {
        int nm = nameIndex("MobilePlayerInput"); if (nm < 0) return NULL;
        for (int i = 0; i < objs->num && !mpiClass; i++) {
            uint8_t *o = objs->data[i];
            if (o && *(int *)(o + 0x48) == nm && *(int *)(o + 0x4c) == 0 && [ibfix_objname(CLS(o)) isEqualToString:@"Class"]) mpiClass = o;
        }
        if (!mpiClass) return NULL;
    }
    for (int i = 0; i < objs->num && !in.obj; i++) {
        uint8_t *o = objs->data[i]; if (!o) continue;
        void *c = CLS(o);
        for (int d = 0; c && c != mpiClass && d < 8; d++) c = *(void **)((uint8_t *)c + 0x68);   // up its superclasses
        if (c == mpiClass && ![ibfix_objname(o) hasPrefix:@"Default__"]) in = (ObjRef){ o, i, CLS(o) };
    }
    return in.obj;
}

// Is p (points, in view v) on a button of the current input group? The zones are in the input's viewport pixels
// (MobileViewportSize), which is the HUD region (gRegionPx) on the screen.
static BOOL onGameButton(UIView *v, CGPoint p, NSString **which) {
    uint8_t *in = mobileInput(); if (!in) { *which = @"(no input found)"; return NO; }
    void *ic = CLS(in);
    int oG = poff(ic, "MobileInputGroups"), oC = poff(ic, "CurrentMobileGroup"), oVS = poff(ic, "MobileViewportSize");
    if (oG < 0 || oC < 0 || oVS < 0) { *which = @"(input fields missing)"; return NO; }
    ObjArray *groups = (ObjArray *)(in + oG); int cur = *(int *)(in + oC);
    if (cur < 0 || cur >= groups->num || !groups->data) { *which = @"(no current group)"; return NO; }
    float vw = *(float *)(in + oVS), vh = *(float *)(in + oVS + 4);
    if (vw < 100 || vh < 100) { *which = @"(viewport not laid out)"; return NO; }
    // A group is {GroupName (string), AssociatedZones (array)}: 16 bytes each. Take the member whose zones belong to this input.
    uint8_t *g = (uint8_t *)groups->data + cur * 32;
    ObjArray *zones = NULL; BOOL any = NO;
    for (int off = 16; off >= 0 && !zones; off -= 16) {
        ObjArray *a = (ObjArray *)(g + off);
        uintptr_t d = (uintptr_t)a->data;
        if (a->num <= 0 || a->num > 64 || (d & 7) || d < 0x100000000ULL || d > 0xFFFFFFFFFULL) continue;
        uintptr_t e0 = (uintptr_t)a->data[0];                       // a list of objects, or a name's letters?
        if (!(e0 & 7) && e0 >= 0x100000000ULL && e0 <= 0xFFFFFFFFFULL) any = YES;
        if (!isLiveObject(a->data[0])) continue;
        void *zc = CLS(a->data[0]); int oIn = poff(zc, "InputOwner");
        if (oIn > 0 && *(uint8_t **)((uint8_t *)a->data[0] + oIn) == in) zones = a;
    }
    if (!zones) { *which = any ? @"(group's zones not recognised)" : @"(no buttons showing)"; return NO; }   // e.g. a cutscene before its first tap shows the skip button
    float sx = gRegionPx[2] > 0 ? gRegionPx[2] / vw : 1, sy = gRegionPx[3] > 0 ? gRegionPx[3] / vh : 1, k = v.contentScaleFactor;
    const float margin = 8;                                         // points round each button
    for (int i = 0; i < zones->num; i++) {
        uint8_t *z = zones->data[i]; if (!isLiveObject(z)) continue;
        void *zc = CLS(z);
        int oX = poff(zc, "X"), oY = poff(zc, "Y"), oW = poff(zc, "SizeX"), oH = poff(zc, "SizeY");
        if (oX < 0 || oY < 0 || oW < 0 || oH < 0) continue;
        float zx = *(float *)(z + oX), zy = *(float *)(z + oY), zw = *(float *)(z + oW), zh = *(float *)(z + oH);
        if (zw <= 0 || zh <= 0 || zw > 0.4f * vw || zh > 0.4f * vh) continue;   // swipe and look areas aren't buttons
        CGRect r = CGRectMake((gRegionPx[0] + zx * sx) / k, (gRegionPx[1] + zy * sy) / k, zw * sx / k, zh * sy / k);
        if (CGRectContainsPoint(CGRectInset(r, -margin, -margin), p)) { *which = ibfix_objname(z); return YES; }
    }
    *which = nil; return NO;
}

static NSMutableDictionary<NSValue *, NSValue *> *gHeld;           // touches held back: touch -> where it started
static NSMutableSet<NSValue *> *gSwiped;                          // held touches that moved: swipes, never passed on
static IMP gOrigTouch[2][4];                                      // [EAGLView, TouchView][began, moved, ended, cancelled]
static Class gGlViewClass;

static NSSet *homeGate(UIView *v, NSSet *touches, int phase, int k) {
    NSMutableSet *pass = nil;
    for (UITouch *t in touches) {
        if (![t isKindOfClass:[UITouch class]]) { if (!pass) pass = [NSMutableSet set]; [pass addObject:t]; continue; }
        NSValue *key = [NSValue valueWithNonretainedObject:t];
        CGPoint p = [t locationInView:v];
        if (phase == 0) {
            float strip = MAX(v.safeAreaInsets.bottom, 20) + 6;
            NSString *which = nil;
            if (p.y < v.bounds.size.height - strip) { if (!pass) pass = [NSMutableSet set]; [pass addObject:t]; continue; }
            if (onGameButton(v, p, &which)) {
                LOG(@"bottom edge: touch at %.0f,%.0f pt on %@: to the game at once", p.x, p.y, which);
                if (!pass) pass = [NSMutableSet set]; [pass addObject:t]; continue;
            }
            gHeld[key] = [NSValue valueWithCGPoint:p];
            LOG(@"bottom edge: touch at %.0f,%.0f pt held (no button there%@%@)", p.x, p.y, which ? @"; " : @"", which ?: @"");
            continue;
        }
        NSValue *start = gHeld[key];
        if (!start) { if (!pass) pass = [NSMutableSet set]; [pass addObject:t]; continue; }
        CGPoint s0 = start.CGPointValue;
        if (phase == 1) { if (hypot(p.x - s0.x, p.y - s0.y) > 10) [gSwiped addObject:key]; continue; }
        if (phase == 2 && ![gSwiped containsObject:key]) {         // a tap: began now, then its own end
            gPhaseTouch = t; gPhaseAs = UITouchPhaseBegan;
            ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouch[k][0])(v, @selector(touchesBegan:withEvent:), [NSSet setWithObject:t], nil);
            gPhaseTouch = nil;
            if (!pass) pass = [NSMutableSet set]; [pass addObject:t];
            LOG(@"bottom edge: tap at %.0f,%.0f pt passed to the game on lift", p.x, p.y);
        } else LOG(@"bottom edge: %@ from %.0f,%.0f pt kept from the game", phase == 3 ? @"touch cancelled by iOS" : @"swipe", s0.x, s0.y);
        [gHeld removeObjectForKey:key]; [gSwiped removeObject:key];
    }
    return pass;
}

#define GATE(name, ph) \
    static void gate_##name(id self, SEL _cmd, NSSet *touches, UIEvent *e) { \
        int k = [self isKindOfClass:gGlViewClass] ? 0 : 1; \
        NSSet *pass = homeGate((UIView *)self, touches, ph, k); \
        if (pass.count) ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouch[k][ph])(self, _cmd, pass, e); \
    }
GATE(began, 0) GATE(moved, 1) GATE(ended, 2) GATE(cancelled, 3)

static void hookHomeSwipe(void) {
    gGlViewClass = NSClassFromString(@"EAGLView");
    Class cs[2] = { gGlViewClass, NSClassFromString(@"TouchView") };
    SEL sels[4] = { @selector(touchesBegan:withEvent:), @selector(touchesMoved:withEvent:), @selector(touchesEnded:withEvent:), @selector(touchesCancelled:withEvent:) };
    IMP gates[4] = { (IMP)gate_began, (IMP)gate_moved, (IMP)gate_ended, (IMP)gate_cancelled };
    for (int k = 0; k < 2; k++)
        if (!cs[k] || ![cs[k] isSubclassOfClass:[UIView class]]) { LOG(@"home swipe gate OFF: no %s view", k ? "TouchView" : "EAGLView"); return; }
    gHeld = [NSMutableDictionary dictionary]; gSwiped = [NSMutableSet set];
    gOrigPhase = hookMethod([UITouch class], @selector(phase), (IMP)my_touchPhase);
    for (int k = 0; k < 2; k++) for (int i = 0; i < 4; i++) gOrigTouch[k][i] = hookMethod(cs[k], sels[i], gates[i]);
    LOG(@"home swipe gate ON: a touch from the bottom strip reaches the game at once only on a button");
}

__attribute__((constructor)) static void game_init(void) {
    gLaunchTime = CFAbsoluteTimeGetCurrent();
    setupIPad();                                            // 3g: before the game works out its device
    devicePrefs();                                          // 3g: before anything reads the settings
    hookSubtitleScale();
    hookHUDRegion();
    hookBackgrounds();
    hookTouchActors();
    hookGodKingCircle();                                    // 4q
    hookCircleTaps();                                       // 4r
    hookWellReturn();                                       // 4y
#ifdef IBFIX_SNAPS
    ffTestRead();                                           // 5d: the preview's capture, test builds
    startTestRead();                                        // 9b: the knight's turn after Start, test builds
    diasTestRead();                                         // 4aa: the Dias's pictures, test builds
#endif
    hookCopyButton();                                       // 4v
    hookViewController();
    hookHomeSwipe();
    hookStartButton();
    hookSharpness();
    hookFilmLog();
    noLiveText();                                           // 4ah
    keepFilmPlaying();
    hookMusic();
    hookMusicTrace();
    hookFXNotify();
    hookSpells();
    hookSpeech();
    hookSpokenLines();                                      // 4w: after 4j, whose hook it rides on
    hookKeyBlade();                                         // 4aa
    hookResumeMusic();
    hookVolumes();
    // Keep the render height current (read on the game thread by the subtitle hook), and log the
    // music player's state every 10 s so silent stretches show up in the log.
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), NSEC_PER_SEC, NSEC_PER_SEC / 20);
    __block int ticks = 0;
    dispatch_source_set_event_handler(t, ^{
        UIWindow *w = [UIApplication sharedApplication].windows.firstObject;
        NSMutableArray *stack = w ? [NSMutableArray arrayWithObject:w] : [NSMutableArray array];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if ([NSStringFromClass([v class]) isEqualToString:@"EAGLView"]) {
                gViewportHeight = v.bounds.size.height * v.contentScaleFactor;
                gViewportWidth = v.bounds.size.width * v.contentScaleFactor;
                if (v.bounds.size.height > 0) gViewportAspect = v.bounds.size.width / v.bounds.size.height;
                UIEdgeInsets in = v.window.safeAreaInsets;
                if (v.bounds.size.width > 0) gSafeSideFrac = MAX(in.left, in.right) / v.bounds.size.width;
                break;
            }
            [stack addObjectsFromArray:v.subviews];
        }
        if (++ticks % 10 == 0) {
            id del = [UIApplication sharedApplication].delegate;
            SEL bg = NSSelectorFromString(@"bUsingBackgroundMusic"), next = NSSelectorFromString(@"NextSongToPlay");
            LOG(@"music: now %@ | category %@ | bUsingBackgroundMusic %d | next %@", playerState(del), [AVAudioSession sharedInstance].category,
                [del respondsToSelector:bg] ? ((BOOL (*)(id, SEL))objc_msgSend)(del, bg) : -1,
                [del respondsToSelector:next] ? ((id (*)(id, SEL))objc_msgSend)(del, next) : @"?");
        }
    });
    dispatch_resume(t);
    static dispatch_source_t keep; keep = t;
}
