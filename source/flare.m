// flare.m: lens flares hidden by what's in front of them, as on the PC, with the GL occlusion queries the iPhone build
// never makes (FIXES.md 37, 40). In every build. The source (the flare's LensFlareComponent, found by game.m) is matched
// to the flare by where it lands on screen against the first piece (the pieces sit close in front of the camera).
// The sun's flare is drawn after the world's depth is cleared (foreground layer) and its source is 900 m out, so the
// question is whether anything nearer than 30% of the way is in front of its spot: nine dots, each its own query, asked
// before that clear if the frame has one, else at the flare's draw. Later frames read the answers (never waiting) and
// every piece fades by the share that is clear. A source not found or not lined up leaves the flare as the game drew it.
// Hooks in post.m (shaders, programs, draws, clears, frames).

#import <Foundation/Foundation.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>


#include "ibfix.h"

static int gState;                                // 0 unchecked, 1 on, 2 off
static BOOL flaresOn(void) {
    if (gState == 0) {
        const char *ext = (const char *)glGetString(GL_EXTENSIONS);
        gState = ext && strstr(ext, "GL_EXT_occlusion_query_boolean") ? 1 : 2;
        LOG(@"flares: hidden by what's in front %@", gState == 1 ? @"ON (occlusion queries)" : @"OFF (no occlusion queries on this device)");
    }
    return gState == 1;
}

// ---- the flare's shaders ----------------------------------------------------------------------------------------
static NSMutableDictionary<NSNumber *, NSString *> *gFlareVS;   // flare vertex shaders: their source (for the query copy)
static BOOL isFlareVS(NSString *src) { return [src containsString:@"uniform vec4 CameraRight;"] && [src containsString:@"attribute float Rotation;"]; }
static BOOL compiles(GLenum kind, NSString *src) {
    GLuint s = glCreateShader(kind); const char *c = src.UTF8String;
    glShaderSource(s, 1, &c, NULL); glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024] = {0}; glGetShaderInfoLog(s, sizeof log, NULL, log); LOG(@"flares: a shader didn't compile: %s", log); }
    glDeleteShader(s);
    return ok != 0;
}
// the flare's own vertex shader, its colour scaled by 1 - ibfixFlareHide (uniforms start at 0: unset = as the game drew it)
NSString *ibfix_flare_rewrite(GLuint sh, NSString *src) {
    if (!isFlareVS(src) || !flaresOn()) return nil;
    NSRange m = [src rangeOfString:@"void main()"], end = [src rangeOfString:@"}" options:NSBackwardsSearch];
    if (m.location == NSNotFound || end.location == NSNotFound || end.location < m.location || ![src containsString:@"Interp_Color"]) return nil;
    NSMutableString *out = [src mutableCopy];
    [out insertString:@"Interp_Color *= ( 1.0 - ibfixFlareHide );\n" atIndex:end.location];
    [out insertString:@"uniform lowp float ibfixFlareHide;\n" atIndex:m.location];
    if (!compiles(GL_VERTEX_SHADER, out)) return nil;
    if (!gFlareVS) gFlareVS = [NSMutableDictionary dictionary];
    gFlareVS[@(sh)] = [src copy];
    return out;
}

