# Frozen reference oracle: the hand-written asm that src/fs/dir_search*.c replaced (tests/test_c_dir_search.py diffs against it)
# src/fs/dir_search.s - Recursive directory search into DirModel virtual panel — dir search reset (split from dir_search.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ SEARCH_MAX_DEPTH, 16
.equ SEARCH_MAX_HITS,  4096
.equ SEARCH_DENTS_SZ,  16384
.equ SEARCH_GREP_SZ,   32768
.struct 0
SearchCtx.model:     .space 8
SearchCtx.name_mask: .space 8
SearchCtx.grep_pat:  .space 8
SearchCtx.grep_len:  .space 8
SearchCtx.grep_buf:  .space 8
SearchCtx.hits:      .space 4
SearchCtx.has_glob:  .space 4
SearchCtx._size:

.extern DirModel_cancel_load
.extern ds_match_mask
.extern ds_grep_file
.extern mem_alloc
.extern mem_realloc
.extern mem_free
.extern str_len
.extern str_copy
.extern utf8_display_width
.extern os_statat
.extern os_dir_read
.extern os_dir_next_ex

.section .text
.global ds_reset_model

# void ds_reset_model(DirModel *m, const char *root_path)
ds_reset_model:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call DirModel_cancel_load
    mov dword ptr [rbx + DirModel.flt_valid], 0
    mov dword ptr [rbx + DirModel.is_loading], 0
    mov dword ptr [rbx + DirModel.load_aborted], 0
    mov dword ptr [rbx + DirModel.huge_mode], 0
    mov dword ptr [rbx + DirModel.is_unsorted], 0
    mov dword ptr [rbx + DirModel.stats_complete], 1
    mov dword ptr [rbx + DirModel.virtual_mode], 1
    mov qword ptr [rbx + DirModel.count], 0
    mov qword ptr [rbx + DirModel.raw_count], 0
    mov qword ptr [rbx + DirModel.name_used], 0
    mov qword ptr [rbx + DirModel.total_bytes], 0
    mov dword ptr [rbx + DirModel.dir_count], 0
    mov dword ptr [rbx + DirModel.file_count], 0
    mov dword ptr [rbx + DirModel.has_dotdot], 0

    cmp byte ptr [r12], '/'
    jne .Ldrm_dotdot
    cmp byte ptr [r12 + 1], 0
    je .Ldrm_done
.Ldrm_dotdot:
    mov rdi, rbx
    mov esi, 3
    call ds_ensure_model_cap
    test eax, eax
    js .Ldrm_done
    mov rdx, [rbx + DirModel.name_pool]
    mov byte ptr [rdx + 0], '.'
    mov byte ptr [rdx + 1], '.'
    mov byte ptr [rdx + 2], 0
    mov qword ptr [rbx + DirModel.name_used], 3
    mov rax, [rbx + DirModel.entries]
    mov qword ptr [rax + FileEntry.size], 0
    mov qword ptr [rax + FileEntry.mtime], 0
    mov dword ptr [rax + FileEntry.mode], S_IFDIR | 0755
    mov dword ptr [rax + FileEntry.flags], FE_IS_DIR | FE_IS_PARENT | FE_STAT_READY
    mov dword ptr [rax + FileEntry.name_off], 0
    mov word ptr [rax + FileEntry.name_len], 2
    mov byte ptr [rax + FileEntry.disp_width], 2
    mov byte ptr [rax + FileEntry.ext_offset], 0
    mov rcx, [rbx + DirModel.order]
    mov dword ptr [rcx], 0
    mov qword ptr [rbx + DirModel.raw_count], 1
    mov qword ptr [rbx + DirModel.count], 1
    mov dword ptr [rbx + DirModel.has_dotdot], 1
.Ldrm_done:
    add rsp, 8
    pop r12
    pop rbx
    ret
