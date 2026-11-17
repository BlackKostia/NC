/* Differential harness: reference asm config loader (ref_ prefix) vs src/core/config*.c on random duoprc files.
 * Shims stand in for the allocator, PAL and read helpers both sides call. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { uint64_t dev, ino; int64_t size, mtime; uint32_t mode, mtime_nsec; uint64_t nlink; uint32_t uid, gid; } FileStat;
void *mem_alloc(uint64_t n) { return calloc(1, n); }
void mem_free(void *p) { free(p); }
void mem_zero(void *p, uint64_t n) { memset(p, 0, n); }
intptr_t sys_read_retry(int fd, void *b, size_t n) { ssize_t r; while ((r = read(fd, b, n)) < 0 && errno == EINTR) {} return r; }
int os_fstat(int fd, FileStat *o) { struct stat s; if (fstat(fd, &s) < 0) return -1; memset(o, 0, sizeof *o); o->mode = s.st_mode; o->size = s.st_size; return 0; }
intptr_t os_openat(int d, const char *p, int f, unsigned m) { int r = openat(d, p, f, m); return r < 0 ? -errno : r; }
intptr_t os_close(int fd) { return close(fd); }

extern char ref_g_config[15024]; extern int32_t ref_g_cfg_warn;
extern char g_config[15024]; extern int32_t g_cfg_warn;
extern void ref_config_load(char **); extern void config_load(char **);
extern int ref_config_lookup_bind(int, int); extern int config_lookup_bind(int, int);
extern const char *ref_config_lookup_open(const char *); extern const char *config_lookup_open(const char *);
extern int ref_config_menu_count(void); extern int config_menu_count(void);
extern int ref_config_menu_item(int, const char **, const char **); extern int config_menu_item(int, const char **, const char **);

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 20); }
#define PICK(a) (a[rnd() % (sizeof a / sizeof a[0])])

static const char *themes[] = {"0", "1", "2", "3", "tokyo", "CATPPUCCIN", "Emerald", "foo", "1x", "-1"};
static const char *bools[] = {"1", "0", "on", "Off", "true", "FALSE", "10", "x", "0n"};
static const char *sorts[] = {"name", "size", "MTIME", "ext", "bogus"};
static const char *fields[] = {"bg", "surface", "ACCENT", "scroll_thumb", "border_inactive", "nope", "cursor_active_bg", "text"};
static const char *hexes[] = {"#112233", "aabbcc", "#ZZZ", "#12345", "#ffFFff", "#000000", "#1234567", ""};
static const char *specs[] = {"F1", "f12", "F13", "F10", "ctrl+a", "Ctrl+Alt+Q", "alt+x", "x", "ALT+ctrl+F5", "f", "Ctrl+A", "ctrl+", "F0", "q"};
static const char *acts[] = {"quit", "help", "rename", "VIEW", "edit", "copy", "move", "mkdir", "delete", "preview", "hidden", "theme", "lang",
                             "filter", "goto", "newfile", "shell", "refresh", "usermenu", "bogus"};
static const char *exts[] = {".txt", "md", ".C", ".tar.gz", ".", "", "jpg", ".verylongextensionname1234"};
static const char *seps[] = {" ", " = ", "=", "\t", "  =  ", " =\t"};
static const char *cmds[] = {"vim \"%f\"", "less %p", "echo 'a b'", "x", "a   b   c", "\"quoted cmd\" arg"};
static const char *labels[] = {"\"Label one\"", "plain", "\"With = sign\"", "\"unterminated"};
static const char *words[] = {"theme", "lang", "show_hidden", "sort", "color", "bind", "open", "menu", "Theme", "BIND", "unknown", "foo"};

static size_t gen_line(char *o)
{
    size_t n = 0;
    uint32_t k = rnd() % 16;
    const char *sep = PICK(seps);
    if (rnd() % 6 == 0) n += (size_t)sprintf(o + n, "%s", rnd() % 2 ? "  " : "\t");
    switch (k) {
    case 0: n += (size_t)sprintf(o + n, "theme%s%s", sep, PICK(themes)); break;
    case 1: n += (size_t)sprintf(o + n, "lang%s%s", sep, rnd() % 2 ? "ua" : "abcdefghijklmnopqrstuvwxyz"); break;
    case 2: n += (size_t)sprintf(o + n, "show_hidden%s%s", sep, PICK(bools)); break;
    case 3: n += (size_t)sprintf(o + n, "sort%s%s", sep, PICK(sorts)); break;
    case 4: case 5: n += (size_t)sprintf(o + n, "color %s%s%s", PICK(fields), sep, PICK(hexes)); break;
    case 6: case 7: n += (size_t)sprintf(o + n, "bind %s %s", PICK(specs), PICK(acts)); break;
    case 8: n += (size_t)sprintf(o + n, "bind%s%s%s%s", sep, PICK(specs), sep, PICK(acts)); break;
    case 9: case 10: n += (size_t)sprintf(o + n, "open %s%s%s", PICK(exts), sep, PICK(cmds)); break;
    case 11: case 12: n += (size_t)sprintf(o + n, "menu %s %s", PICK(labels), PICK(cmds)); break;
    case 13: n += (size_t)sprintf(o + n, "# comment %s", PICK(words)); break;
    case 14: n += (size_t)sprintf(o + n, "%s%s%s", PICK(words), sep, rnd() % 2 ? "" : PICK(themes)); break;
    default: break;
    }
    if (rnd() % 12 == 0) n += (size_t)sprintf(o + n, "%s", " ; trailing");
    return n;
}

int main(void)
{
    char tmpl[] = "/tmp/duop_cfgdiff_XXXXXX";
    int tfd = mkstemp(tmpl);
    if (tfd < 0) return 2;
    close(tfd);
    char env[300];
    snprintf(env, sizeof env, "DUOP_CONFIG=%s", tmpl);
    char *envp[] = {(char *)"HOME=/nonexistent", env, NULL};
    long checks = 0;
    char *text = malloc(1300000);
    for (long it = 0; it < 6000; it++) {
        size_t n = 0;
        int lines = rnd() % 60;
        int huge = rnd() % 4000 == 0;
        if (huge) lines = 70000;
        const char *eol = rnd() % 3 == 0 ? "\r\n" : "\n";
        for (int l = 0; l < lines && n < 1250000; l++) { n += gen_line(text + n); n += (size_t)sprintf(text + n, "%s", eol); }
        if (rnd() % 4 == 0 && n) n -= strlen(eol);                      /* no trailing newline */
        if (rnd() % 50 == 0) text[n++] = 0;                              /* embedded NUL */
        FILE *f = fopen(tmpl, "wb");
        fwrite(text, 1, n, f); fclose(f);
        ref_config_load(envp); config_load(envp);
        if (memcmp(ref_g_config, g_config, sizeof g_config) || ref_g_cfg_warn != g_cfg_warn) {
            size_t i = 0; while (i < sizeof g_config && ref_g_config[i] == g_config[i]) i++;
            printf("config mismatch iter %ld (file %zu bytes): first diff at offset %zu (asm %d vs C %d) warn %d/%d\n", it, n, i,
                   (unsigned char)ref_g_config[i], (unsigned char)g_config[i], ref_g_cfg_warn, g_cfg_warn);
            return 1;
        }
        for (int q = 0; q < 12; q++) {
            int key = q < 6 ? 0x100011 + (int)(rnd() % 14) : "xqabcF"[rnd() % 6], mods = rnd() % 8;
            if (ref_config_lookup_bind(key, mods) != config_lookup_bind(key, mods)) { printf("lookup_bind mismatch\n"); return 1; }
            static const char *names[] = {"a.txt", "b.MD", "c.tar.gz", ".hidden", "noext", "x.", "y.C", "z.jpg", "", "w.verylongextensionname1234"};
            const char *nm = PICK(names);
            const char *r1 = ref_config_lookup_open(nm), *r2 = config_lookup_open(nm);
            if ((r1 == NULL) != (r2 == NULL) || (r1 && strcmp(r1, r2))) { printf("lookup_open mismatch [%s]\n", nm); return 1; }
            checks += 2;
        }
        int mc = ref_config_menu_count();
        if (mc != config_menu_count()) { printf("menu_count mismatch\n"); return 1; }
        for (int i = -1; i <= mc; i++) {
            const char *l1 = 0, *c1 = 0, *l2 = 0, *c2 = 0;
            int a = ref_config_menu_item(i, &l1, &c1), b = config_menu_item(i, &l2, &c2);
            if (a != b || (a && (strcmp(l1, l2) || strcmp(c1, c2)))) { printf("menu_item mismatch %d\n", i); return 1; }
        }
        checks += 3;
    }
    unlink(tmpl);
    printf("OK 6000 random duoprc files: g_config (15024 B) + lookups identical (%ld checks)\n", checks);
    return 0;
}