// ---- flare programs, and the one query program --------------------------------------------------------------------
typedef struct { GLuint prog; GLint hide, l2w, vp, pos, tex; } Flare;
static Flare gFlares[32]; static int gNFlares;
static Flare *flareFor(GLuint p) { for (int i = 0; i < gNFlares; i++) if (gFlares[i].prog == p) return &gFlares[i]; return NULL; }
void ibfix_flare_attach(GLuint p, GLuint sh) {
    if (!gFlareVS[@(sh)] || flareFor(p) || gNFlares >= 32) return;
    gFlares[gNFlares++] = (Flare){ .prog = p, .hide = -2 };
}
// the test dots: a patch of the screen around the source's spot, at a point on the way to the source (kept inside the far
// plane), from our own vertices (attribute 0, put back after)
#define kGrid 9
#define kPatch 0.025f                             // the patch's half-height, a share of the screen's height
static const GLfloat kDots[(kGrid + 1) * 12] = {   // nine 3 x 3 squares, two triangles each, then one in the middle (the ladder)
#define SQ(x, y) x - 0.3f, y - 0.3f, x + 0.3f, y - 0.3f, x + 0.3f, y + 0.3f,  x - 0.3f, y - 0.3f, x + 0.3f, y + 0.3f, x - 0.3f, y + 0.3f
    SQ(-1, -1), SQ(0, -1), SQ(1, -1), SQ(-1, 0), SQ(0, 0), SQ(1, 0), SQ(-1, 1), SQ(0, 1), SQ(1, 1), SQ(0, 0)
#undef SQ
};
static GLuint gQProg; static GLint gQVp, gQPoint, gQScale;
static BOOL queryProgram(void) {
    if (gQProg) return YES;
    const char *vs = "attribute vec2 ibfixCorner;\nuniform mat4 ViewProjection;\nuniform vec3 ibfixPoint;\nuniform vec2 ibfixScale;\n"
                     "void main() {\nvec4 p = ViewProjection * vec4( ibfixPoint, 1.0 );\n"
                     "p.xy += ibfixCorner * ibfixScale * p.w;\np.z = min( p.z, p.w * 0.99999 );\ngl_Position = p;\n}\n";
    const char *fs = "precision mediump float;\nvoid main() { gl_FragColor = vec4( 0.0 ); }\n";
    GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER), q = glCreateProgram();
    glShaderSource(v, 1, &vs, NULL); glCompileShader(v); glShaderSource(f, 1, &fs, NULL); glCompileShader(f);
    glAttachShader(q, v); glAttachShader(q, f); glBindAttribLocation(q, 0, "ibfixCorner");
    glLinkProgram(q); glDeleteShader(v); glDeleteShader(f);
    GLint ok = 0; glGetProgramiv(q, GL_LINK_STATUS, &ok);
    if (!ok) { char log[1024] = {0}; glGetProgramInfoLog(q, sizeof log, NULL, log); LOG(@"flares: the test dots' program didn't link: %s", log); glDeleteProgram(q); return NO; }
    gQProg = q;
    gQVp = glGetUniformLocation(q, "ViewProjection"); gQPoint = glGetUniformLocation(q, "ibfixPoint"); gQScale = glGetUniformLocation(q, "ibfixScale");
    return YES;
}

// ---- where the source is ----------------------------------------------------------------------------------------
int ibfix_objects_of_class(const char *cls, void **out, int max);   // game.m
BOOL ibfix_component_location(void *comp, float out[3]);             // game.m
BOOL ibfix_camera_location(float out[3]);                           // game.m
__attribute__((weak)) void ibfix_snap(NSString *label) {}
__attribute__((weak)) BOOL ibfix_auto_photos(void) { return NO; }   // snaps.m takes the pictures in test builds, when switched on (FIXES.md 98)

