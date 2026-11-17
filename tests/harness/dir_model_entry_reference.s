# Frozen reference oracle: DirModel_get_entry and mark_link_dir as they were in src/fs/dir_model_filter.s before they moved to
# src/fs/dir_model_stat.c (tests/test_c_dir_model_stat.py links them next to the frozen stat / select oracles)
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global DirModel_get_entry
.global mark_link_dir

# ==============================================================================
# FileEntry *DirModel_get_entry(DirModel *this, ssize_t idx)
# Maps visible index through order[] indirection to 32-byte FileEntry*.
# ==============================================================================
DirModel_get_entry:
    test rsi, rsi
    js .Ldge_null
    cmp rsi, [rdi + DirModel.count]
    jae .Ldge_null
    mov rax, [rdi + DirModel.order]
    mov eax, [rax + rsi * 4]
    shl rax, 5
    add rax, [rdi + DirModel.entries]
    ret
.Ldge_null:
    xor eax, eax
    ret

# ==============================================================================
# Helper: void mark_link_dir(DirModel *model, FileEntry *entry)
# A symlink resolved to a directory: count it as a dir once and flag FE_LINK_DIR.
# ==============================================================================
mark_link_dir:
    test dword ptr [rsi + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jnz .Lmld_flag
    inc dword ptr [rdi + DirModel.dir_count]
    cmp dword ptr [rdi + DirModel.file_count], 0
    je .Lmld_flag
    dec dword ptr [rdi + DirModel.file_count]
.Lmld_flag:
    or dword ptr [rsi + FileEntry.flags], FE_LINK_DIR
    ret
