/* src/fs/dir_sort.c - comparison sorts of DirModel index slices: fast single-pass comparator, insertion sort,
 * Floyd hole-sifting heapsort and pattern-defeating quicksort (pdqsort) with O(n) presorted / reverse-sorted /
 * duplicate-key paths and worst-case O(n log n) heapsort fallback (freestanding C23).
 *
 * Every sort orders uint32_t indices into the FileEntry array. Equal primary keys (size, mtime, extension) always
 * fall back to the name in ascending order, whatever the direction, so the order is deterministic. */
#include "duop_fs.h"

#define INSERTION_MIN_N 24
#define NINTHER_MIN_N 128
#define PARTIAL_INS_LIMIT 8

typedef struct SortCtx { const FileEntry *entries; const char *pool; uint32_t mode, desc; } SortCtx;

uint64_t extract_radix_key(uint32_t idx, const FileEntry *entries, uint32_t mode, uint32_t desc)
{
    const FileEntry *e = &entries[idx];
    uint64_t k = (uint64_t)(mode == SORT_MTIME ? e->mtime : e->size) ^ 0x8000000000000000ull;   /* signed -> monotonic unsigned */
    return desc ? ~k : k;
}

static inline uint8_t ds_lower(uint8_t c) { return (uint8_t)(c - 'A') <= 25 ? (uint8_t)(c + 32) : c; }

static int ds_casecmp(const char *a, const char *b)
{
    const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
    for (;; x++, y++) {
        uint8_t cx = *x, cy = *y;
        if (cx != cy) {
            uint8_t lx = ds_lower(cx), ly = ds_lower(cy);
            if (lx != ly) return (int)lx - (int)ly;
        } else if (!cx) {
            return 0;
        }
    }
}

/* Single-pass case-insensitive compare with case-sensitive tie-break: exact match to str_casecmp + str_cmp. */
static int ds_cmp_name(const char *a, const char *b)
{
    if (a == b) return 0;
    const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
    int tie = 0;
    for (;; x++, y++) {
        uint8_t cx = *x, cy = *y;
        if (cx != cy) {
            uint8_t lx = ds_lower(cx), ly = ds_lower(cy);
            if (lx != ly) return (int)lx - (int)ly;
            if (!tie) tie = (int)cx - (int)cy;
        } else if (!cx) {
            return tie;
        }
    }
}

int cmp_indices(uint32_t a, uint32_t b, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    if (a == b) return 0;
    const FileEntry *ea = &entries[a], *eb = &entries[b];
    const char *na = pool + ea->name_off, *nb = pool + eb->name_off;
    if (mode == SORT_SIZE || mode == SORT_MTIME) {
        int64_t ka = mode == SORT_SIZE ? ea->size : ea->mtime, kb = mode == SORT_SIZE ? eb->size : eb->mtime;
        if (ka != kb) {
            int r = ka > kb ? 1 : -1;
            return desc ? -r : r;
        }
        return ds_cmp_name(na, nb);                                  /* equal primary keys: name, ascending */
    }
    if (mode == SORT_EXT) {
        uint32_t xa = ea->ext_offset, xb = eb->ext_offset;
        int r = !xa ? (xb ? -1 : 0) : !xb ? 1 : ds_casecmp(na + xa + 1, nb + xb + 1);
        if (r) return desc ? -r : r;
        return ds_cmp_name(na, nb);
    }
    int r = ds_cmp_name(na, nb);
    return desc ? -r : r;
}

static inline int ds_cmp(const SortCtx *c, uint32_t a, uint32_t b)
{
    return cmp_indices(a, b, c->entries, c->pool, c->mode, c->desc);
}

static inline void ds_swap(uint32_t *arr, size_t i, size_t j)
{
    uint32_t t = arr[i];
    arr[i] = arr[j];
    arr[j] = t;
}

void insertion_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    const SortCtx c = {entries, pool, mode, desc};
    for (size_t i = 1; i < len; i++) {
        uint32_t key = arr[i];
        if (ds_cmp(&c, arr[i - 1], key) <= 0) continue;
        size_t j = i;
        do {
            arr[j] = arr[j - 1];
            j--;
        } while (j > 0 && ds_cmp(&c, arr[j - 1], key) > 0);
        arr[j] = key;
    }
}

/* Bounded insertion sort for nearly-sorted partitions: returns true if the slice is now sorted. */
static bool ds_partial_insertion(uint32_t *arr, size_t len, const SortCtx *c)
{
    size_t moves = 0;
    for (size_t i = 1; i < len; i++) {
        uint32_t key = arr[i];
        if (ds_cmp(c, arr[i - 1], key) <= 0) continue;
        size_t j = i;
        do {
            arr[j] = arr[j - 1];
            j--;
            if (++moves > PARTIAL_INS_LIMIT) {
                arr[j] = key;
                return false;
            }
        } while (j > 0 && ds_cmp(c, arr[j - 1], key) > 0);
        arr[j] = key;
    }
    return true;
}

/* Floyd hole-sifting: lifts larger child up, writes original root once. */
static void sift_down_u32(uint32_t *arr, size_t root, size_t n, const SortCtx *c)
{
    uint32_t val = arr[root];
    for (;;) {
        size_t child = 2 * root + 1;
        if (child >= n) break;
        if (child + 1 < n && ds_cmp(c, arr[child], arr[child + 1]) < 0) child++;
        if (ds_cmp(c, val, arr[child]) >= 0) break;
        arr[root] = arr[child];
        root = child;
    }
    arr[root] = val;
}

