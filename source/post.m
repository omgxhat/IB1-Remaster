// post.m: our own effects on each frame's finished 3D picture, before the interface is drawn on top: bloom, a gentle
// filmic contrast curve and contrast-adaptive sharpening (mock-up tools/post/postfx.py; FIXES.md 32, 33). In every build.
// Run once a frame where the scene ends: its "gamma correction" copy (uniform InverseGamma) or the first draw with any
// version of the interface's shader (SimplePixelShader.glsl); a frame with no interface gets it just before it is shown.
// A multisampled framebuffer is resolved into our texture, and the result drawn back into every sample (smoothing kept).
// Every piece of OpenGL state touched is put back exactly (the engine keeps its own copy and must never find it changed);
// an error skips the frame, and after six the effect stays off for the session.
// (gltrace.m, test tools only, interposes some of the same calls; the two aren't built together.)

#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>


#include "ibfix.h"

static const float kBloom = 0.175f, kThreshold = 0.55f, kContrast = 0.25f, kSharpen = 0.5f;   // as in the mock-up, but:
// the bloom at half the mock-up's 0.35, which lands on the original game's brightness (FIXES.md 105).
// kOldBloom: test builds' look sets only, to compare.
static const float kOldBloom = 0.35f;
static BOOL gOff, gDoneThisFrame;
// Test builds' look switch (snaps.m's look sets, FIXES.md 58): 0 as made, 1 no bloom, 2 no contrast curve, 3 no effects,
// 4 the first contrast curve, per channel (FIXES.md 103), 5 the first bloom strength (FIXES.md 105)
static int gLookFx;
#ifdef IBFIX_SNAPS
void ibfix_look_fx(int mode) { gLookFx = mode; }
#endif
static GLuint gGammaShader, gGammaProg, gCurProg;
static int gFrames, gRanAfterGamma, gRanBeforeUI, gRanAtEnd, gLateDraws, gLateFrames;
// every version of the interface's shader, and every program built with one (GL reuses names, so a name is dropped
// again when the game creates a new shader or program under it)
#define kMaxSimple 64
static GLuint gSimpleShaders[kMaxSimple], gSimpleProgs[kMaxSimple]; static int gSimpleShaderN, gSimpleProgN;
static BOOL inSet(const GLuint *set, int n, GLuint x) { for (int i = 0; i < n; i++) if (set[i] == x) return YES; return NO; }
static void addTo(GLuint *set, int *n, GLuint x) { if (x && !inSet(set, *n, x) && *n < kMaxSimple) set[(*n)++] = x; }
static void dropFrom(GLuint *set, int *n, GLuint x) { for (int i = 0; i < *n; i++) if (set[i] == x) { set[i] = set[--(*n)]; return; } }

// ---- shaders --------------------------------------------------------------------------------
static const char *kVS =
    "attribute vec2 P; varying vec2 UV; void main() { UV = P * 0.5 + 0.5; gl_Position = vec4(P, 0.0, 1.0); }";
static const char *kBright =                     // downsample by 2 (4 bilinear taps) + keep only what's bright
    "precision mediump float; uniform sampler2D T; uniform vec2 Px; uniform float Thr; varying vec2 UV;\n"
    "void main() { vec3 c = 0.25 * (texture2D(T, UV + vec2(-Px.x, -Px.y)).rgb + texture2D(T, UV + vec2(Px.x, -Px.y)).rgb +\n"
    "  texture2D(T, UV + vec2(-Px.x, Px.y)).rgb + texture2D(T, UV + vec2(Px.x, Px.y)).rgb);\n"
    "  vec3 l = c * c; float y = dot(l, vec3(0.2126, 0.7152, 0.0722));\n"
    "  gl_FragColor = vec4(l * clamp((y - Thr) / (1.0 - Thr), 0.0, 1.0), 1.0); }";
static const char *kDown =                       // downsample by 2
    "precision mediump float; uniform sampler2D T; uniform vec2 Px; varying vec2 UV;\n"
    "void main() { gl_FragColor = 0.25 * (texture2D(T, UV + vec2(-Px.x, -Px.y)) + texture2D(T, UV + vec2(Px.x, -Px.y)) +\n"
    "  texture2D(T, UV + vec2(-Px.x, Px.y)) + texture2D(T, UV + vec2(Px.x, Px.y))); }";
