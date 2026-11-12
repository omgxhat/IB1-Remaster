// bump.m: the PC port's own bump and shine maps on the world, option B (FIXES.md 36). In every build, but acts only when
// ibfix-bump.pak (tools/bump/makebump.py) is in the app: per colour texture (keyed like ibfix-hd.pak by the SHA-256 of
// the game's own data), a PC bump map with its shine mask in alpha, its settings and the level's main light.
// The world's 12 lightmapped shader pairs are extended as they compile: the vertex shader passes on the world tangent
// frame and the eye vector (world positions here are measured from the camera). Each changed shader is test-compiled,
// a pair that fails to link is put back, and each is checked to be fed the tangents and placement before it is used.
// The hooks are in post.m (shaders, links, texture bindings, draws) and game.m (texture uploads).

#import <Foundation/Foundation.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <CommonCrypto/CommonDigest.h>


#include "ibfix.h"
GLuint ibfix_bound_2d(int unit);                 // post.m: the texture bound on a unit, as the game left it
int ibfix_active_unit(void);                    // post.m: the game's active texture unit

typedef struct { uint64_t hash; uint32_t entry, level, gw, gh; } BKey;
typedef struct { uint32_t fmt, w, h, mips; uint64_t off, size; float p[8]; } BEntry;   // shine, power, tint, soft, bump, light xyz
static NSData *gFile; static const BKey *gKeys; static const BEntry *gEntries; static uint32_t gNKeys, gNEntries;
static BOOL gOn;                                // the file is there and nothing has gone wrong
static GLuint *gEntryTex;                       // per entry: our GL texture (0 = not up yet; ~0 = failed)
static int gUnit = -1;                          // the texture unit the bump maps go on (the last one)
static GLuint gUnitTex;                         // what we last bound there
__attribute__((weak)) void ibfix_wound_forget_unit(void) {}   // wound.m shares the unit (enemies' skins: no bump maps there)
static int gHits, gChanged;

static void bumpOpen(void) {
    static BOOL tried; if (tried) return; tried = YES;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"ibfix-bump" ofType:@"pak"];
    if (!path) return;                                          // not in this build: nothing happens
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:NULL];
    const uint32_t *h = d.length >= 16 ? d.bytes : NULL;
    if (!h || memcmp(h, "IBBM", 4) || h[1] != 1 || 16 + 24ull * h[3] + 64ull * h[2] > d.length) { LOG(@"bump maps OFF: ibfix-bump.pak not as expected"); return; }
    gFile = d; gNEntries = h[2]; gNKeys = h[3];
    gKeys = (const BKey *)((const uint8_t *)d.bytes + 16); gEntries = (const BEntry *)(gKeys + gNKeys);
    gEntryTex = calloc(gNEntries, sizeof(GLuint));
    GLint units = 0; glGetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &units);
    gUnit = units >= 8 ? MIN(units, 32) - 1 : -1;               // the last one (the iPhone 17's GL reports 8: unit 7)
    gOn = gUnit > 0;
    LOG(@"bump maps %@: %u in ibfix-bump.pak (%.0f MB), on texture unit %d of %d", gOn ? @"ON" : @"OFF", gNEntries, d.length / 1e6, gUnit, units);
}

// ---- which colour texture has a bump map: GL texture name -> entry (open addressing; names are small integers) ----
#define kMapSize 8192
static GLuint gMapName[kMapSize]; static int gMapEntry[kMapSize];
static int *mapSlot(GLuint t, BOOL add) {
    for (unsigned i = (t * 2654435761u) & (kMapSize - 1), n = 0; n < kMapSize; i = (i + 1) & (kMapSize - 1), n++) {
        if (gMapName[i] == t) return &gMapEntry[i];
        if (!gMapName[i]) { if (!add) return NULL; gMapName[i] = t; gMapEntry[i] = -1; return &gMapEntry[i]; }
    }
    return NULL;
}
static int entryFor(GLuint t) { int *e = t ? mapSlot(t, NO) : NULL; return e ? *e : -1; }

