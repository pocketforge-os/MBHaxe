/*
 * pf-probe: window step-1 device probe for the MBHaxe PocketForge port (tsp-0qwbh.10).
 *
 * It runs on the game's own library stack (the bookworm sysroot it is linked against, the
 * image's SDL2 and GLESv2, the app root's bundled OpenAL Soft) and asks that stack for what the
 * game needs, in the order and with the settings hashlink's sdl.hdll uses:
 *   - SDL_Init(SDL_INIT_EVERYTHING), then the video driver (expected: wayland);
 *   - an OpenGL ES 3.0 context through EGL (profile ES, 3.0, depth 24, stencil 8, double
 *     buffered), its GL_VERSION / GL_RENDERER / GLSL version / extension count;
 *   - a small ES 3.0 draw (VAO + VBO, "#version 300 es" shaders) into the default framebuffer,
 *     read back with glReadPixels and compared with the expected colours, twice across a buffer
 *     swap, then a short run of presented frames;
 *   - the SDL game controllers (name, GUID, IsGameController, mapping);
 *   - the default OpenAL device playing a 0.5 s tone.
 *
 * Output (stdout, line buffered): "PROBE INFO key=value ..." lines, one
 * "PROBE CHECK <name> PASS|FAIL|WARN|SKIP [key=value ...]" line per check, and a final
 * "PROBE RESULT PASS [warn=<checks>]" or "PROBE RESULT FAIL reason=<check>".
 * Exit status: 0 only when every GL check passed (gamepad and audio are reported but are not
 * fatal: CI has neither); 1 on a failed check; 2 on a usage error; 3 when the watchdog fired
 * (reason=timeout); 4 on a fatal signal (reason=crash). Neither a hang nor a crash goes unnamed.
 *
 * usage: pf-probe [--expect-driver NAME] [--expect-renderer TEXT]... [--reject-renderer TEXT]...
 *                 [--hold SECONDS] [--timeout SECONDS] [--no-audio] [--negative]
 *   --expect-driver NAME    SDL video driver the run must get (default wayland)
 *   --expect-renderer TEXT  GL_RENDERER must contain TEXT (repeatable; e.g. zink)
 *   --reject-renderer TEXT  GL_RENDERER must not contain TEXT (repeatable; e.g. llvmpipe)
 *   --hold SECONDS          keep presenting the test pattern this long after the checks, for a
 *                           screen capture (default 0)
 *   --timeout SECONDS       watchdog for the whole run (default 60, at least hold + 30)
 *   --no-audio              skip the OpenAL check (reported as SKIP)
 *   --negative              negative control: force SDL_VIDEODRIVER=x11 with no DISPLAY, so video
 *                           init must fail; the run must end "PROBE RESULT FAIL reason=sdl-init-video"
 */
#include <SDL.h>
#include <GLES3/gl3.h>
#include <AL/al.h>
#include <AL/alc.h>

#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef PF_PROBE_VERSION
#define PF_PROBE_VERSION "dev"
#endif

/* EGL enums used through SDL_GL_GetProcAddress (the probe, like the game, does not link libEGL). */
#define PF_EGL_VENDOR 0x3053
#define PF_EGL_VERSION 0x3054
#define PF_EGL_CLIENT_APIS 0x308D
typedef void *(*pf_egl_get_display_fn)(void);
typedef const char *(*pf_egl_query_string_fn)(void *dpy, int name);

#define MAX_MATCH 8
static const char *expect_driver = "wayland";
static const char *expect_renderer[MAX_MATCH];
static const char *reject_renderer[MAX_MATCH];
static int n_expect, n_reject;
static double hold_s;
static int timeout_s = 60;
static int no_audio, negative;

/* First failed fatal (GL path) check, and the non-fatal checks that warned. */
static char fail_reason[64];
static char warn_list[128];

static const char *volatile stage = "start";

static void put_raw(const char *s) {
	size_t n = strlen(s);
	while (n > 0) {
		ssize_t w = write(STDOUT_FILENO, s, n);
		if (w <= 0) return;
		s += w;
		n -= (size_t)w;
	}
}

