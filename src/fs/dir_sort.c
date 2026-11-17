/* src/fs/dir_sort.c - comparison sorts of DirModel index slices: the comparator, insertion sort, heapsort and introsort
 * (freestanding C23; replaces dir_sort.s + dir_sort_intro.s, kept as tests/harness/dir_sort_reference.s and
 * dir_sort_intro_reference.s). The radix and prefix-key sorts and DirModel_sort itself are in dir_sort_radix.c.
 *
 * Every sort orders uint32_t indices into the FileEntry array. Equal primary keys (size, mtime, extension) always fall back to the
 * name in ascending order, whatever the direction, so the order is deterministic. */
#include "duop_fs.h"
#include "duop_string.h"

#define INSERTION_MIN_N 16

typedef struct SortCtx { const FileEntry *entries; const char *pool; uint32_t mode, desc; } SortCtx;

uint64_t extract_radix_key(uint32_t idx, const FileEntry *entries, uint32_t mode, uint32_t desc)
{
    const FileEntry *e = &entries[idx];
    uint64_t k = (uint64_t)(mode == SORT_MTIME ? e->mtime : e->size) ^ 0x8000000000000000ull;   /* signed -> monotonic unsigned */
    return desc ? ~k : k;
}

static int ds_sign(int64_t a, int64_t b) { return a > b ? 1 : -1; }

int cmp_indices(uint32_t a, uint32_t b, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    if (a == b) return 0;
    const FileEntry *ea = &entries[a], *eb = &entries[b];
    const char *na = pool + ea->name_off, *nb = pool + eb->name_off;
    int r = 0;
    if (mode == SORT_SIZE || mode == SORT_MTIME) {
        int64_t ka = mode == SORT_SIZE ? ea->size : ea->mtime, kb = mode == SORT_SIZE ? eb->size : eb->mtime;
        if (ka != kb) r = ds_sign(ka, kb);
    } else if (mode == SORT_EXT) {
        uint32_t xa = ea->ext_offset, xb = eb->ext_offset;
        if (!xa) r = xb ? -1 : 0;                                    /* no extension sorts first */
        else if (!xb) r = 1;
        else r = str_casecmp(na + xa + 1, nb + xb + 1);
    }
    if (mode == SORT_SIZE || mode == SORT_MTIME || mode == SORT_EXT) {
        if (r) return desc ? -r : r;
        desc = 0;                                                    /* equal primary keys: name, ascending */
    }
    r = str_casecmp(na, nb);
    if (!r) r = str_cmp(na, nb);
    return desc ? -r : r;
}

static int ds_cmp(const SortCtx *c, uint32_t a, uint32_t b) { return cmp_indices(a, b, c->entries, c->pool, c->mode, c->desc); }

static void ds_swap(uint32_t *arr, size_t i, size_t j)
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
        size_t j = i;
        while (j > 0 && ds_cmp(&c, arr[j - 1], key) > 0) {
            arr[j] = arr[j - 1];
            j--;
        }
        arr[j] = key;
    }
}

static void sift_down_u32(uint32_t *arr, size_t root, size_t n, const SortCtx *c)
{
    for (;;) {
        size_t child = 2 * root + 1, sw = root;
        if (child >= n) return;
        if (ds_cmp(c, arr[sw], arr[child]) < 0) sw = child;
        if (child + 1 < n && ds_cmp(c, arr[sw], arr[child + 1]) < 0) sw = child + 1;
        if (sw == root) return;
        ds_swap(arr, root, sw);
        root = sw;
    }
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

/* median of three (arr[0] <= arr[mid] <= arr[len - 1]), then a Hoare partition around arr[mid]: the length of the left part */
static size_t ds_partition(uint32_t *arr, size_t len, const SortCtx *c)
{
    size_t mid = len / 2, hi = len - 1;
    if (ds_cmp(c, arr[0], arr[mid]) > 0) ds_swap(arr, 0, mid);
    if (ds_cmp(c, arr[0], arr[hi]) > 0) ds_swap(arr, 0, hi);
    if (ds_cmp(c, arr[mid], arr[hi]) > 0) ds_swap(arr, mid, hi);
    uint32_t pivot = arr[mid];
    size_t i = (size_t)-1, j = len;
    for (;;) {
        do i++; while (ds_cmp(c, arr[i], pivot) < 0);
        do j--; while (ds_cmp(c, pivot, arr[j]) < 0);
        if ((intptr_t)i >= (intptr_t)j) return j + 1;
        ds_swap(arr, i, j);
    }
}

/* recursion only on the smaller part: depth <= log2(len) */
static void introsort_loop(uint32_t *arr, size_t len, size_t depth, const SortCtx *c)
{
    while (len > INSERTION_MIN_N) {
        if (!depth) {
            heapsort_u32(arr, len, c->entries, c->pool, c->mode, c->desc);
            return;
        }
        depth--;
        size_t left = ds_partition(arr, len, c), right = len - left;
        if (left < right) {
            introsort_loop(arr, left, depth, c);
            arr += left;
            len = right;
        } else {
            introsort_loop(arr + left, right, depth, c);
            len = left;
        }
    }
    insertion_sort_u32(arr, len, c->entries, c->pool, c->mode, c->desc);
}

void introsort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    if (len < 2) return;
    const SortCtx c = {entries, pool, mode, desc};
    introsort_loop(arr, len, 2 * (size_t)(63 - __builtin_clzll(len)), &c);
}
