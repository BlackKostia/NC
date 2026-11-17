/* src/fs/dir_fuzzy.c - fuzzy matching scorer of the fuzzy finder (freestanding C23; replaces dir_fuzzy.s). Case-insensitive
 * ASCII subsequence match: +2 per matched character, +8 when it directly follows the previous match, +6 at the start of a
 * word (candidate start or after / _ - . space); the total loses one point per four candidate characters consumed. */
#include "duop_fs.h"

static char fold(char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : c; }
static bool word_start(char prev) { return prev == '/' || prev == '_' || prev == '-' || prev == '.' || prev == ' '; }

int fuzzy_score(const char *query, const char *cand, uint64_t *out_mask)
{
    if (out_mask) *out_mask = 0;
    if (!*query) return 0;
    int score = 0;
    uint32_t idx = 0;
    bool prev_matched = false;
    uint64_t mask = 0;
    for (const char *c = cand; *query; c++, idx++) {
        if (!*c) return -1;                                        /* the query is not a subsequence */
        if (fold(*query) != fold(*c)) { prev_matched = false; continue; }
        score += 2;
        if (prev_matched) score += 8;
        if (idx == 0 || word_start(c[-1])) score += 6;
        if (idx < 64) mask |= 1ull << idx;
        prev_matched = true;
        query++;
    }
    score -= (int)(idx >> 2);
    if (score < 1) score = 1;
    if (out_mask) *out_mask = mask;
    return score;
}