static void project(const GLfloat *m, const float p[4], float clip[4]) {   // a column-major GL matrix times a point
    for (int i = 0; i < 4; i++) clip[i] = m[i] * p[0] + m[4 + i] * p[1] + m[8 + i] * p[2] + m[12 + i] * p[3];
}
// The first piece's spot on screen, from the game's own vertex data (a client-side array: Position, as floats)
static BOOL pieceSpot(Flare *f, GLint first, const GLfloat *l2w, const GLfloat *vp, float ndc[2]) {
    if (f->pos < 0) return NO;
    GLint on = 0, buf = 0, size = 0, type = 0, stride = 0; GLvoid *ptr = NULL;
    glGetVertexAttribiv((GLuint)f->pos, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &on); glGetVertexAttribiv((GLuint)f->pos, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &buf);
    glGetVertexAttribiv((GLuint)f->pos, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size); glGetVertexAttribiv((GLuint)f->pos, GL_VERTEX_ATTRIB_ARRAY_TYPE, &type);
    glGetVertexAttribiv((GLuint)f->pos, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &stride); glGetVertexAttribPointerv((GLuint)f->pos, GL_VERTEX_ATTRIB_ARRAY_POINTER, &ptr);
    if (!on || buf || !ptr || type != GL_FLOAT || size < 3) return NO;
    const float *v = (const float *)((const uint8_t *)ptr + first * (stride ? stride : size * 4));
    float p[4] = { v[0], v[1], v[2], size > 3 ? v[3] : 1 }, w[4], c[4];
    project(l2w, p, w); project(vp, w, c);
    if (c[3] <= 0) return NO;
    ndc[0] = c[0] / c[3]; ndc[1] = c[1] / c[3];
    return YES;
}
// The source nearest the first piece on screen, in the shaders' own space (positions measured from the camera, or not:
// whichever lines up). NO if none does.
static void *gComps[8]; static int gNComps; static double gCompsAt;
static int gSpace = -1;                           // 1: measured from the camera, 0: absolute; -1: not settled yet
static BOOL sourceFor(Flare *f, GLint first, const GLfloat *l2w, const GLfloat *vp, float src[3], float eye[3], float *miss) {
    double t = CFAbsoluteTimeGetCurrent();
    if (t - gCompsAt > 2) { gCompsAt = t; gNComps = ibfix_objects_of_class("LensFlareComponent", gComps, 8); }
    float cam[3]; BOOL camOK = ibfix_camera_location(cam), havePiece; float piece[2];
    havePiece = pieceSpot(f, first, l2w, vp, piece);
    float best = 1e9; BOOL found = NO;
    for (int i = 0; i < gNComps; i++) {
        float L[3]; if (!ibfix_component_location(gComps[i], L)) continue;
        for (int space = 1; space >= 0; space--) {
            if (space && !camOK) continue;
            if (gSpace >= 0 && space != gSpace) continue;
            float s[4] = { L[0] - (space ? cam[0] : 0), L[1] - (space ? cam[1] : 0), L[2] - (space ? cam[2] : 0), 1 }, c[4];
            project(vp, s, c);
            if (c[3] <= 0) continue;                        // behind the camera
            float d = havePiece ? hypotf(c[0] / c[3] - piece[0], c[1] / c[3] - piece[1]) : 0;
            if (d < best) {
                best = d; memcpy(src, s, sizeof(float) * 3); found = YES; if (havePiece && d < 0.1f && gSpace < 0) gSpace = space;
                for (int j = 0; j < 3; j++) eye[j] = space ? 0 : cam[j];     // the camera, in the same space
            }
        }
    }
    *miss = havePiece ? best : -1;
    return found && (!havePiece || best < 0.1f);
}

// ---- the questions ------------------------------------------------------------------------------------------------
#define kSlots 16
typedef struct {
    GLuint q[kGrid]; BOOL pending; float vis;     // the nine answers being waited for; the share shown, eased
    BOOL have; int frame; float src[3], eye[3]; GLfloat vp[16], scale[2];   // the source and view last seen at the flare's draw
    GLuint ladder[4]; BOOL ladderPending;         // test builds: what's in front at 5%, 30%, 70%, 100% of the way
} Slot;
static Slot gSlots[kSlots];
static int gFrame, gSlot, gRunFirst = -1;         // the frame; the next run's slot; the current run's slot (-1 between runs)
static int gDrawsThisFrame, gFlareFB = -1; static BOOL gClearedAfterWorld;
static int gDraws, gHidden, gNoSource, gAtClear, gAtDraw, gClearFrames; static double gVisSum;
static const float kLadder[4] = { 0.05f, 0.3f, 0.7f, 1.0f };

