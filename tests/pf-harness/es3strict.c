/*
 * es3strict: LD_PRELOAD checker for OpenGL ES 3.0 core-only usage (PocketForge regression harness).
 *
 * Mesa accepts some non-core enums in an ES 3.0 context without raising a GL error (for example
 * GL_BGRA_EXT pixel transfers, which Mesa always exposes through EXT_texture_format_BGRA8888 and
 * cannot be disabled with MESA_EXTENSION_OVERRIDE), so glGetError alone cannot see a regression
 * that a stricter ES driver would reject. This shim interposes the GL entry points that sdl.hdll
 * imports directly and reports every argument outside the OpenGL ES 3.0 core tables:
 *   - pixel-transfer `format` of glTexImage2D/3D, glTexSubImage2D/3D, glReadPixels
 *     (ES 3.0 section 3.7, table 3.3; section 4.3.2);
 *   - `cap` of glEnable/glDisable (ES 3.0 section 6.1.1 / glEnable reference page).
 * It also counts every non-zero glGetError result returned to the application from process start,
 * so errors that heaps itself polls and swallows (before the pf_diag per-frame counter runs) are seen.
 * Each call is forwarded unchanged (dlsym RTLD_NEXT). Each distinct violation is logged once as
 *   [es3strict] VIOLATION <function> <arg> 0x<enum>
 * the first 20 GL errors as
 *   [es3strict] glGetError 0x<error> (after <K> checked calls)
 * the caller of exit() (so an unexpected early exit can be told apart from the pf_diag exit) as
 *   [es3strict] exit(<code>) backtrace: <frames>
 * and the totals at exit as
 *   [es3strict] violations: <N> (calls checked: <M>), GL errors returned: <E>
 *
 * build: cc -shared -fPIC -O2 -o es3strict.so es3strict.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>

typedef unsigned int GLenum;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLboolean;

static unsigned long violations, checked, glerrors;
static struct { const char *fn; GLenum v; } seen[64];
static unsigned nseen;

static void *next(const char *name) {
	void *f = dlsym(RTLD_NEXT, name);
	if (!f) {
		fprintf(stderr, "[es3strict] FATAL cannot resolve %s\n", name);
		abort();
	}
	return f;
}

static void violation(const char *fn, const char *what, GLenum v) {
	unsigned i;
	violations++;
	for (i = 0; i < nseen; i++)
		if (seen[i].fn == fn && seen[i].v == v)
			return;
	if (nseen < 64) {
		seen[nseen].fn = fn;
		seen[nseen++].v = v;
	}
	fprintf(stderr, "[es3strict] VIOLATION %s %s 0x%04X\n", fn, what, v);
	fflush(stderr);
}

static int es3_format(GLenum f) {
	switch (f) {
	case 0x1908: /* GL_RGBA */
	case 0x8D99: /* GL_RGBA_INTEGER */
	case 0x1907: /* GL_RGB */
	case 0x8D98: /* GL_RGB_INTEGER */
	case 0x8227: /* GL_RG */
	case 0x8228: /* GL_RG_INTEGER */
	case 0x1903: /* GL_RED */
	case 0x8D94: /* GL_RED_INTEGER */
	case 0x1902: /* GL_DEPTH_COMPONENT */
	case 0x84F9: /* GL_DEPTH_STENCIL */
	case 0x190A: /* GL_LUMINANCE_ALPHA */
	case 0x1909: /* GL_LUMINANCE */
	case 0x1906: /* GL_ALPHA */
		return 1;
	}
	return 0;
}

static int es3_cap(GLenum c) {
	switch (c) {
	case 0x0BE2: /* GL_BLEND */
	case 0x0B44: /* GL_CULL_FACE */
	case 0x0B71: /* GL_DEPTH_TEST */
	case 0x0BD0: /* GL_DITHER */
	case 0x8037: /* GL_POLYGON_OFFSET_FILL */
	case 0x8D69: /* GL_PRIMITIVE_RESTART_FIXED_INDEX */
	case 0x8C89: /* GL_RASTERIZER_DISCARD */
	case 0x809E: /* GL_SAMPLE_ALPHA_TO_COVERAGE */
	case 0x80A0: /* GL_SAMPLE_COVERAGE */
	case 0x0C11: /* GL_SCISSOR_TEST */
	case 0x0B90: /* GL_STENCIL_TEST */
		return 1;
	}
	return 0;
}

#define CHECK_FORMAT(fn, f) do { checked++; if (!es3_format(f)) violation(fn, "format", f); } while (0)
#define CHECK_CAP(fn, c) do { checked++; if (!es3_cap(c)) violation(fn, "cap", c); } while (0)

void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
		GLint border, GLenum format, GLenum type, const void *pixels) {
	static void (*f)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
	if (!f) f = next("glTexImage2D");
	CHECK_FORMAT("glTexImage2D", format);
	f(target, level, internalformat, width, height, border, format, type, pixels);
}

void glTexImage3D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height,
		GLsizei depth, GLint border, GLenum format, GLenum type, const void *pixels) {
	static void (*f)(GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
	if (!f) f = next("glTexImage3D");
	CHECK_FORMAT("glTexImage3D", format);
	f(target, level, internalformat, width, height, depth, border, format, type, pixels);
}

void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width,
		GLsizei height, GLenum format, GLenum type, const void *pixels) {
	static void (*f)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
	if (!f) f = next("glTexSubImage2D");
	CHECK_FORMAT("glTexSubImage2D", format);
	f(target, level, xoffset, yoffset, width, height, format, type, pixels);
}

void glTexSubImage3D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
		GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void *pixels) {
	static void (*f)(GLenum, GLint, GLint, GLint, GLint, GLsizei, GLsizei, GLsizei, GLenum, GLenum, const void *);
	if (!f) f = next("glTexSubImage3D");
	CHECK_FORMAT("glTexSubImage3D", format);
	f(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels);
}

void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void *data) {
	static void (*f)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
	if (!f) f = next("glReadPixels");
	CHECK_FORMAT("glReadPixels", format);
	f(x, y, width, height, format, type, data);
}

void glEnable(GLenum cap) {
	static void (*f)(GLenum);
	if (!f) f = next("glEnable");
	CHECK_CAP("glEnable", cap);
	f(cap);
}

void glDisable(GLenum cap) {
	static void (*f)(GLenum);
	if (!f) f = next("glDisable");
	CHECK_CAP("glDisable", cap);
	f(cap);
}

GLenum glGetError(void) {
	static GLenum (*f)(void);
	GLenum e;
	if (!f) f = next("glGetError");
	e = f();
	if (e != 0 && ++glerrors <= 20) {
		fprintf(stderr, "[es3strict] glGetError 0x%04X (after %lu checked calls)\n", e, checked);
		fflush(stderr);
	}
	return e;
}

void exit(int code) {
	static void (*f)(int);
	void *bt[24];
	int n;
	if (!f) f = (void (*)(int))next("exit");
	n = backtrace(bt, 24);
	fprintf(stderr, "[es3strict] exit(%d) backtrace:\n", code);
	backtrace_symbols_fd(bt, n, 2);
	fflush(stderr);
	f(code);
	abort(); /* not reached */
}

__attribute__((constructor)) static void es3strict_init(void) {
	fprintf(stderr, "[es3strict] loaded\n");
}

__attribute__((destructor)) static void es3strict_fini(void) {
	fprintf(stderr, "[es3strict] violations: %lu (calls checked: %lu), GL errors returned: %lu\n",
		violations, checked, glerrors);
	fflush(stderr);
}
