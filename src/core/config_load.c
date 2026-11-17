/* src/core/config_load.c - locate, read and apply ~/.config/duop/duoprc; typed lookups (freestanding C23;
 * replaces config_load.s). Lookup order: $DUOP_CONFIG, $XDG_CONFIG_HOME/duop/duoprc, $HOME/.config/duop/duoprc. */
#include "duop_config.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

void *mem_alloc(size_t size);
void mem_free(void *ptr);

Config g_config;
int32_t g_cfg_warn;

Config *config_get(void) { return &g_config; }

/* Splits buf into lines in place ("\n" or "\r\n" terminated, the last line may lack one) and parses each. */
static void parse_buf(char *buf)
{
    while (*buf) {
        char *end = buf;
        while (*end && *end != '\n') end++;
        bool had_nl = *end == '\n';
        *end = 0;
        if (end > buf && end[-1] == '\r') end[-1] = 0;
        parse_config_line(buf);
        if (!had_nl) return;
        buf = end + 1;
    }
}

static void load_file(const char *path)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd < 0) return;
    FileStat st;
    if (os_fstat((int)fd, &st) >= 0 && (st.mode & S_IFMT) == S_IFREG) {
        uint64_t size = (uint64_t)st.size;
        if (size > CFG_FILE_HARD) {                         /* beyond the hard limit the head is used and the user is told */
            g_cfg_warn = 1;
            size = CFG_FILE_HARD;
        }
        char *buf = mem_alloc(size + 1);                    /* exactly the file size + NUL: no silent cap below the limit */
        if (buf) {
            size_t total = 0;
            intptr_t n = 0;
            while (total < size && (n = sys_read_retry((int)fd, buf + total, size - total)) > 0) total += (size_t)n;
            if (n >= 0) {
                if (g_cfg_warn)
                    while (total && buf[total - 1] != '\n') total--;   /* a cut file ends at its last complete line */
                buf[total] = 0;
                parse_buf(buf);
            }
            mem_free(buf);
        }
    }
    (void)os_close((int)fd);
}

void config_load(char **envp)
{
    char path[PATH_MAX];
    __builtin_memset(&g_config, 0, sizeof g_config);
    g_config.theme = g_config.lang = g_config.hidden = g_config.sort = -1;

    const char *v = cfg_getenv(envp, "DUOP_CONFIG=");
    if (v && *v) { load_file(v); return; }
    v = cfg_getenv(envp, "XDG_CONFIG_HOME=");
    if (v && *v && path_join(path, v, "duop/duoprc", PATH_MAX) >= 0) { load_file(path); return; }
    v = cfg_getenv(envp, "HOME=");
    if (v && *v && path_join(path, v, ".config/duop/duoprc", PATH_MAX) >= 0) load_file(path);
}

int config_lookup_bind(int key, int mods)
{
    for (uint32_t i = 0; i < g_config.bind_cnt; i++)
        if (g_config.binds[i].key == key && g_config.binds[i].mods == mods) return g_config.binds[i].action;
    return -1;
}

const char *config_lookup_open(const char *name)
{
    if (!name || !*name) return nullptr;
    const char *ext = nullptr;
    for (size_t i = 1; name[i]; i++)                        /* the last '.' after index 0 */
        if (name[i] == '.') ext = name + i + 1;
    if (!ext || !*ext) return nullptr;
    for (uint32_t i = 0; i < g_config.open_cnt; i++)
        if (str_casecmp(ext, g_config.opens[i].ext) == 0) return g_config.opens[i].cmd;
    return nullptr;
}

#define DEFAULT_MENU_COUNT 3
static const char *const default_menu[DEFAULT_MENU_COUNT][2] = {
    {"Disk usage of current dir (du -sh)", "du -sh \"%d\"; printf 'Press Enter...'; read -r _"},
    {"File info (file / stat)", "file \"%p\"; stat \"%p\"; printf 'Press Enter...'; read -r _"},
    {"Line count (wc -l)", "wc -l \"%p\"; printf 'Press Enter...'; read -r _"},
};

int config_menu_count(void)
{
    return g_config.menu_cnt ? (int)g_config.menu_cnt : DEFAULT_MENU_COUNT;
}

int config_menu_item(int idx, const char **out_label, const char **out_cmd)
{
    uint32_t i = (uint32_t)idx;
    if (g_config.menu_cnt) {
        if (i >= g_config.menu_cnt) return 0;
        *out_label = g_config.menus[i].label;
        *out_cmd = g_config.menus[i].cmd;
        return 1;
    }
    if (i >= DEFAULT_MENU_COUNT) return 0;
    *out_label = default_menu[i][0];
    *out_cmd = default_menu[i][1];
    return 1;
}