static const char *kBlur =                       // 9-tap Gaussian in one direction (5 bilinear taps)
    "precision mediump float; uniform sampler2D T; uniform vec2 Dir; varying vec2 UV;\n"
    "void main() { vec4 s = texture2D(T, UV) * 0.2270270;\n"
    "  s += (texture2D(T, UV + Dir * 1.3846154) + texture2D(T, UV - Dir * 1.3846154)) * 0.3162162;\n"
    "  s += (texture2D(T, UV + Dir * 3.2307692) + texture2D(T, UV - Dir * 3.2307692)) * 0.0702703;\n"
    "  gl_FragColor = s; }";
static const char *kComposite =                  // scene + bloom, filmic curve, sharpening
    "precision mediump float; uniform sampler2D S, B1, B2, B3; uniform vec2 Px; uniform vec4 K; varying vec2 UV;\n"
    "void main() { vec3 c = texture2D(S, UV).rgb;\n"
    "  vec3 n = texture2D(S, UV + vec2(0.0, Px.y)).rgb, s = texture2D(S, UV - vec2(0.0, Px.y)).rgb;\n"
    "  vec3 e = texture2D(S, UV + vec2(Px.x, 0.0)).rgb, w = texture2D(S, UV - vec2(Px.x, 0.0)).rgb;\n"
    "  vec3 mn = min(c, min(min(n, s), min(e, w))), mx = max(c, max(max(n, s), max(e, w)));\n"
    "  vec3 amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, vec3(0.001)), 0.0, 1.0));\n"
    "  c = c + K.w * amp * (c - 0.25 * (n + s + e + w));\n"
    "  vec3 l = c * c + K.x * (0.5 * texture2D(B1, UV).rgb + 0.3 * texture2D(B2, UV).rgb + 0.2 * texture2D(B3, UV).rgb);\n"
    "  c = sqrt(clamp(l, 0.0, 1.0));\n"
    "  float y = dot(c, vec3(0.2126, 0.7152, 0.0722)), y2 = y + K.z * (y - 0.5) * (1.0 - abs(2.0 * y - 1.0));\n"
    "  c = mix(c * (y2 / max(y, 0.001)), c + K.z * (c - 0.5) * (1.0 - abs(2.0 * c - 1.0)), K.y);\n"
    "  gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0); }";
// (gamma 2.0 instead of 2.2: squares and square roots are exact and cheap; the mock-up looks the same)
// The contrast curve on brightness only, the colour scaled with it, so every colour keeps its hue and strength: the
// first one bent red, green and blue apart, which made warm light too yellow (FIXES.md 103). K.y 1: that first,
// per-channel curve (test builds' look sets only, to compare).

static GLuint compile(GLenum kind, const char *src) {
    GLuint s = glCreateShader(kind); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512] = {0}; glGetShaderInfoLog(s, sizeof log, NULL, log); LOG(@"effects OFF: a shader didn't compile: %s", log); glDeleteShader(s); return 0; }
    return s;
}
static GLuint program(const char *fs) {
    GLuint v = compile(GL_VERTEX_SHADER, kVS), f = compile(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram(); glAttachShader(p, v); glAttachShader(p, f); glBindAttribLocation(p, 0, "P"); glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    glDeleteShader(v); glDeleteShader(f);
    if (!ok) { LOG(@"effects OFF: a program didn't link"); glDeleteProgram(p); return 0; }
    return p;
}

// ---- our textures: the scene copy (full size), then 1/2, 1/4, 1/8, 1/16, 1/32, and a blur partner for the last three
typedef struct { GLuint tex, fbo; int w, h; } Target;
static Target gScene, gL[6], gTmp[6];
static GLuint gPBright, gPDown, gPBlur, gPComp;
static int gW, gH;
static BOOL target(Target *t, int w, int h) {
    t->w = w; t->h = h;
    glGenTextures(1, &t->tex); glBindTexture(GL_TEXTURE_2D, t->tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &t->fbo); glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->tex, 0);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}