// one patch of dots at a point a share of the way from the camera to the source, each dot its own query (or only the
// middle one, for the ladder); everything touched is put back
static void ask(Slot *r, float share, GLuint *queries, int n, int firstDot) {
    if (!queryProgram()) { gState = 2; return; }
    GLint prog, ab, vao = 0, df, a0on, a0buf, a0size, a0type, a0stride, a0norm; GLvoid *a0ptr;
    GLboolean cm[4], dm, dt = glIsEnabled(GL_DEPTH_TEST), cf = glIsEnabled(GL_CULL_FACE), sc = glIsEnabled(GL_SCISSOR_TEST), st = glIsEnabled(GL_STENCIL_TEST);
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog); glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &ab); glGetIntegerv(GL_VERTEX_ARRAY_BINDING_OES, &vao);
    glGetIntegerv(GL_DEPTH_FUNC, &df); glGetBooleanv(GL_COLOR_WRITEMASK, cm); glGetBooleanv(GL_DEPTH_WRITEMASK, &dm);
    if (vao) glBindVertexArrayOES(0);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a0on); glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &a0buf);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a0size); glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a0type);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a0stride); glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a0norm);
    glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &a0ptr);

    float pt[3]; for (int j = 0; j < 3; j++) pt[j] = r->eye[j] + share * (r->src[j] - r->eye[j]);
    glUseProgram(gQProg);
    glUniformMatrix4fv(gQVp, 1, GL_FALSE, r->vp); glUniform3fv(gQPoint, 1, pt); glUniform2fv(gQScale, 1, r->scale);
    glBindBuffer(GL_ARRAY_BUFFER, 0); glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, kDots);
    glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE); glDepthMask(GL_FALSE); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LEQUAL);
    glDisable(GL_CULL_FACE); glDisable(GL_SCISSOR_TEST); glDisable(GL_STENCIL_TEST);
    for (int i = 0; i < n; i++) {
        glBeginQueryEXT(GL_ANY_SAMPLES_PASSED_CONSERVATIVE_EXT, queries[i]);
        glDrawArrays(GL_TRIANGLES, (firstDot + i) * 6, 6);
        glEndQueryEXT(GL_ANY_SAMPLES_PASSED_CONSERVATIVE_EXT);
    }

    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)a0buf); glVertexAttribPointer(0, a0size, (GLenum)a0type, (GLboolean)a0norm, a0stride, a0ptr);
    if (a0on) glEnableVertexAttribArray(0); else glDisableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)ab); if (vao) glBindVertexArrayOES((GLuint)vao);
    glColorMask(cm[0], cm[1], cm[2], cm[3]); glDepthMask(dm); glDepthFunc((GLenum)df);
    (dt ? glEnable : glDisable)(GL_DEPTH_TEST); (cf ? glEnable : glDisable)(GL_CULL_FACE);
    (sc ? glEnable : glDisable)(GL_SCISSOR_TEST); (st ? glEnable : glDisable)(GL_STENCIL_TEST);
    glUseProgram((GLuint)prog);
}
static void askSlot(Slot *r) {
    if (!r->q[0]) glGenQueriesEXT(kGrid, r->q);
    ask(r, 0.3f, r->q, kGrid, 0); r->pending = YES;
#ifdef IBFIX_SNAPS
    static int ladderFrame = -1000;
    if (r == &gSlots[0] && !r->ladderPending && gFrame - ladderFrame >= 120) {
        ladderFrame = gFrame;
        if (!r->ladder[0]) glGenQueriesEXT(4, r->ladder);
        for (int i = 0; i < 4; i++) ask(r, kLadder[i], &r->ladder[i], 1, kGrid);
        r->ladderPending = YES;
    }
#endif
}
// answers in: the share of the nine dots with nothing in front, eased towards
static void readSlot(Slot *r) {
    if (r->pending) {
        GLuint avail = 0; glGetQueryObjectuivEXT(r->q[kGrid - 1], GL_QUERY_RESULT_AVAILABLE_EXT, &avail);   // in order, so the last one
        if (avail) {
            int seen = 0;
            for (int i = 0; i < kGrid; i++) { GLuint s = 0; glGetQueryObjectuivEXT(r->q[i], GL_QUERY_RESULT_EXT, &s); seen += s ? 1 : 0; }
            r->pending = NO;
            float target = seen / (float)kGrid; r->vis += (target - r->vis) * 0.35f;
            if (fabsf(r->vis - target) < 0.02f) r->vis = target;
        }
    }
#ifdef IBFIX_SNAPS
    if (r->ladderPending) {
        GLuint avail = 0; glGetQueryObjectuivEXT(r->ladder[3], GL_QUERY_RESULT_AVAILABLE_EXT, &avail);
        if (avail) {
            GLuint s[4]; for (int i = 0; i < 4; i++) glGetQueryObjectuivEXT(r->ladder[i], GL_QUERY_RESULT_EXT, &s[i]);
            r->ladderPending = NO;
            float d = sqrtf((r->src[0] - r->eye[0]) * (r->src[0] - r->eye[0]) + (r->src[1] - r->eye[1]) * (r->src[1] - r->eye[1]) + (r->src[2] - r->eye[2]) * (r->src[2] - r->eye[2]));
            LOG(@"flares: in front of the sun's spot (source %.0f units away): at 5%% %@, 30%% %@, 70%% %@, 100%% %@ | grid shows %.0f%% | asked %@",
                d, s[0] ? @"clear" : @"covered", s[1] ? @"clear" : @"covered", s[2] ? @"clear" : @"covered", s[3] ? @"clear" : @"covered",
                100 * r->vis, gClearedAfterWorld ? @"before the world's depth was cleared" : @"at the flare's draw");
        }
    }
#endif
}