static void on_alarm(int sig) {
	(void)sig;
	put_raw("PROBE CHECK watchdog FAIL stage=");
	put_raw(stage);
	put_raw("\nPROBE RESULT FAIL reason=timeout\n");
	_exit(3);
}

static void on_crash(int sig) {
	char num[8];
	int i = 0, s = sig;
	char tmp[8];
	do { tmp[i++] = (char)('0' + s % 10); s /= 10; } while (s && i < 7);
	for (int j = 0; j < i; j++) num[j] = tmp[i - 1 - j];
	num[i] = 0;
	put_raw("PROBE CHECK crash FAIL signal=");
	put_raw(num);
	put_raw(" stage=");
	put_raw(stage);
	put_raw("\nPROBE RESULT FAIL reason=crash\n");
	_exit(4);
}

/* Quote a value for a key=value line: double quotes, inner quotes and newlines replaced. */
static const char *q(const char *s) {
	static char bufs[8][1024];
	static int k;
	char *b = bufs[k++ & 7];
	size_t o = 0;
	if (!s) s = "";
	b[o++] = '"';
	for (; *s && o < sizeof bufs[0] - 2; s++) b[o++] = (*s == '"' || *s == '\n' || *s == '\r') ? '\'' : *s;
	b[o++] = '"';
	b[o] = 0;
	return b;
}

static void line(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fputs("PROBE ", stdout);
	vprintf(fmt, ap);
	fputc('\n', stdout);
	va_end(ap);
}

/* Record a check. fatal: a FAIL decides the result (GL path). Returns 1 on PASS. */
static int check(const char *name, int ok, int fatal, const char *fmt, ...) {
	char detail[1536] = "";
	va_list ap;
	va_start(ap, fmt);
	if (fmt) vsnprintf(detail, sizeof detail, fmt, ap);
	va_end(ap);
	const char *st = ok ? "PASS" : (fatal ? "FAIL" : "WARN");
	printf("PROBE CHECK %s %s%s%s\n", name, st, detail[0] ? " " : "", detail);
	if (!ok && fatal && !fail_reason[0]) snprintf(fail_reason, sizeof fail_reason, "%s", name);
	if (!ok && !fatal) {
		size_t l = strlen(warn_list);
		snprintf(warn_list + l, sizeof warn_list - l, "%s%s", l ? "," : "", name);
	}
	return ok;
}

static void skip(const char *name, const char *why) { printf("PROBE CHECK %s SKIP reason=%s\n", name, why); }

static int usage(const char *msg) {
	fprintf(stderr, "pf-probe: %s\n", msg);
	fprintf(stderr, "usage: pf-probe [--expect-driver NAME] [--expect-renderer TEXT]... [--reject-renderer TEXT]...\n"
	                "                [--hold SECONDS] [--timeout SECONDS] [--no-audio] [--negative]\n");
	puts("PROBE RESULT FAIL reason=usage");
	return 2;
}

/* ---- GL --------------------------------------------------------------------------------- */

static const char *VS =
	"#version 300 es\n"
	"layout(location = 0) in vec2 a_pos;\n"
	"void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }\n";
static const char *FS =
	"#version 300 es\n"
	"precision mediump float;\n"
	"uniform vec4 u_color;\n"
	"out vec4 o_color;\n"
	"void main() { o_color = u_color; }\n";

static GLuint compile_shader(GLenum type, const char *src, char *log, size_t logsz) {
	GLuint s = glCreateShader(type);
	GLint ok = 0;
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		glGetShaderInfoLog(s, (GLsizei)logsz, NULL, log);
		glDeleteShader(s);
		return 0;
	}
	return s;
}

/* Colours are multiples of 1/255 (n/255 for n in 51, 102, 153, 204) with distinct channels, so
 * channel order shows and 8-bit framebuffers read them back exactly; the tolerance covers 565. */
static const unsigned char CLEAR_A[3] = {204, 51, 102}, DRAW_A[3] = {51, 153, 204};
static const unsigned char CLEAR_B[3] = {102, 204, 51}, DRAW_B[3] = {204, 102, 153};
#define TOL 8

static int near3(const unsigned char *px, const unsigned char *want) {
	for (int i = 0; i < 3; i++)
		if (abs((int)px[i] - (int)want[i]) > TOL) return 0;
	return 1;
}