static BOOL setup(int w, int h) {
    gPBright = program(kBright); gPDown = program(kDown); gPBlur = program(kBlur); gPComp = program(kComposite);
    if (!gPBright || !gPDown || !gPBlur || !gPComp) return NO;
    BOOL ok = target(&gScene, w, h);
    for (int i = 0; i < 6 && ok; i++) {
        int lw = MAX(1, w >> (i + 1)), lh = MAX(1, h >> (i + 1));
        ok = target(&gL[i], lw, lh) && (i < 3 || target(&gTmp[i], lw, lh));
    }
    if (!ok) LOG(@"effects OFF: our framebuffers aren't complete");
    gW = w; gH = h;
    return ok;
}

// ---- the state we touch, saved and put back --------------------------------------------------
typedef struct {
    GLint prog, active, tex[4], drawFB, readFB, rb, viewport[4], arrayBuf, vao;
    GLboolean blend, depth, cull, scissor, stencil, dither, colorMask[4], depthMask;
    GLint attrEnabled[16]; GLint a0buf, a0size, a0type, a0stride, a0norm; GLvoid *a0ptr;
} GLState;
static void save(GLState *s) {
    glGetIntegerv(GL_CURRENT_PROGRAM, &s->prog); glGetIntegerv(GL_ACTIVE_TEXTURE, &s->active);
    for (int u = 0; u < 4; u++) { glActiveTexture(GL_TEXTURE0 + u); glGetIntegerv(GL_TEXTURE_BINDING_2D, &s->tex[u]); }
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_APPLE, &s->drawFB); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_APPLE, &s->readFB);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &s->rb); glGetIntegerv(GL_VIEWPORT, s->viewport);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING_OES, &s->vao); glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &s->arrayBuf);
    s->blend = glIsEnabled(GL_BLEND); s->depth = glIsEnabled(GL_DEPTH_TEST); s->cull = glIsEnabled(GL_CULL_FACE);
    s->scissor = glIsEnabled(GL_SCISSOR_TEST); s->stencil = glIsEnabled(GL_STENCIL_TEST); s->dither = glIsEnabled(GL_DITHER);
    glGetBooleanv(GL_COLOR_WRITEMASK, s->colorMask); glGetBooleanv(GL_DEPTH_WRITEMASK, &s->depthMask);
    if (s->vao) glBindVertexArrayOES(0);
    for (int i = 0; i < 16; i++) glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &s->attrEnabled[i]);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &s->a0buf); glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &s->a0size);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &s->a0type); glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &s->a0stride);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &s->a0norm); glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &s->a0ptr);
}
static void restore(const GLState *s) {
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)s->a0buf);
    glVertexAttribPointer(0, s->a0size, (GLenum)s->a0type, (GLboolean)s->a0norm, s->a0stride, s->a0ptr);
    for (int i = 0; i < 16; i++) { if (s->attrEnabled[i]) glEnableVertexAttribArray(i); else glDisableVertexAttribArray(i); }
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)s->arrayBuf);
    if (s->vao) glBindVertexArrayOES((GLuint)s->vao);
    (s->blend ? glEnable : glDisable)(GL_BLEND); (s->depth ? glEnable : glDisable)(GL_DEPTH_TEST);
    (s->cull ? glEnable : glDisable)(GL_CULL_FACE); (s->scissor ? glEnable : glDisable)(GL_SCISSOR_TEST);
    (s->stencil ? glEnable : glDisable)(GL_STENCIL_TEST); (s->dither ? glEnable : glDisable)(GL_DITHER);
    glColorMask(s->colorMask[0], s->colorMask[1], s->colorMask[2], s->colorMask[3]); glDepthMask(s->depthMask);
    glViewport(s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3]);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, (GLuint)s->drawFB); glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, (GLuint)s->readFB);
    glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)s->rb);
    for (int u = 0; u < 4; u++) { glActiveTexture(GL_TEXTURE0 + u); glBindTexture(GL_TEXTURE_2D, (GLuint)s->tex[u]); }
    glActiveTexture((GLenum)s->active); glUseProgram((GLuint)s->prog);
}

