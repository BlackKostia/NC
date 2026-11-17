/* src/tui/theme.c - TrueColor 24-bit themes (Tokyo Night, Catppuccin Mocha, Cyber Emerald); replaces theme.s.
 * theme_get() returns one shared writable copy of the chosen palette with the duoprc `color` overrides applied. */
#include "duop_config.h"
#include "duop_tui.h"

#define THEME_COUNT 3

/* name, then the 29 colours in Theme/Config.colors order: bg surface surface_alt header_bg header_fg accent accent_fg
 * border_active border_inactive text muted dir_fg exec_fg link_fg hidden_fg selected_fg selected_bg cursor_active_bg
 * cursor_inactive_bg badge_bg badge_hover_bg badge_fg dialog_bg dialog_border ok_fg warn_fg err_fg scroll_track scroll_thumb */
#define T(nm, ...) { .name = nm, .colors = { __VA_ARGS__ } }
static const Theme themes_table[THEME_COUNT] = {
    T("Tokyo Night",
        0x0116161E, 0x011A1B26, 0x011F2335, 0x0113141C, 0x01C0CAF5, 0x017AA2F7,
        0x0115161E, 0x017AA2F7, 0x013B4261, 0x01C0CAF5, 0x01565F89, 0x017DCFFF,
        0x019ECE6A, 0x01BB9AF7, 0x016B739E, 0x01E0AF68, 0x01292E42, 0x01283457,
        0x01202436, 0x0124283B, 0x013B4261, 0x01C0CAF5, 0x011D202F, 0x01BB9AF7,
        0x019ECE6A, 0x01E0AF68, 0x01F7768E, 0x01292E42, 0x017AA2F7),
    T("Catppuccin",
        0x01181825, 0x011E1E2E, 0x01252538, 0x0111111B, 0x01CDD6F4, 0x01CBA6F7,
        0x0111111B, 0x01CBA6F7, 0x0145475A, 0x01CDD6F4, 0x016C7086, 0x0189B4FA,
        0x01A6E3A1, 0x0194E2D5, 0x017F849C, 0x01F9E2AF, 0x01313244, 0x01363850,
        0x01262738, 0x01313244, 0x0145475A, 0x01CDD6F4, 0x011E1E2E, 0x01F5C2E7,
        0x01A6E3A1, 0x01F9E2AF, 0x01F38BA8, 0x01313244, 0x01CBA6F7),
    T("Emerald",
        0x010A1014, 0x010F171C, 0x01142026, 0x01070C0F, 0x01D8E8EE, 0x0100E5A3,
        0x01061210, 0x0100E5A3, 0x01243B44, 0x01D8E8EE, 0x015D7882, 0x0138BDF8,
        0x01A3E635, 0x01F472B6, 0x01607D87, 0x01FBBF24, 0x01182C34, 0x01173842,
        0x0113222A, 0x01182830, 0x01243B44, 0x01D8E8EE, 0x01111C22, 0x0138BDF8,
        0x0100E5A3, 0x01FBBF24, 0x01FB7185, 0x01182C34, 0x0100E5A3),
};
#undef T

static Theme g_active_theme;

int theme_count(void) { return THEME_COUNT; }

const Theme *theme_get(int idx)
{
    int i = idx % THEME_COUNT;
    if (i < 0) i += THEME_COUNT;
    g_active_theme = themes_table[i];
    const Config *cfg = config_get();
    for (unsigned k = 0; k < CFG_COLOR_FIELDS; k++)
        if (cfg->color_mask >> k & 1) g_active_theme.colors[k] = cfg->colors[k];
    return &g_active_theme;
}
