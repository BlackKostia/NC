/* src/core/config.c - duoprc text helpers: env lookup, whitespace/token scanning, colour and key-spec parsing
 * (freestanding C23; replaces config.s). Tokens are cut in place, exactly like the assembly version. */
#include "duop_config.h"
#include "duop_string.h"

const char *cfg_getenv(char **envp, const char *key_eq)
{
    if (!envp) return nullptr;
    size_t n = str_len(key_eq);
    for (; *envp; envp++)
        if (str_starts_with(*envp, key_eq)) return *envp + n;
    return nullptr;
}

char *skip_ws(char *p)
{
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

static int hex_val(uint8_t c)
{
    if (c >= '0' && c <= '9') return c - '0';
    c |= 0x20;
    return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

/* Exactly six hex digits (anything after them is ignored); the 0x01 marker byte distinguishes "black" from "unset". */
int32_t parse_hex_rgb(const char *s)
{
    if (*s == '#') s++;
    uint32_t acc = 0;
    for (int i = 0; i < 6; i++) {
        int v = hex_val((uint8_t)s[i]);
        if (v < 0) return -1;
        acc = acc << 4 | (uint32_t)v;
    }
    return (int32_t)(acc | 0x01000000u);
}

static bool prefix_ci(const char *s, const char *lower_prefix)
{
    for (; *lower_prefix; s++, lower_prefix++)
        if ((*s | 0x20) != *lower_prefix) return false;
    return true;
}

CfgKey parse_key_spec(const char *tok)
{
    uint32_t mods = 0;
    for (;;) {                                          /* any number of "ctrl+" / "alt+" prefixes, any case */
        if (prefix_ci(tok, "ctrl") && tok[4] == '+') { mods |= MOD_CTRL; tok += 5; }
        else if (prefix_ci(tok, "alt") && tok[3] == '+') { mods |= MOD_ALT; tok += 4; }
        else break;
    }
    const CfgKey bad = {0, 0};
    if (!*tok) return bad;
    if (!tok[1]) {                                      /* one character; Ctrl+<letter> is stored lower-case */
        uint32_t c = (uint8_t)tok[0];
        if ((mods & MOD_CTRL) && c >= 'A' && c <= 'Z') c += 32;
        return (CfgKey){c, mods};
    }
    if ((tok[0] | 0x20) != 'f' || tok[1] < '1' || tok[1] > '9') return bad;
    if (!tok[2]) return (CfgKey){KEY_F1 + (uint32_t)(tok[1] - '1'), mods};
    if (tok[1] != '1' || tok[3]) return bad;
    if (tok[2] == '0') return (CfgKey){KEY_F10, mods};
    if (tok[2] == '1') return (CfgKey){KEY_F11, mods};
    if (tok[2] == '2') return (CfgKey){KEY_F12, mods};
    return bad;
}

/* Skips blanks, then returns the token and the cursor after its terminator ('=' and blanks end a bare token, the
 * closing quote ends a "quoted" one). tok == NULL when nothing is left. */
CfgToken next_token(char *cursor)
{
    char *start = skip_ws(cursor);
    if (!*start) return (CfgToken){nullptr, start};
    bool quoted = *start == '"';
    if (quoted) start++;
    char *p = start;
    while (*p && !(quoted ? *p == '"' : (*p == ' ' || *p == '\t' || *p == '='))) p++;
    if (!*p) return (CfgToken){start, p};
    *p = 0;
    return (CfgToken){start, p + 1};
}