static const GLfloat kQuad[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
static void pass(GLuint prog, Target *dst, GLuint src, float pxx, float pxy) {
    glBindFramebuffer(GL_FRAMEBUFFER, dst->fbo); glViewport(0, 0, dst->w, dst->h);
    glUseProgram(prog); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, src);
    glUniform1i(glGetUniformLocation(prog, "T"), 0);
    GLint px = glGetUniformLocation(prog, "Px"), dir = glGetUniformLocation(prog, "Dir"), thr = glGetUniformLocation(prog, "Thr");
    if (px >= 0) glUniform2f(px, pxx, pxy);
    if (dir >= 0) glUniform2f(dir, pxx, pxy);
    if (thr >= 0) glUniform1f(thr, kThreshold);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// Which step failed, with the framebuffer's details (first few times only).
static int gErrors;
static BOOL stepOK(const char *step, const GLState *st) {
    GLenum e = glGetError(); if (e == GL_NO_ERROR) return YES;
    if (++gErrors <= 6) {
        GLint samples = 0, fmt = 0, w = 0, h = 0, obj = 0, kind = 0;
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)st->drawFB); glGetIntegerv(GL_SAMPLES, &samples);
        glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &kind);
        glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &obj);
        if (kind == GL_RENDERBUFFER) { glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)obj);
            glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_INTERNAL_FORMAT, &fmt);
            glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w); glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h); }
        while (glGetError() != GL_NO_ERROR) {}
        LOG(@"effects: OpenGL error 0x%x at %s | game framebuffer %d (read %d), %d samples, colour %s %d (format 0x%x) %dx%d, viewport %d,%d %dx%d",
            e, step, st->drawFB, st->readFB, samples, kind == GL_RENDERBUFFER ? "renderbuffer" : kind == GL_TEXTURE ? "texture" : "none", obj, fmt, w, h,
            st->viewport[0], st->viewport[1], st->viewport[2], st->viewport[3]);
    }
    if (gErrors >= 6) { gOff = YES; LOG(@"effects OFF: six errors"); }
    return NO;
}

// The effect, on the framebuffer the game is drawing into (its scene just finished).
static void runEffects(void) {
    if (gLookFx == 3) return;
    GLState st; save(&st);
    GLint vw = st.viewport[2], vh = st.viewport[3];
    if (vw < 64 || vh < 64) { restore(&st); return; }
    if (!gW && !setup(vw, vh)) { gOff = YES; restore(&st); return; }
    if (vw != gW || vh != gH) { restore(&st); return; }        // a different size (a cutscene's own buffer): leave it
    while (glGetError() != GL_NO_ERROR) {}
    glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE); glDisable(GL_SCISSOR_TEST); glDisable(GL_STENCIL_TEST);
    glColorMask(1, 1, 1, 1); glDepthMask(GL_FALSE);
    for (int i = 0; i < 16; i++) glDisableVertexAttribArray(i);
    glBindBuffer(GL_ARRAY_BUFFER, 0); glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, kQuad);
    // 1. the scene into our texture: resolve (multisampled) or copy
    if (!stepOK("setting up", &st)) { restore(&st); return; }
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)st.drawFB);
    GLint samples = 0; glGetIntegerv(GL_SAMPLES, &samples);
    if (samples > 0) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER_APPLE, (GLuint)st.drawFB); glBindFramebuffer(GL_DRAW_FRAMEBUFFER_APPLE, gScene.fbo);
        glResolveMultisampleFramebufferAPPLE();
        if (!stepOK("resolving the multisampled scene", &st)) { restore(&st); return; }
    } else {
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, gScene.tex);
        glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, st.viewport[0], st.viewport[1], vw, vh);
        if (!stepOK("copying the scene", &st)) { restore(&st); return; }
    }
    // 2. bloom: bright pass at 1/2, down to 1/32; blur the 1/8, 1/16 and 1/32 levels
    pass(gPBright, &gL[0], gScene.tex, 0.5f / vw, 0.5f / vh);
    for (int i = 1; i < 6; i++) pass(gPDown, &gL[i], gL[i - 1].tex, 0.5f / gL[i - 1].w, 0.5f / gL[i - 1].h);
    for (int i = 3; i < 6; i++) {
        pass(gPBlur, &gTmp[i], gL[i].tex, 1.0f / gL[i].w, 0);
        pass(gPBlur, &gL[i], gTmp[i].tex, 0, 1.0f / gL[i].h);
    }
    if (!stepOK("the bloom passes", &st)) { restore(&st); return; }
    // 3. back into the game's framebuffer: scene + bloom, contrast, sharpening
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)st.drawFB); glViewport(st.viewport[0], st.viewport[1], vw, vh);
    glUseProgram(gPComp);
    GLuint tx[4] = { gScene.tex, gL[3].tex, gL[4].tex, gL[5].tex }; const char *nm[4] = { "S", "B1", "B2", "B3" };
    for (int u = 0; u < 4; u++) { glActiveTexture(GL_TEXTURE0 + u); glBindTexture(GL_TEXTURE_2D, tx[u]); glUniform1i(glGetUniformLocation(gPComp, nm[u]), u); }
    glUniform2f(glGetUniformLocation(gPComp, "Px"), 1.0f / vw, 1.0f / vh);
    glUniform4f(glGetUniformLocation(gPComp, "K"), gLookFx == 1 ? 0 : gLookFx == 5 ? kOldBloom : kBloom, gLookFx == 4 ? 1 : 0, gLookFx == 2 ? 0 : kContrast, kSharpen);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    BOOL ok = stepOK("drawing back into the game's picture", &st);
    restore(&st);
    if (ok && stepOK("putting the game's state back", &st)) { static BOOL said; if (!said) { said = YES; LOG(@"effects: first frame done (%dx%d, %d samples)", vw, vh, samples); } }
}

