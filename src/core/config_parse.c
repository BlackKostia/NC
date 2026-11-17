/* src/core/config_parse.c - one duoprc line -> g_config (freestanding C23; replaces config_parse.s).
 *   theme = 0|1|2|tokyo|catppuccin|emerald     lang = <pack id>      show_hidden = 1|0|on|off|true|false
 *   sort = name|size|mtime|ext                 color <field> #RRGGBB
 *   bind <key> <action>                        open <.ext> <command>   menu "<label>" <command>
 * Unknown keywords, bad values and full tables are ignored silently. */
#include "duop_config.h"
#include "duop_string.h"

static const char *const color_fields[CFG_COLOR_FIELDS] = {
    "bg", "surface", "surface_alt", "header_bg", "header_fg", "accent", "accent_fg", "border_active", "border_inactive",
    "text", "muted", "dir_fg", "exec_fg", "link_fg", "hidden_fg", "selected_fg", "selected_bg", "cursor_active_bg",
    "cursor_inactive_bg", "badge_bg", "badge_hover_bg", "badge_fg", "dialog_bg", "dialog_border", "ok_fg", "warn_fg",
    "err_fg", "scroll_track", "scroll_thumb",
};

static const char *const action_names[] = {
    "quit", "help", "rename", "view", "edit", "copy", "move", "mkdir", "delete", "preview",
    "hidden", "theme", "lang", "filter", "goto", "newfile", "shell", "refresh", "usermenu",
};
#define ACTION_COUNT ((int)(sizeof action_names / sizeof action_names[0]))

static bool is(const char *a, const char *b) { return str_casecmp(a, b) == 0; }

static int find(const char *const *table, int n, const char *name)
{
    for (int i = 0; i < n; i++)
        if (is(name, table[i])) return i;
    return -1;
}

static void set_theme(Config *c, const char *v)
{
    if (v[0] >= '0' && v[0] <= '2' && !v[1]) c->theme = v[0] - '0';
    else if (is(v, "tokyo")) c->theme = 0;
    else if (is(v, "catppuccin")) c->theme = 1;
    else if (is(v, "emerald")) c->theme = 2;
}

static void set_hidden(Config *c, const char *v)
{
    if (v[0] == '1' || is(v, "on") || is(v, "true")) c->hidden = 1;
    else if (v[0] == '0' || is(v, "off") || is(v, "false")) c->hidden = 0;
}

static void set_sort(Config *c, const char *v)
{
    if (is(v, "name")) c->sort = SORT_NAME;
    else if (is(v, "size")) c->sort = SORT_SIZE;
    else if (is(v, "mtime")) c->sort = SORT_MTIME;
    else if (is(v, "ext")) c->sort = SORT_EXT;
}

static void add_color(Config *c, char *rest)
{
    CfgToken field = next_token(rest);
    if (!field.tok) return;
    CfgToken hex = next_token(field.next);
    if (!hex.tok) return;
    int32_t rgb = parse_hex_rgb(hex.tok);
    if (rgb < 0) return;
    int i = find(color_fields, CFG_COLOR_FIELDS, field.tok);
    if (i < 0) return;
    c->colors[i] = (uint32_t)rgb;
    c->color_mask |= 1u << i;
}

static void add_bind(Config *c, char *rest)
{
    CfgToken key = next_token(rest);
    if (!key.tok) return;
    CfgToken act = next_token(key.next);
    if (!act.tok) return;
    CfgKey k = parse_key_spec(key.tok);
    if (!k.key) return;
    int a = find(action_names, ACTION_COUNT, act.tok);
    if (a < 0 || c->bind_cnt >= CFG_MAX_BINDS) return;
    c->binds[c->bind_cnt].key = (int32_t)k.key;
    c->binds[c->bind_cnt].mods = (int32_t)k.mods;
    c->binds[c->bind_cnt].action = a + 1;                  /* ACT_* are 1..19 */
    c->bind_cnt++;
}

static void add_open(Config *c, char *rest)
{
    CfgToken ext = next_token(rest);
    if (!ext.tok) return;
    const char *e = ext.tok + (ext.tok[0] == '.');
    if (!*e) return;
    char *cmd = skip_ws(ext.next);
    if (!*cmd || c->open_cnt >= CFG_MAX_OPENS) return;
    str_copy(c->opens[c->open_cnt].ext, e, sizeof c->opens[0].ext);
    str_copy(c->opens[c->open_cnt].cmd, cmd, sizeof c->opens[0].cmd);
    c->open_cnt++;
}

static void add_menu(Config *c, char *rest)
{
    CfgToken label = next_token(rest);
    if (!label.tok) return;
    char *cmd = skip_ws(label.next);
    if (!*cmd || c->menu_cnt >= CFG_MAX_MENUS) return;
    str_copy(c->menus[c->menu_cnt].label, label.tok, sizeof c->menus[0].label);
    str_copy(c->menus[c->menu_cnt].cmd, cmd, sizeof c->menus[0].cmd);
    c->menu_cnt++;
}

void parse_config_line(char *line)
{
    char *p = skip_ws(line);
    if (!*p || *p == '#' || *p == ';') return;
    CfgToken kw = next_token(p);
    if (!kw.tok) return;
    char *rest = skip_ws(kw.next);
    if (*rest == '=') rest = skip_ws(rest + 1);
    Config *c = &g_config;
    if (is(kw.tok, "color")) { add_color(c, rest); return; }
    if (is(kw.tok, "bind")) { add_bind(c, rest); return; }
    if (is(kw.tok, "open")) { add_open(c, rest); return; }
    if (is(kw.tok, "menu")) { add_menu(c, rest); return; }
    CfgToken v = next_token(rest);
    if (!v.tok) return;
    if (is(kw.tok, "theme")) set_theme(c, v.tok);
    else if (is(kw.tok, "lang")) str_copy(c->lang_id, v.tok, I18N_ID_LEN);
    else if (is(kw.tok, "show_hidden")) set_hidden(c, v.tok);
    else if (is(kw.tok, "sort")) set_sort(c, v.tok);
}
