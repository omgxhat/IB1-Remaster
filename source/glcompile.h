// glcompile.h: compile one GL shader and say whether it compiled (its log in *err if not), for bump.m and wound.m,
// included where each used to have its own copy (FIXES.md 107). flare.m has its own, without the log.
#pragma once
static BOOL compiles(GLenum kind, NSString *src, NSString **err) {
    GLuint s = glCreateShader(kind); const char *c = src.UTF8String;
    glShaderSource(s, 1, &c, NULL); glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024] = {0}; glGetShaderInfoLog(s, sizeof log, NULL, log); *err = @(log); }
    glDeleteShader(s);
    return ok != 0;
}