// ---- bump maps (bump.m; these stand-ins do nothing when it isn't built) --------------------------------------
__attribute__((weak)) NSString *ibfix_bump_rewrite(GLuint sh, NSString *src) { return nil; }
__attribute__((weak)) BOOL ibfix_bump_relink(GLuint prog) { return NO; }
__attribute__((weak)) void ibfix_bump_before_draw(GLuint prog) {}
__attribute__((weak)) void ibfix_bump_note_deleted(GLsizei n, const GLuint *t) {}
// lens flares hidden by what's in front (flare.m; stand-ins when it isn't built)
__attribute__((weak)) NSString *ibfix_flare_rewrite(GLuint sh, NSString *src) { return nil; }
__attribute__((weak)) void ibfix_flare_attach(GLuint p, GLuint sh) {}
__attribute__((weak)) void ibfix_flare_before_draw(GLuint prog, GLenum mode, GLsizei count, GLenum type, const GLvoid *indices, BOOL elements) {}
__attribute__((weak)) void ibfix_flare_new_frame(void) {}
__attribute__((weak)) void ibfix_flare_before_clear(GLbitfield mask) {}
// blood drawn in the 3D scene (blood.m; stand-ins when it isn't built)
__attribute__((weak)) void ibfix_blood_before_draw(GLuint prog) {}
__attribute__((weak)) void ibfix_blood_before_clear(GLbitfield mask) {}
__attribute__((weak)) void ibfix_blood_before_effects(void) {}
__attribute__((weak)) void ibfix_blood_new_frame(void) {}
// cuts on the enemies' skin (wound.m; stand-ins when it isn't built)
__attribute__((weak)) NSString *ibfix_wound_rewrite(GLuint sh, NSString *src) { return nil; }
__attribute__((weak)) void ibfix_wound_before_draw(GLuint prog) {}
__attribute__((weak)) void ibfix_wound_note_deleted(GLsizei n, const GLuint *t) {}
// the game's texture bindings, as it left them (bump.m reads which colour texture a draw uses)
static GLuint gBound2D[32]; static int gActiveUnit;
#ifdef IBFIX_SNAPS
// Diagnostic: the game's lens flares (FIXES.md 37; vertex shader LensFlareVertexShader.glsl): which shaders draw them,
// how often, how big, whether depth-tested; and the highest texture unit the game uses (bump maps take the last).
static GLuint gFlareShaders[16], gFlareProgs[16]; static int gFlareShaderN, gFlareProgN, gFlareDraws, gFlareDepthOn, gFlareVerts, gMaxUnit;
static BOOL isFlareProg(GLuint p) { for (int i = 0; i < gFlareProgN; i++) if (gFlareProgs[i] == p) return YES; return NO; }
#endif
GLuint ibfix_bound_2d(int unit) { return unit >= 0 && unit < 32 ? gBound2D[unit] : 0; }
int ibfix_active_unit(void) { return gActiveUnit; }