void heapsort_u32(uint32_t *arr, size_t n, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    if (n < 2) return;
    const SortCtx c = {entries, pool, mode, desc};
    for (size_t i = n / 2; i-- > 0;) sift_down_u32(arr, i, n, &c);
    for (size_t end = n - 1; end > 0; end--) {
        ds_swap(arr, 0, end);
        sift_down_u32(arr, 0, end, &c);
    }
}

static void ds_sort3(uint32_t *arr, size_t a, size_t b, size_t d, const SortCtx *c)
{
    if (ds_cmp(c, arr[a], arr[b]) > 0) ds_swap(arr, a, b);
    if (ds_cmp(c, arr[b], arr[d]) > 0) {
        ds_swap(arr, b, d);
        if (ds_cmp(c, arr[a], arr[b]) > 0) ds_swap(arr, a, b);
    }
}

/* Median-of-3 (or Tukey's ninther for >= 128 elements), placing the chosen pivot at arr[0]. */
static void ds_pick_pivot(uint32_t *arr, size_t len, const SortCtx *c)
{
    size_t mid = len / 2, hi = len - 1;
    if (len >= NINTHER_MIN_N) {
        ds_sort3(arr, 0, mid, hi, c);
        ds_sort3(arr, 1, mid - 1, hi - 1, c);
        ds_sort3(arr, 2, mid + 1, hi - 2, c);
        ds_sort3(arr, mid - 1, mid, mid + 1, c);
    } else {
        ds_sort3(arr, 0, mid, hi, c);
    }
    ds_swap(arr, 0, mid);
}

/* Partitions arr[0..len) around pivot = arr[0] into [< pivot][pivot][>= pivot]; sets *already if 0 swaps occurred. */
static size_t ds_partition_right(uint32_t *arr, size_t len, const SortCtx *c, bool *already)
{
    uint32_t pivot = arr[0];
    size_t i = 0, j = len;
    while (++i < j && ds_cmp(c, arr[i], pivot) < 0) {}
    while (j > i && ds_cmp(c, arr[j - 1], pivot) >= 0) j--;
    *already = (i >= j);
    while (i < j) {
        ds_swap(arr, i, --j);
        while (++i < j && ds_cmp(c, arr[i], pivot) < 0) {}
        while (j > i && ds_cmp(c, arr[j - 1], pivot) >= 0) j--;
    }
    size_t pos = i - 1;
    arr[0] = arr[pos];
    arr[pos] = pivot;
    return pos;
}

/* Partitions arr[0..len) when pivot == arr[-1] into [== pivot][> pivot]; returns start of the > pivot suffix. */
static size_t ds_partition_left(uint32_t *arr, size_t len, const SortCtx *c)
{
    uint32_t pivot = arr[0];
    size_t i = 0, j = len;
    while (j > 1 && ds_cmp(c, pivot, arr[j - 1]) < 0) j--;
    while (++i < j && ds_cmp(c, pivot, arr[i]) >= 0) {}
    while (i < j) {
        ds_swap(arr, i, --j);
        while (j > i && ds_cmp(c, pivot, arr[j - 1]) < 0) j--;
        while (++i < j && ds_cmp(c, pivot, arr[i]) >= 0) {}
    }
    size_t pos = i - 1;
    arr[0] = arr[pos];
    arr[pos] = pivot;
    return pos + 1;
}

static void pdq_loop(uint32_t *arr, size_t len, size_t bad, bool leftmost, const SortCtx *c)
{
    while (len > INSERTION_MIN_N) {
        ds_pick_pivot(arr, len, c);
        if (!leftmost && ds_cmp(c, arr[-1], arr[0]) >= 0) {
            size_t eq = ds_partition_left(arr, len, c);
            arr += eq;
            len -= eq;
            leftmost = false;
            continue;
        }
        bool already = false;
        size_t pos = ds_partition_right(arr, len, c, &already);
        size_t left = pos, right = len - pos - 1;
        if (left < len / 8 || right < len / 8) {
            if (!bad) {
                heapsort_u32(arr, len, c->entries, c->pool, c->mode, c->desc);
                return;
            }
            bad--;
            if (left >= INSERTION_MIN_N) { ds_swap(arr, 0, left / 4); ds_swap(arr, pos - 1, pos - left / 4); }
            if (right >= INSERTION_MIN_N) { ds_swap(arr, pos + 1, pos + 1 + right / 4); ds_swap(arr, len - 1, len - 1 - right / 4); }
        } else if (already) {
            if (ds_partial_insertion(arr, left, c) && ds_partial_insertion(arr + pos + 1, right, c)) return;
        }
        if (left < right) {
            pdq_loop(arr, left, bad, leftmost, c);
            arr += pos + 1;
            len = right;
            leftmost = false;
        } else {
            pdq_loop(arr + pos + 1, right, bad, false, c);
            len = left;
        }
    }
    insertion_sort_u32(arr, len, c->entries, c->pool, c->mode, c->desc);
}

void introsort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    if (len < 2) return;
    const SortCtx c = {entries, pool, mode, desc};
    if (len > INSERTION_MIN_N) {                                     /* O(n) fast path for already-sorted / reversed */
        bool asc = true, rev = true;
        for (size_t i = 1; i < len && (asc || rev); i++) {
            int r = ds_cmp(&c, arr[i - 1], arr[i]);
            if (r > 0) asc = false;
            else if (r < 0) rev = false;
        }
        if (asc) return;
        if (rev) {
            for (size_t lo = 0, hi = len - 1; lo < hi; lo++, hi--) ds_swap(arr, lo, hi);
            return;
        }
    }
    pdq_loop(arr, len, (size_t)(63 - __builtin_clzll(len)), true, &c);
}