// game.m: the game uploads level 0 of a compressed texture into the bound texture name
void ibfix_bump_note_upload(GLenum target, const void *data, GLsizei size) {
    bumpOpen();
    if (!gOn || target != GL_TEXTURE_2D || !data || size <= 0) return;
    GLint bound = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound); if (bound <= 0) return;
    uint8_t dig[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data, (CC_LONG)size, dig);
    uint64_t want; memcpy(&want, dig, 8);
    uint32_t lo = 0, hi = gNKeys;
    while (lo < hi) { uint32_t mid = (lo + hi) / 2; if (gKeys[mid].hash < want) lo = mid + 1; else hi = mid; }
    int e = lo < gNKeys && gKeys[lo].hash == want && gKeys[lo].entry < gNEntries ? (int)gKeys[lo].entry : -1;
    int *s = mapSlot((GLuint)bound, e >= 0);
    if (s) *s = e;                                              // a new picture in this name: its bump map, or none
    if (e >= 0 && ++gHits <= 30) LOG(@"bump maps: texture %d has one (#%d, %ux%u)", bound, e, gEntries[e].w, gEntries[e].h);
}
// post.m: the game deletes textures (their names may come back for other pictures)
void ibfix_bump_note_deleted(GLsizei n, const GLuint *t) {
    for (GLsizei i = 0; gOn && t && i < n; i++) { int *s = mapSlot(t[i], NO); if (s) *s = -1; }
}