// ---- watching the game's renderer --------------------------------------------------------------
static void my_glShaderSource(GLuint sh, GLsizei n, const GLchar *const *src, const GLint *len) {
    NSMutableString *all = [NSMutableString string];
    for (GLsizei i = 0; i < n; i++) {
        NSString *part = len && len[i] >= 0 ? [[NSString alloc] initWithBytes:src[i] length:(NSUInteger)len[i] encoding:NSASCIIStringEncoding]
                                            : [NSString stringWithUTF8String:src[i]];
        if (part) [all appendString:part];
    }
#ifdef IBFIX_SNAPS
    if ([all containsString:@"uniform vec4 CameraRight;"] && [all containsString:@"attribute float Rotation;"] && gFlareShaderN < 16) gFlareShaders[gFlareShaderN++] = sh;   // (particles have Rotation_Sizer)
#endif
    if ([all containsString:@"InverseGamma"]) gGammaShader = sh;
    else if ([all containsString:@"PolyColor = PrimColor * BaseColor"]) {     // SimplePixelShader.glsl's own line
        if (!inSet(gSimpleShaders, gSimpleShaderN, sh)) {
            addTo(gSimpleShaders, &gSimpleShaderN, sh);
            LOG(@"effects: interface shader version %d (shader %u)", gSimpleShaderN, sh);
        }
    }
    NSString *ext = ibfix_flare_rewrite(sh, all) ?: ibfix_bump_rewrite(sh, all);   // flares (flare.m), the world's shaders (bump.m)
    NSString *wound = ibfix_wound_rewrite(sh, ext ?: all); if (wound) ext = wound; // and the enemies' cuts (wound.m)
    if (ext) { const char *c = ext.UTF8String; glShaderSource(sh, 1, &c, NULL); return; }
    glShaderSource(sh, n, src, len);
}
static void my_glLinkProgram(GLuint p) {
    glLinkProgram(p);
    GLint ok = 1; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok && ibfix_bump_relink(p)) glLinkProgram(p);         // our shaders put back as the game had them
}
static void my_glActiveTexture(GLenum u) {
    int i = (int)u - GL_TEXTURE0; if (i >= 0 && i < 32) gActiveUnit = i;
#ifdef IBFIX_SNAPS
    if (i > gMaxUnit) gMaxUnit = i;
#endif
    glActiveTexture(u);
}
static void my_glBindTexture(GLenum target, GLuint t) { if (target == GL_TEXTURE_2D) gBound2D[gActiveUnit] = t; glBindTexture(target, t); }
__attribute__((weak)) void ibfix_hd_note_deleted(GLsizei n, const GLuint *t) {}   // game.m 3e
static void my_glDeleteTextures(GLsizei n, const GLuint *t) {
    for (GLsizei i = 0; t && i < n; i++) for (int u = 0; u < 32; u++) if (gBound2D[u] == t[i]) gBound2D[u] = 0;   // GL unbinds them
    ibfix_bump_note_deleted(n, t);
    ibfix_wound_note_deleted(n, t);
    ibfix_hd_note_deleted(n, t);
    glDeleteTextures(n, t);
}
static GLuint my_glCreateShader(GLenum kind) {
    GLuint sh = glCreateShader(kind);
    dropFrom(gSimpleShaders, &gSimpleShaderN, sh); if (sh == gGammaShader) gGammaShader = 0;
    return sh;
}
static GLuint my_glCreateProgram(void) {
    GLuint p = glCreateProgram();
    dropFrom(gSimpleProgs, &gSimpleProgN, p); if (p == gGammaProg) gGammaProg = 0;
    return p;
}
static void my_glAttachShader(GLuint p, GLuint sh) {
    ibfix_flare_attach(p, sh);
#ifdef IBFIX_SNAPS
    for (int i = 0; i < gFlareShaderN; i++) if (gFlareShaders[i] == sh && gFlareProgN < 16 && !isFlareProg(p)) { gFlareProgs[gFlareProgN++] = p; LOG(@"flares: program %u draws lens flares", p); }
#endif
    if (sh && sh == gGammaShader) gGammaProg = p;
    if (sh && inSet(gSimpleShaders, gSimpleShaderN, sh) && !inSet(gSimpleProgs, gSimpleProgN, p)) {
        addTo(gSimpleProgs, &gSimpleProgN, p);
        LOG(@"effects: interface program %d (program %u)", gSimpleProgN, p);
    }
    glAttachShader(p, sh);
}
static void my_glUseProgram(GLuint p) {
    gCurProg = p;
    // the interface's first draw of the frame comes with its program: the scene before it is finished
    if (p && inSet(gSimpleProgs, gSimpleProgN, p)) ibfix_blood_before_effects();   // blood.m, part of the scene
    if (!gOff && !gDoneThisFrame && p && inSet(gSimpleProgs, gSimpleProgN, p)) { gDoneThisFrame = YES; gRanBeforeUI++; runEffects(); }
    glUseProgram(p);
}
static void afterDraw(void) {
    if (!gOff && !gDoneThisFrame && gCurProg && gCurProg == gGammaProg) { gDoneThisFrame = YES; gRanAfterGamma++; runEffects(); }
    // a draw with any other program after the effects ran: a 3D thing in front of the interface (a menu's turning
    // sword) or interface art drawn with a material; counted, so a new screen can be checked from the log
    else if (gDoneThisFrame && gCurProg != gGammaProg && !inSet(gSimpleProgs, gSimpleProgN, gCurProg)) gLateDraws++;
}
static void my_glDrawArrays(GLenum m, GLint f, GLsizei c) {
#ifdef IBFIX_SNAPS
    if (gCurProg && isFlareProg(gCurProg)) { gFlareDraws++; gFlareVerts += c; if (glIsEnabled(GL_DEPTH_TEST)) gFlareDepthOn++; }
#endif
    ibfix_flare_before_draw(gCurProg, m, c, 0, (const GLvoid *)(intptr_t)f, NO); ibfix_blood_before_draw(gCurProg);
    ibfix_bump_before_draw(gCurProg); ibfix_wound_before_draw(gCurProg); glDrawArrays(m, f, c); afterDraw();
}
static void my_glDrawElements(GLenum m, GLsizei c, GLenum t, const GLvoid *i) {
#ifdef IBFIX_SNAPS
    if (gCurProg && isFlareProg(gCurProg)) {
        gFlareDraws++; gFlareVerts += c; if (glIsEnabled(GL_DEPTH_TEST)) gFlareDepthOn++;
        static int shown; if (shown < 6) { shown++; GLint fb = 0, dm = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb); glGetIntegerv(GL_DEPTH_WRITEMASK, &dm);
            LOG(@"flares: a draw of %d indices, depth test %@, depth writes %@, framebuffer %d, %@ the effects", c, glIsEnabled(GL_DEPTH_TEST) ? @"on" : @"off", dm ? @"on" : @"off", fb, gDoneThisFrame ? @"after" : @"before"); }
    }