static GLuint prog, vao, vbo;
static GLint u_color;

static void draw_pattern(int w, int h, const unsigned char *clear, const unsigned char *draw) {
	glViewport(0, 0, w, h);
	glDisable(GL_DITHER);
	glDisable(GL_SCISSOR_TEST);
	glClearColor(clear[0] / 255.0f, clear[1] / 255.0f, clear[2] / 255.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
	glUseProgram(prog);
	glUniform4f(u_color, draw[0] / 255.0f, draw[1] / 255.0f, draw[2] / 255.0f, 1.0f);
	glBindVertexArray(vao);
	glDrawArrays(GL_TRIANGLES, 0, 6);
	glBindVertexArray(0);
}

/* Read the centre (inside the drawn quad) and a corner (clear colour) of the back buffer. */
static int readback(const char *name, int w, int h, const unsigned char *clear, const unsigned char *draw) {
	unsigned char c[4] = {0}, k[4] = {0};
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, c);
	glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, k);
	GLenum e = glGetError();
	int ok = e == GL_NO_ERROR && near3(c, draw) && near3(k, clear);
	return check(name, ok, 1,
	             "centre=%d,%d,%d want=%d,%d,%d corner=%d,%d,%d want=%d,%d,%d tol=%d size=%dx%d glerror=0x%04x",
	             c[0], c[1], c[2], draw[0], draw[1], draw[2], k[0], k[1], k[2], clear[0], clear[1], clear[2], TOL, w, h,
	             (unsigned)e);
}

static int contains(const char *hay, const char *needle) { return hay && needle && strstr(hay, needle) != NULL; }

