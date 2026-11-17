/* src/fs/nav_state.c - per-tab navigation history (freestanding C23; replaces nav_state.s and nav_state_history.s). A tab
 * block (NavTab, 4384 bytes, eight per pane) keeps the directory, cursor and sort state of the tab and up to 32 visited
 * paths; going to a new place cuts the "forward" part of the history, repeating the current place records nothing, and a full
 * history drops its oldest entry. nav_tabs_alloc / nav_tabs_free own the block and the strings of the history. */
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_string.h"

char *nav_strdup(const char *s)
{
    size_t n = str_len(s) + 1;
    char *p = mem_alloc(n);
    if (p) str_copy(p, s, n);
    return p;
}

/* ASCII case-insensitive substring test; an empty needle matches */
int nav_ci_contains(const char *hay, const char *needle)
{
    if (!*needle) return 1;
    for (; *hay; hay++) {
        size_t i = 0;
        for (;; i++) {
            if (!needle[i]) return 1;
            if (!hay[i]) return 0;
            char a = hay[i], b = needle[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
        }
    }
    return 0;
}

NavTab *nav_tabs_alloc(const char *init_path)
{
    NavTab *tabs = mem_alloc(NAV_TAB_MAX * sizeof(NavTab));
    if (!tabs) return nullptr;
    mem_zero(tabs, NAV_TAB_MAX * sizeof(NavTab));
    if (!init_path) return tabs;
    str_copy(tabs[0].path, init_path, PATH_MAX);
    tabs[0].hist[0] = nav_strdup(init_path);
    if (tabs[0].hist[0]) { tabs[0].hist_len = 1; tabs[0].hist_pos = 0; }
    return tabs;
}

void nav_tabs_free(NavTab *tabs, int tab_count)
{
    if (!tabs) return;
    for (int t = 0; t < tab_count; t++)
        for (int h = 0; h < tabs[t].hist_len; h++) mem_free(tabs[t].hist[h]);
    mem_free(tabs);
}

void nav_hist_push(NavTab *tab, const char *path)
{
    if (!tab || !path || !*path) return;
    int32_t len = tab->hist_len;
    uint32_t pos = (uint32_t)tab->hist_pos;
    if (len != 0 && pos < (uint32_t)len) {
        if (tab->hist[pos] && !str_cmp(tab->hist[pos], path)) return;      /* already there */
        for (int32_t i = (int32_t)pos + 1; i < len; i++) {                 /* a new place cuts the forward history */
            mem_free(tab->hist[i]);
            tab->hist[i] = nullptr;
        }
        len = (int32_t)pos + 1;
        tab->hist_len = len;
    }
    if (len >= NAV_HIST_MAX) {                                             /* full: the oldest entry falls off */
        mem_free(tab->hist[0]);
        for (int i = 0; i < NAV_HIST_MAX - 1; i++) tab->hist[i] = tab->hist[i + 1];
        len = NAV_HIST_MAX - 1;
        tab->hist_len = len;
    }
    char *copy = nav_strdup(path);
    if (!copy) return;
    tab->hist[len] = copy;
    tab->hist_pos = len;
    tab->hist_len = len + 1;
}

const char *nav_hist_back(NavTab *tab)
{
    if (!tab || tab->hist_pos <= 0) return nullptr;
    return tab->hist[--tab->hist_pos];
}

const char *nav_hist_fwd(NavTab *tab)
{
    if (!tab || tab->hist_pos + 1 >= tab->hist_len) return nullptr;
    return tab->hist[++tab->hist_pos];
}