#endif
    ibfix_flare_before_draw(gCurProg, m, c, t, i, YES); ibfix_blood_before_draw(gCurProg);
    ibfix_bump_before_draw(gCurProg); ibfix_wound_before_draw(gCurProg); glDrawElements(m, c, t, i); afterDraw();
}

static void my_glClear(GLbitfield m) { ibfix_blood_before_clear(m); ibfix_flare_before_clear(m); glClear(m); }   // blood.m draws and flare.m asks before the world's depth goes

INTERPOSE(kPostInterpose) = {
    { (const void *)my_glShaderSource, (const void *)glShaderSource },
    { (const void *)my_glAttachShader, (const void *)glAttachShader },
    { (const void *)my_glCreateShader, (const void *)glCreateShader },
    { (const void *)my_glCreateProgram, (const void *)glCreateProgram },
    { (const void *)my_glUseProgram,   (const void *)glUseProgram },
    { (const void *)my_glDrawArrays,   (const void *)glDrawArrays },
    { (const void *)my_glDrawElements, (const void *)glDrawElements },
    { (const void *)my_glLinkProgram,  (const void *)glLinkProgram },
    { (const void *)my_glActiveTexture, (const void *)glActiveTexture },
    { (const void *)my_glBindTexture,  (const void *)glBindTexture },
    { (const void *)my_glDeleteTextures, (const void *)glDeleteTextures },
    { (const void *)my_glClear,        (const void *)glClear },
};