static void gl_checks(void) {
	stage = "window";
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_Window *win = SDL_CreateWindow("pf-probe", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 1280, 720,
	                                   SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN);
	if (!check("window", win != NULL, 1, win ? NULL : "sdl_error=%s", q(SDL_GetError()))) return;

	stage = "gl-context";
	SDL_GLContext ctx = SDL_GL_CreateContext(win);
	if (!check("gl-context", ctx != NULL, 1, ctx ? "profile=es requested=3.0" : "sdl_error=%s",
	           q(ctx ? NULL : SDL_GetError()))) {
		SDL_DestroyWindow(win);
		return;
	}
	SDL_GL_MakeCurrent(win, ctx);
	int r = 0, g = 0, b = 0, a = 0, d = 0, s = 0, maj = 0, min = 0, prof = 0;
	SDL_GL_GetAttribute(SDL_GL_RED_SIZE, &r);
	SDL_GL_GetAttribute(SDL_GL_GREEN_SIZE, &g);
	SDL_GL_GetAttribute(SDL_GL_BLUE_SIZE, &b);
	SDL_GL_GetAttribute(SDL_GL_ALPHA_SIZE, &a);
	SDL_GL_GetAttribute(SDL_GL_DEPTH_SIZE, &d);
	SDL_GL_GetAttribute(SDL_GL_STENCIL_SIZE, &s);
	SDL_GL_GetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, &maj);
	SDL_GL_GetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, &min);
	SDL_GL_GetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, &prof);
	line("INFO gl_config rgba=%d%d%d%d depth=%d stencil=%d context=%d.%d profile_mask=0x%x swap_interval=%d", r, g, b,
	     a, d, s, maj, min, prof, SDL_GL_GetSwapInterval());

	/* EGL identity through the same loader SDL uses (no libEGL link, as in the game). */
	pf_egl_get_display_fn egl_get_display = (pf_egl_get_display_fn)SDL_GL_GetProcAddress("eglGetCurrentDisplay");
	pf_egl_query_string_fn egl_query = (pf_egl_query_string_fn)SDL_GL_GetProcAddress("eglQueryString");
	void *dpy = egl_get_display ? egl_get_display() : NULL;
	if (dpy && egl_query)
		line("INFO egl vendor=%s version=%s client_apis=%s", q(egl_query(dpy, PF_EGL_VENDOR)),
		     q(egl_query(dpy, PF_EGL_VERSION)), q(egl_query(dpy, PF_EGL_CLIENT_APIS)));
	else
		line("INFO egl unavailable=%s", q(dpy ? "eglQueryString" : "eglGetCurrentDisplay"));

	stage = "gl-strings";
	const char *ver = (const char *)glGetString(GL_VERSION);
	const char *ren = (const char *)glGetString(GL_RENDERER);
	const char *ven = (const char *)glGetString(GL_VENDOR);
	const char *sl = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
	GLint next = 0, maxtex = 0, maj_gl = 0, min_gl = 0;
	glGetIntegerv(GL_NUM_EXTENSIONS, &next);
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxtex);
	glGetIntegerv(GL_MAJOR_VERSION, &maj_gl);
	glGetIntegerv(GL_MINOR_VERSION, &min_gl);
	line("INFO gl GL_VERSION=%s GL_RENDERER=%s GL_VENDOR=%s GL_SHADING_LANGUAGE_VERSION=%s", q(ver), q(ren), q(ven),
	     q(sl));
	line("INFO gl extensions=%d max_texture_size=%d version_int=%d.%d", next, maxtex, maj_gl, min_gl);
	GLint rng[2] = {0, 0}, prec = 0, mrng[2] = {0, 0}, mprec = 0;
	glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, GL_HIGH_FLOAT, rng, &prec);
	glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, GL_MEDIUM_FLOAT, mrng, &mprec);
	line("INFO gl frag_highp_float=range:%d,%d,precision:%d frag_mediump_float=range:%d,%d,precision:%d", rng[0],
	     rng[1], prec, mrng[0], mrng[1], mprec);

	check("gl-version", ver && strncmp(ver, "OpenGL ES 3.", 12) == 0 && maj_gl >= 3, 1, "GL_VERSION=%s", q(ver));
	check("glsl-version", sl && strncmp(sl, "OpenGL ES GLSL ES 3.", 20) == 0, 1, "GL_SHADING_LANGUAGE_VERSION=%s", q(sl));
	int ren_ok = ren != NULL;
	for (int i = 0; i < n_expect; i++) ren_ok &= contains(ren, expect_renderer[i]);
	for (int i = 0; i < n_reject; i++) ren_ok &= !contains(ren, reject_renderer[i]);
	{
		char rules[512] = "";
		size_t o = 0;
		for (int i = 0; i < n_expect && o < sizeof rules; i++)
			o += (size_t)snprintf(rules + o, sizeof rules - o, " expect=%s", q(expect_renderer[i]));
		for (int i = 0; i < n_reject && o < sizeof rules; i++)
			o += (size_t)snprintf(rules + o, sizeof rules - o, " reject=%s", q(reject_renderer[i]));
		check("gl-renderer", ren_ok, 1, "GL_RENDERER=%s%s", q(ren), rules);
	}
	GLenum e0 = glGetError();
	while (glGetError() != GL_NO_ERROR) {}

	stage = "gl-program";
	char log[512] = "";
	GLuint vs = compile_shader(GL_VERTEX_SHADER, VS, log, sizeof log);
	GLuint fs = vs ? compile_shader(GL_FRAGMENT_SHADER, FS, log, sizeof log) : 0;
	GLint linked = 0;
	if (vs && fs) {
		prog = glCreateProgram();
		glAttachShader(prog, vs);
		glAttachShader(prog, fs);
		glLinkProgram(prog);
		glGetProgramiv(prog, GL_LINK_STATUS, &linked);
		if (!linked) glGetProgramInfoLog(prog, sizeof log, NULL, log);
		glDeleteShader(vs);
		glDeleteShader(fs);
	}
	if (!check("gl-program", linked, 1, linked ? "glsl=300es vao=1" : "log=%s", q(log))) goto out;
	u_color = glGetUniformLocation(prog, "u_color");
	/* A centred quad covering the middle half of the framebuffer. */
	static const GLfloat quad[] = {-0.5f, -0.5f, 0.5f, -0.5f, 0.5f, 0.5f, -0.5f, -0.5f, 0.5f, 0.5f, -0.5f, 0.5f};
	glGenVertexArrays(1, &vao);
	glBindVertexArray(vao);
	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
	glBindVertexArray(0);

	/* Frame A, read back, swap; frame B (other colours), read back, swap: the second readback
	 * proves the swap returned and the next back buffer is live. */
	stage = "gl-draw";
	int w = 0, h = 0;
	SDL_PumpEvents();
	SDL_GL_GetDrawableSize(win, &w, &h);
	GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if (!check("gl-framebuffer", fbs == GL_FRAMEBUFFER_COMPLETE && w > 4 && h > 4, 1, "status=0x%04x size=%dx%d",
	           (unsigned)fbs, w, h))
		goto out;
	draw_pattern(w, h, CLEAR_A, DRAW_A);
	int draw_ok = readback("gl-draw", w, h, CLEAR_A, DRAW_A);
	stage = "gl-swap";
	SDL_GL_SwapWindow(win);
	stage = "gl-draw-after-swap";
	SDL_PumpEvents();
	SDL_GL_GetDrawableSize(win, &w, &h);
	draw_pattern(w, h, CLEAR_B, DRAW_B);
	draw_ok &= readback("gl-draw-after-swap", w, h, CLEAR_B, DRAW_B);

	/* Present: 60 frames of the test pattern (plus --hold), timed; any GL error fails. */
	stage = "gl-present";
	Uint64 f = SDL_GetPerformanceFrequency(), t0 = SDL_GetPerformanceCounter();
	int frames = 0;
	double elapsed = 0;
	while (frames < 60 || elapsed < hold_s) {
		SDL_Event ev;
		while (SDL_PollEvent(&ev)) {}
		SDL_GL_GetDrawableSize(win, &w, &h);
		draw_pattern(w, h, CLEAR_A, DRAW_A);
		SDL_GL_SwapWindow(win);
		frames++;
		elapsed = (double)(SDL_GetPerformanceCounter() - t0) / (double)f;
	}
	GLenum e1 = glGetError();
	check("gl-present", draw_ok && e1 == GL_NO_ERROR, 1, "frames=%d seconds=%.3f fps=%.1f glerror=0x%04x", frames,
	      elapsed, elapsed > 0 ? frames / elapsed : 0.0, (unsigned)e1);
	check("gl-errors", e0 == GL_NO_ERROR && e1 == GL_NO_ERROR, 1, "after_strings=0x%04x after_present=0x%04x",
	      (unsigned)e0, (unsigned)e1);