// ---- each frame, each draw, each clear ------------------------------------------------------------------------------
void ibfix_flare_new_frame(void) {
    if (++gFrame % 300 == 0 && (gDraws || gNoSource)) {
        LOG(@"flares: %d piece draws in the last 300 frames, %.0f%% shown on average, %d fully hidden; source not found or not lined up %d times (%d flare sources in the world, positions %@) | asked before the world's depth was cleared %d, at the flare's draw %d; frames with that clear %d",
            gDraws, gDraws ? 100 * gVisSum / gDraws : 100.0, gHidden, gNoSource, gNComps, gSpace == 1 ? @"from the camera" : gSpace == 0 ? @"absolute" : @"not settled",
            gAtClear, gAtDraw, gClearFrames);
        gDraws = gHidden = gNoSource = gAtClear = gAtDraw = gClearFrames = 0; gVisSum = 0;
    }
    gSlot = 0; gRunFirst = -1; gDrawsThisFrame = 0; gClearedAfterWorld = NO;
}
// a clear of the depth in the flare's framebuffer after the world was drawn (the foreground layer's): the world's depth is
// still there, so ask now, about each flare drawn in the last frames
void ibfix_flare_before_clear(GLbitfield mask) {
    if (gState != 1 || !(mask & GL_DEPTH_BUFFER_BIT) || gDrawsThisFrame < 8 || gFlareFB < 0) return;
    GLint fb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    if (fb != gFlareFB) return;
    if (!gClearedAfterWorld) gClearFrames++;
    gClearedAfterWorld = YES;
    for (int k = 0; k < kSlots; k++) {
        Slot *r = &gSlots[k];
        if (!r->have || gFrame - r->frame > 2) continue;
        readSlot(r);
        if (!r->pending) { askSlot(r); gAtClear++; }
    }
}
// before a draw: if it's a flare piece, note its source (first piece of a run), ask if this frame hasn't, set its fade.
// elements: 1 for glDrawElements (count, type, indices), 0 for glDrawArrays (first in 'indices' as an integer)
void ibfix_flare_before_draw(GLuint prog, GLenum mode, GLsizei count, GLenum type, const GLvoid *indices, BOOL elements) {
    gDrawsThisFrame++;
    Flare *f = gState == 1 && prog ? flareFor(prog) : NULL;
    if (!f) { gRunFirst = -1; return; }                         // any other draw ends a flare's run of pieces
    if (f->hide == -2) {
        f->hide = glGetUniformLocation(prog, "ibfixFlareHide"); f->l2w = glGetUniformLocation(prog, "LocalToWorld");
        f->vp = glGetUniformLocation(prog, "ViewProjection"); f->pos = glGetAttribLocation(prog, "Position"); f->tex = glGetAttribLocation(prog, "TexCoords0");
        GLint fb = 0, func = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb); glGetIntegerv(GL_DEPTH_FUNC, &func); gFlareFB = fb;
        LOG(@"flares: drawn in framebuffer %d; at the draw: faces culled %@, scissor %@, stencil %@, depth test %@ (function 0x%x)", fb,
            glIsEnabled(GL_CULL_FACE) ? @"yes" : @"no", glIsEnabled(GL_SCISSOR_TEST) ? @"on" : @"off", glIsEnabled(GL_STENCIL_TEST) ? @"on" : @"off",
            glIsEnabled(GL_DEPTH_TEST) ? @"on" : @"off", func);
    }
    if (f->hide < 0 || f->vp < 0) return;
    if (gRunFirst >= 0) {                                       // one of the flare's other pieces: as its first piece
        float v = gSlots[gRunFirst].vis;
        glUniform1f(f->hide, 1 - v); gDraws++; gVisSum += v; if (v <= 0) gHidden++;
        return;
    }
    if (gSlot >= kSlots) return;
    int k = gSlot++; gRunFirst = k; Slot *r = &gSlots[k];
    if (!r->have) r->vis = 1;
    float before = r->vis;
    GLfloat m[16] = {0}; float src[3], eye[3], miss;
    if (f->l2w >= 0) glGetUniformfv(prog, f->l2w, m);
    glGetUniformfv(prog, f->vp, r->vp);
    GLint first = elements ? 0 : (GLint)(intptr_t)indices;
    BOOL ok = !elements && sourceFor(f, first, m, r->vp, src, eye, &miss);
    static int told; if (told < 6) { told++; LOG(@"flares: flare source %@ (%d in the world, off by %.3f of the screen from the first piece)", ok ? @"found" : @"NOT found or not lined up: the flare is left as the game draws it", gNComps, miss); }
    if (!ok) { r->have = NO; gNoSource++; r->vis = 1; glUniform1f(f->hide, 0); gDraws++; gVisSum += 1; return; }
    GLint view[4]; glGetIntegerv(GL_VIEWPORT, view);
    r->scale[1] = 2 * kPatch;                                   // NDC spans 2: the outer dots' centres at +-kPatch of the screen's height
    r->scale[0] = view[2] > 0 ? r->scale[1] * view[3] / (float)view[2] : r->scale[1];   // and square on screen
    memcpy(r->src, src, sizeof src); memcpy(r->eye, eye, sizeof eye); r->have = YES; r->frame = gFrame;
    readSlot(r);
    if (!r->pending && !gClearedAfterWorld) { askSlot(r); gAtDraw++; }   // after such a clear the world's depth is gone: next frame, before it
    glUniform1f(f->hide, 1 - r->vis);
    gDraws++; gVisSum += r->vis; if (r->vis <= 0) gHidden++;
    // test builds: a picture each time the flare goes from shown to hidden or back (up to 8)
    static int snaps;
    if (snaps < 8 && (before >= 0.5f) != (r->vis >= 0.5f) && ibfix_auto_photos()) { snaps++; ibfix_snap([NSString stringWithFormat:@"flare-%d-%@", snaps, r->vis >= 0.5f ? @"shown" : @"hidden"]); }
}