// ---- the shaders ---------------------------------------------------------------------------------------------
static NSMutableDictionary<NSNumber *, NSString *> *gOriginal;   // changed shaders: their own source, to put back
#include "glcompile.h"
// post.m: the game is about to give shader sh this source; returns the extended source, or nil to leave it
NSString *ibfix_bump_rewrite(GLuint sh, NSString *src) {
    bumpOpen();
    if (!gOn) return nil;
    GLint kind = 0; glGetShaderiv(sh, GL_SHADER_TYPE, &kind);
    NSString *out = nil;
    if (kind == GL_VERTEX_SHADER && [src containsString:@"attribute vec2 LightMapCoordinate;"] && ![src containsString:@"BoneMatrices"] &&
        [src containsString:@"uniform mat4 LocalToWorld;"] && [src containsString:@"uniform mat3 LocalToWorldRotation;"]) {
        NSRange mainAt = [src rangeOfString:@"void main()"], end = [src rangeOfString:@"}" options:NSBackwardsSearch];
        if (mainAt.location == NSNotFound || end.location == NSNotFound || end.location < mainAt.location) return nil;
        NSMutableString *decl = [NSMutableString string];
        if (![src containsString:@"attribute vec3 TangentX;"]) [decl appendString:@"attribute vec3 TangentX;\n"];
        if (![src containsString:@"attribute vec4 TangentZ;"]) [decl appendString:@"attribute vec4 TangentZ;\n"];
        [decl appendString:@"varying lowp vec3 ibfixT;\nvarying lowp vec3 ibfixB;\nvarying lowp vec3 ibfixN;\nvarying mediump vec3 ibfixE;\n"];
        NSString *body =
            @"{\n"   // the engine's own unpacking (DefaultVertexShader.glsl: TangentBias3, TangentBias1)
             "vec3 ibn = TangentZ.xyz / vec3( 127.5 ) - vec3( 1.0 );\n"
             "vec3 ibt = TangentX / vec3( 127.5 ) - vec3( 1.0 );\n"
             "vec3 ibb = cross( ibn, ibt ) * ( TangentZ.w / 127.5 - 1.0 );\n"
             "ibfixT = LocalToWorldRotation * ibt; ibfixB = LocalToWorldRotation * ibb; ibfixN = LocalToWorldRotation * ibn;\n"
             "ibfixE = -( LocalToWorld * Position ).xyz;\n"
             "}\n";
        NSMutableString *m = [src mutableCopy];
        [m insertString:body atIndex:end.location];
        [m insertString:decl atIndex:mainAt.location];
        out = m;
    } else if (kind == GL_FRAGMENT_SHADER) {
        NSString *anchor = @"lowp vec3 LightmapColor = texture2D( TextureLightmap, UVLightmap ).rgb;";
        // (the game's shader files have Windows line endings, \r\n: anchored on the line, inserted after its own break)
        NSRange a = [src rangeOfString:anchor], p = [src rangeOfString:@"precision mediump float;"];
        if (p.location != NSNotFound) { NSRange nl = [src rangeOfString:@"\n" options:0 range:NSMakeRange(NSMaxRange(p), src.length - NSMaxRange(p))];
                                        p = nl.location == NSNotFound ? (NSRange){NSNotFound, 0} : nl; }
        if (a.location == NSNotFound || p.location == NSNotFound || ![src containsString:@"FinalBaseUV"] || ![src containsString:@"lowp vec4 BaseColor"]) return nil;
        NSString *decl = @"uniform sampler2D ibfixNormal;\nuniform mediump vec4 ibfixLight;\nuniform mediump vec4 ibfixShine;\n"
                          "varying lowp vec3 ibfixT;\nvarying lowp vec3 ibfixB;\nvarying lowp vec3 ibfixN;\nvarying mediump vec3 ibfixE;\n";
        NSString *step =
            @"\nif ( ibfixShine.y > 0.0 ) {\n"   // y = the shine's power: 0 = no bump map for this draw
             "lowp vec4 ibM = texture2D( ibfixNormal, FinalBaseUV );\n"
             "mediump vec3 ibn = ibM.xyz * 2.0 - 1.0;\n"
             "mediump vec3 ibN0 = normalize( ibfixN );\n"
             "mediump vec3 ibN = normalize( ibfixT * ibn.x + ibfixB * ibn.y + ibfixN * ibn.z );\n"
             // bump shading of the baked light: as lit by the main light with the bumps, relative to the flat surface
             "mediump float ibF = ( max( dot( ibN, ibfixLight.xyz ), 0.0 ) + ibfixShine.w ) / ( max( dot( ibN0, ibfixLight.xyz ), 0.0 ) + ibfixShine.w );\n"
             "LightmapColor *= clamp( mix( 1.0, ibF, ibfixLight.w ), 0.5, 1.6 );\n"
             // shine: the main light's highlight on the bumped surface, masked, before the lightmap like the game's own
             "mediump vec3 ibH = normalize( ibfixLight.xyz + normalize( ibfixE ) );\n"
             "lowp float ibS = pow( max( dot( ibN, ibH ), 0.0 ), ibfixShine.y ) * ibfixShine.x * ibM.a;\n"
             "PolyColor.rgb += ibS * mix( vec3( 1.0 ), BaseColor.rgb, ibfixShine.z );\n"
             "}\n";
        NSMutableString *m = [src mutableCopy];
        [m insertString:step atIndex:NSMaxRange(a)];
        [m insertString:decl atIndex:NSMaxRange(p)];
        out = m;
    }
    if (!out) return nil;
    NSString *err = nil;
    if (!compiles((GLenum)kind, out, &err)) { LOG(@"bump maps: a %@ shader didn't compile with the step, left as the game's: %@", kind == GL_VERTEX_SHADER ? @"vertex" : @"pixel", err); return nil; }
    if (!gOriginal) gOriginal = [NSMutableDictionary dictionary];
    gOriginal[@(sh)] = [src copy];
    if (++gChanged <= 30) LOG(@"bump maps: %@ shader %u extended", kind == GL_VERTEX_SHADER ? @"vertex" : @"pixel", sh);
    return out;
}
// post.m: a program failed to link: if it has our shaders, put them back as the game had them and link again
BOOL ibfix_bump_relink(GLuint prog) {
    GLuint sh[8]; GLsizei n = 0; glGetAttachedShaders(prog, 8, &n, sh);
    BOOL ours = NO;
    for (GLsizei i = 0; i < n; i++) {
        NSString *src = gOriginal[@(sh[i])]; if (!src) continue;
        const char *c = src.UTF8String; glShaderSource(sh[i], 1, &c, NULL); glCompileShader(sh[i]);
        [gOriginal removeObjectForKey:@(sh[i])]; ours = YES;
    }
    if (!ours) return NO;
    char log[1024] = {0}; glGetProgramInfoLog(prog, sizeof log, NULL, log);
    LOG(@"bump maps OFF: program %u didn't link with the step (%s); put back as the game had it", prog, log);
    gOn = NO;                                                   // from here on, the game's own shaders only
    return YES;
}