out:
	stage = "gl-teardown";
	if (vbo) glDeleteBuffers(1, &vbo);
	if (vao) glDeleteVertexArrays(1, &vao);
	if (prog) glDeleteProgram(prog);
	SDL_GL_DeleteContext(ctx);
	SDL_DestroyWindow(win);
}

/* ---- gamepad ----------------------------------------------------------------------------- */

static void gamepad_checks(void) {
	stage = "gamepad";
	/* Hot-plug events for devices present at init arrive on the first pumps. */
	Uint32 t0 = SDL_GetTicks();
	while (SDL_GetTicks() - t0 < 500) {
		SDL_Event ev;
		while (SDL_PollEvent(&ev)) {}
		SDL_Delay(20);
	}
	int n = SDL_NumJoysticks(), gc = 0;
	for (int i = 0; i < n; i++) {
		char guid[64];
		SDL_JoystickGetGUIDString(SDL_JoystickGetDeviceGUID(i), guid, sizeof guid);
		int is_gc = SDL_IsGameController(i) == SDL_TRUE;
		char *mapping = is_gc ? SDL_GameControllerMappingForDeviceIndex(i) : NULL;
		gc += is_gc;
		line("INFO gamepad index=%d name=%s guid=%s vendor=0x%04x product=0x%04x gamecontroller=%d mapping=%s", i,
		     q(SDL_JoystickNameForIndex(i)), guid, SDL_JoystickGetDeviceVendor(i), SDL_JoystickGetDeviceProduct(i),
		     is_gc, q(mapping ? mapping : ""));
		if (mapping) SDL_free(mapping);
	}
	check("gamepad", gc > 0, 0, "joysticks=%d gamecontrollers=%d", n, gc);
}

/* ---- audio ------------------------------------------------------------------------------- */