// a new frame starts after each present
static IMP gOrigPresent;
static volatile BOOL gFilmCovering;         // the start-up film is on screen (kept by a main-thread timer)
static BOOL filmOnScreen(void) {            // as ibfix.m: the app delegate holds the film player while it shows
    id del = [UIApplication sharedApplication].delegate; SEL s = NSSelectorFromString(@"MoviePlayer");
    return [del respondsToSelector:s] && ((id (*)(id, SEL))objc_msgSend)(del, s) != nil;
}
static BOOL my_present(id self, SEL _cmd, NSUInteger target) {
    // no interface this frame: the effect on the finished picture, just before it is shown (only once the effect has
    // run normally, so its sizes come from the game's real picture, and only on the game's own context)
    if (!gFilmCovering && [EAGLContext currentContext] == self) ibfix_blood_before_effects();   // blood.m, if nothing came first
    if (!gOff && !gDoneThisFrame && gW && !gFilmCovering && [EAGLContext currentContext] == self) { gRanAtEnd++; runEffects(); }
    BOOL r = ((BOOL (*)(id, SEL, NSUInteger))gOrigPresent)(self, _cmd, target);
    if (gLateDraws) { gLateFrames++; gLateDraws = 0; }
    ibfix_flare_new_frame(); ibfix_blood_new_frame();
    gDoneThisFrame = NO;
    if (++gFrames % 300 == 0) LOG(@"effects: %s | of the last 300 frames, after the scene's gamma pass %d, before the interface %d, "
                                  "at the frame's end %d, with other draws after the effects %d | interface versions %d, programs %d",
                                  gOff ? "OFF" : "on", gRanAfterGamma, gRanBeforeUI, gRanAtEnd, gLateFrames, gSimpleShaderN, gSimpleProgN);
    if (gFrames % 300 == 0) gRanAfterGamma = gRanBeforeUI = gRanAtEnd = gLateFrames = 0;
#ifdef IBFIX_SNAPS
    if (gFrames % 300 == 0) {
        if (gFlareDraws) LOG(@"flares: %d draws in the last 300 frames (%.0f indices each), depth test on in %d | highest texture unit the game uses: %d", gFlareDraws, (double)gFlareVerts / gFlareDraws, gFlareDepthOn, gMaxUnit);
        else LOG(@"flares: none in the last 300 frames | highest texture unit the game uses: %d", gMaxUnit);
        gFlareDraws = gFlareDepthOn = gFlareVerts = 0;
    }
#endif
    return r;
}
__attribute__((constructor)) static void post_init(void) {
    // after snaps.m's own hook of the same method (if any), so both run: each keeps the one before it
    dispatch_async(dispatch_get_main_queue(), ^{
        gOrigPresent = hookMethod([EAGLContext class], @selector(presentRenderbuffer:), (IMP)my_present);
        LOG(@"effects ON: bloom %.2f, contrast %.2f, sharpening %.2f", kBloom, kContrast, kSharpen);
        // watch for the start-up film (behind it the effect only takes the graphics chip from the film): until it has
        // come and gone, with no time limit while it shows (FIXES.md 33), or for the first minute if it never shows.
        gFilmCovering = filmOnScreen();
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
        __block BOOL seen = NO; __block int ticks = 0;
        dispatch_source_set_event_handler(t, ^{
            BOOL on = filmOnScreen(); gFilmCovering = on; seen |= on;
            if ((seen && !on) || (!seen && ++ticks > 600)) { dispatch_source_cancel(t); LOG(@"effects: start-up film %s", seen ? "gone" : "not shown"); }
        });
        dispatch_resume(t);
        static dispatch_source_t keep; keep = t;
    });
}