// ---- each draw -----------------------------------------------------------------------------------------------
typedef struct { GLuint prog; GLint locShine, locLight, locNormal, locBase; int state, last, lastLook; } Prog;   // state 0 unchecked, 1 ok, 2 off
// Test builds' look switch (snaps.m's look sets, FIXES.md 58): 0 as made, 1 no highlight, 2 no bump shading, 3 off
static int gLookBump;
#ifdef IBFIX_SNAPS
void ibfix_look_bump(int mode) { gLookBump = mode; }
#endif
static Prog gProgs[256]; static int gNProgs;
static Prog *progInfo(GLuint p) {
    for (int i = 0; i < gNProgs; i++) if (gProgs[i].prog == p) return &gProgs[i];
    if (gNProgs >= 256) return NULL;
    Prog *q = &gProgs[gNProgs++];
    *q = (Prog){ p, glGetUniformLocation(p, "ibfixShine"), glGetUniformLocation(p, "ibfixLight"), glGetUniformLocation(p, "ibfixNormal"),
                 glGetUniformLocation(p, "TextureBase"), 0, -2, 0 };
    return q;
}
// Before a shader is first used with a bump map: does the engine feed it the tangents and the placement?
static BOOL check(Prog *q) {
    GLint ax = glGetAttribLocation(q->prog, "TangentX"), az = glGetAttribLocation(q->prog, "TangentZ"), ex = 0, ez = 0;
    if (ax >= 0) glGetVertexAttribiv((GLuint)ax, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &ex);
    if (az >= 0) glGetVertexAttribiv((GLuint)az, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &ez);
    GLint l2w = glGetUniformLocation(q->prog, "LocalToWorld"), l2r = glGetUniformLocation(q->prog, "LocalToWorldRotation");
    GLfloat m[16] = {0}, r[9] = {0}; float sm = 0, sr = 0;
    if (l2w >= 0) { glGetUniformfv(q->prog, l2w, m); for (int i = 0; i < 16; i++) sm += fabsf(m[i]); }
    if (l2r >= 0) { glGetUniformfv(q->prog, l2r, r); for (int i = 0; i < 9; i++) sr += fabsf(r[i]); }
    GLint sx = 0, tx = 0, sz = 0, tz = 0, st = 0;
    if (ax >= 0) { glGetVertexAttribiv((GLuint)ax, GL_VERTEX_ATTRIB_ARRAY_SIZE, &sx); glGetVertexAttribiv((GLuint)ax, GL_VERTEX_ATTRIB_ARRAY_TYPE, &tx); glGetVertexAttribiv((GLuint)ax, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &st); }
    if (az >= 0) { glGetVertexAttribiv((GLuint)az, GL_VERTEX_ATTRIB_ARRAY_SIZE, &sz); glGetVertexAttribiv((GLuint)az, GL_VERTEX_ATTRIB_ARRAY_TYPE, &tz); }
    BOOL ok = ex && ez && sm > 0 && sr > 0;
    LOG(@"bump maps: shader program %u %@ | tangents X at %d %@ (%d x 0x%x, stride %d), Z at %d %@ (%d x 0x%x) | placement %@, rotation %@",
        q->prog, ok ? @"fed as needed: on" : @"NOT fed as needed: off", ax, ex ? @"fed" : @"not fed", sx, tx, st, az, ez ? @"fed" : @"not fed", sz, tz,
        sm > 0 ? @"set" : @"not set", sr > 0 ? @"set" : @"not set");
    return ok;
}
static GLuint entryTexture(int e) {
    if (gEntryTex[e]) return gEntryTex[e] == ~0u ? 0 : gEntryTex[e];
    const BEntry *E = &gEntries[e];
    int bw = E->fmt == 0x93B0 ? 4 : E->fmt == 0x93B2 ? 5 : E->fmt == 0x93B4 ? 6 : 8, bh = bw;
    const uint8_t *p = (const uint8_t *)gFile.bytes + E->off, *end = p + E->size;
    GLuint t = 0; glGenTextures(1, &t);
    glActiveTexture(GL_TEXTURE0 + gUnit); glBindTexture(GL_TEXTURE_2D, t);
    while (glGetError() != GL_NO_ERROR) {}
    uint32_t w = E->w, h = E->h, m = 0;
    for (; m < E->mips; m++) {
        GLsizei n = (GLsizei)(((w + bw - 1) / bw) * ((h + bh - 1) / bh) * 16);
        if (p + n > end) break;
        glCompressedTexImage2D(GL_TEXTURE_2D, (GLint)m, E->fmt, (GLsizei)w, (GLsizei)h, 0, n, p);
        p += n; w = w > 1 ? w / 2 : 1; h = h > 1 ? h / 2 : 1;
    }
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    GLfloat an = 0; glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, &an); if (an > 1) glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT, MIN(an, 16));
    GLenum err = glGetError();
    gUnitTex = t; ibfix_wound_forget_unit();                    // left bound on our unit
    glActiveTexture(GL_TEXTURE0 + ibfix_active_unit());
    if (err != GL_NO_ERROR || m != E->mips) { LOG(@"bump maps: bump map #%d didn't upload (GL error 0x%x)", e, err); glDeleteTextures(1, &t); gUnitTex = 0; gEntryTex[e] = ~0u; return 0; }
    gEntryTex[e] = t;
    return t;
}
// wound.m shares our unit (its layers go on enemies' skins, which have no bump maps): whoever binds tells the other
void ibfix_bump_forget_unit(void) { gUnitTex = 0; }
// post.m: just before each draw, with the program in use
void ibfix_bump_before_draw(GLuint prog) {
    if (!gOn || !prog) return;
    Prog *q = progInfo(prog);
    if (!q || q->locShine < 0 || q->state == 2) return;
    GLint baseUnit = 0; if (q->locBase >= 0) glGetUniformiv(prog, q->locBase, &baseUnit);
    int e = entryFor(ibfix_bound_2d(baseUnit));
    GLuint t = e >= 0 ? entryTexture(e) : 0;
    if (t && q->state == 0) { q->state = check(q) ? 1 : 2; if (q->state == 1 && q->locNormal >= 0) glUniform1i(q->locNormal, gUnit); }
    if (!t || q->state != 1 || gLookBump == 3) { if (q->last != -1) { glUniform4f(q->locShine, 0, 0, 0, 0); q->last = -1; } return; }
    if (gUnitTex != t) {
        glActiveTexture(GL_TEXTURE0 + gUnit); glBindTexture(GL_TEXTURE_2D, t); glActiveTexture(GL_TEXTURE0 + ibfix_active_unit());
        gUnitTex = t; ibfix_wound_forget_unit();
    }
    if (q->last != e || q->lastLook != gLookBump) {
        const float *p = gEntries[e].p;
        glUniform4f(q->locShine, gLookBump == 1 ? 0 : p[0], p[1], p[2], p[3]);
        glUniform4f(q->locLight, p[5], p[6], p[7], gLookBump == 2 ? 0 : p[4]);
        q->last = e; q->lastLook = gLookBump;
    }
}