static void audio_checks(void) {
	if (no_audio) {
		skip("audio", "no-audio");
		return;
	}
	stage = "audio-open";
	const char *def = alcGetString(NULL, ALC_DEFAULT_DEVICE_SPECIFIER);
	ALCdevice *dev = alcOpenDevice(NULL);
	if (!dev) {
		check("audio", 0, 0, "step=alcOpenDevice default=%s alc_error=0x%04x", q(def), (unsigned)alcGetError(NULL));
		return;
	}
	const char *name = alcGetString(dev, ALC_DEVICE_SPECIFIER);
	ALCcontext *ctx = alcCreateContext(dev, NULL);
	if (!ctx || !alcMakeContextCurrent(ctx)) {
		check("audio", 0, 0, "step=alcCreateContext device=%s alc_error=0x%04x", q(name), (unsigned)alcGetError(dev));
		if (ctx) alcDestroyContext(ctx);
		alcCloseDevice(dev);
		return;
	}
	ALCint freq = 0;
	alcGetIntegerv(dev, ALC_FREQUENCY, 1, &freq);
	line("INFO openal device=%s AL_VERSION=%s AL_RENDERER=%s AL_VENDOR=%s frequency=%d", q(name),
	     q(alGetString(AL_VERSION)), q(alGetString(AL_RENDERER)), q(alGetString(AL_VENDOR)), freq);

	stage = "audio-play";
	enum { RATE = 48000, N = RATE / 2 };
	static ALshort pcm[N];
	for (int i = 0; i < N; i++) {
		double env = i < 480 ? i / 480.0 : (i > N - 480 ? (N - i) / 480.0 : 1.0); /* 10 ms fades */
		pcm[i] = (ALshort)(0.25 * 32767.0 * env * sin(2.0 * M_PI * 440.0 * i / RATE));
	}
	ALuint buf = 0, src = 0;
	alGetError();
	alGenBuffers(1, &buf);
	alBufferData(buf, AL_FORMAT_MONO16, pcm, sizeof pcm, RATE);
	alGenSources(1, &src);
	alSourcei(src, AL_BUFFER, (ALint)buf);
	alSourcePlay(src);
	ALenum err = alGetError();
	ALint state = AL_PLAYING;
	Uint32 t0 = SDL_GetTicks();
	while (err == AL_NO_ERROR && state == AL_PLAYING && SDL_GetTicks() - t0 < 3000) {
		SDL_Delay(10);
		alGetSourcei(src, AL_SOURCE_STATE, &state);
	}
	Uint32 ms = SDL_GetTicks() - t0;
	ALCenum aerr = alcGetError(dev);
	int ok = err == AL_NO_ERROR && state == AL_STOPPED && ms >= 400 && aerr == ALC_NO_ERROR;
	check("audio", ok, 0, "device=%s tone=440Hz duration_ms=500 played_ms=%u state=0x%04x al_error=0x%04x alc_error=0x%04x",
	      q(name), ms, (unsigned)state, (unsigned)err, (unsigned)aerr);
	alDeleteSources(1, &src);
	alDeleteBuffers(1, &buf);
	alcMakeContextCurrent(NULL);
	alcDestroyContext(ctx);
	alcCloseDevice(dev);
}

/* ---- main -------------------------------------------------------------------------------- */

static int parse_num(const char *s, double *out) {
	char *end;
	double v = strtod(s, &end);
	if (!*s || *end || v < 0 || v > 86400) return 0;
	*out = v;
	return 1;
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IOLBF, 0);
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = i + 1 < argc ? argv[i + 1] : NULL;
		double num;
		if (!strcmp(a, "--expect-driver") && v) expect_driver = argv[++i];
		else if (!strcmp(a, "--expect-renderer") && v && n_expect < MAX_MATCH) expect_renderer[n_expect++] = argv[++i];
		else if (!strcmp(a, "--reject-renderer") && v && n_reject < MAX_MATCH) reject_renderer[n_reject++] = argv[++i];
		else if (!strcmp(a, "--hold") && v && parse_num(argv[++i], &num)) hold_s = num;
		else if (!strcmp(a, "--timeout") && v && parse_num(argv[++i], &num) && num >= 1) timeout_s = (int)num;
		else if (!strcmp(a, "--no-audio")) no_audio = 1;
		else if (!strcmp(a, "--negative")) negative = 1;
		else return usage(a);
	}
	if (timeout_s < (int)hold_s + 30) timeout_s = (int)hold_s + 30;

	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_alarm;
	sigaction(SIGALRM, &sa, NULL);
	sa.sa_handler = on_crash;
	sa.sa_flags = SA_RESETHAND;
	int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};
	for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
	alarm((unsigned)timeout_s);

	if (negative) {
		/* Negative control: no X server to talk to, so video init must fail by name. */
		setenv("SDL_VIDEODRIVER", "x11", 1);
		unsetenv("DISPLAY");
		expect_driver = "x11";
	}
	SDL_version lv;
	SDL_GetVersion(&lv);
	line("INFO probe version=%s mode=%s sdl=%d.%d.%d timeout=%d hold=%.1f", PF_PROBE_VERSION,
	     negative ? "negative" : "positive", lv.major, lv.minor, lv.patch, timeout_s, hold_s);
	line("INFO env SDL_VIDEODRIVER=%s WAYLAND_DISPLAY=%s XDG_RUNTIME_DIR=%s DISPLAY=%s ALSOFT_CONF=%s",
	     q(getenv("SDL_VIDEODRIVER")), q(getenv("WAYLAND_DISPLAY")), q(getenv("XDG_RUNTIME_DIR")),
	     q(getenv("DISPLAY")), q(getenv("ALSOFT_CONF")));

	/* Which files the dynamic loader picked for the game's three graphics/audio libraries. */
	{
		Dl_info sdl_i, gles_i, al_i;
		memset(&sdl_i, 0, sizeof sdl_i);
		memset(&gles_i, 0, sizeof gles_i);
		memset(&al_i, 0, sizeof al_i);
		dladdr((void *)SDL_Init, &sdl_i);
		dladdr((void *)glGetString, &gles_i);
		dladdr((void *)alcOpenDevice, &al_i);
		line("INFO libs sdl=%s gles=%s openal=%s", q(sdl_i.dli_fname), q(gles_i.dli_fname), q(al_i.dli_fname));
	}
	/* Same init as hashlink's sdl.hdll (init_once). On failure, name the subsystem. */
	stage = "sdl-init";
	SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
	if (SDL_Init(SDL_INIT_EVERYTHING) != 0) {
		char err[512];
		snprintf(err, sizeof err, "%s", SDL_GetError());
		static const struct { Uint32 flag; const char *name; } subs[] = {
			{SDL_INIT_VIDEO, "video"}, {SDL_INIT_AUDIO, "audio"}, {SDL_INIT_JOYSTICK, "joystick"},
			{SDL_INIT_GAMECONTROLLER, "gamecontroller"}, {SDL_INIT_HAPTIC, "haptic"},
			{SDL_INIT_SENSOR, "sensor"}, {SDL_INIT_EVENTS, "events"}, {SDL_INIT_TIMER, "timer"}};
		const char *which = "everything";
		for (size_t i = 0; i < sizeof subs / sizeof subs[0]; i++) {
			if (SDL_InitSubSystem(subs[i].flag) != 0) {
				snprintf(err, sizeof err, "%s", SDL_GetError());
				which = subs[i].name;
				break;
			}
			SDL_QuitSubSystem(subs[i].flag);
		}
		char name[32];
		snprintf(name, sizeof name, "sdl-init-%s", which);
		check(name, 0, 1, "sdl_error=%s", q(err));
		printf("PROBE RESULT FAIL reason=%s\n", fail_reason);
		return 1;
	}
	check("sdl-init", 1, 1, "flags=everything");
	const char *drv = SDL_GetCurrentVideoDriver();
	line("INFO sdl video_driver=%s audio_driver=%s", q(drv), q(SDL_GetCurrentAudioDriver()));
	if (check("video-driver", drv && !strcmp(drv, expect_driver), 1, "driver=%s expected=%s", q(drv), q(expect_driver)))
		gl_checks();
	else
		skip("gl", "video-driver");
	gamepad_checks();
	audio_checks();
	stage = "quit";
	SDL_Quit();
	alarm(0);
	if (fail_reason[0]) {
		printf("PROBE RESULT FAIL reason=%s\n", fail_reason);
		return 1;
	}
	if (warn_list[0]) printf("PROBE RESULT PASS warn=%s\n", warn_list);
	else puts("PROBE RESULT PASS");
	return 0;
}
