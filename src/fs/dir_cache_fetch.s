# LRU Directory Cache: keeps the fully loaded listings of recently left directories — dir cache fetch (split from dir_cache.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global dircache_fetch
.global dircache_invalidate

# int dircache_fetch(DirModel *m, const FileStat *dir_st)
# Looks up m->path. On a valid snapshot (same dev/ino/mtime/mtime_nsec) installs it into m
# (freeing m's current arrays) and returns 1 when order[] is directly reusable, or 2 when the
# caller must re-filter/re-sort (hidden/filter/sort mode differ). Returns 0 on miss; a stale
# snapshot is dropped.
dircache_fetch:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rbx + DirModel.path]
    call dc_find
    test rax, rax
    jz .Ldcf_miss
    mov r13, rax
    mov rax, [r12 + FileStat.dev]
    cmp rax, [r13 + DCSlot.dev]
    jne .Ldcf_stale
    mov rax, [r12 + FileStat.ino]
    cmp rax, [r13 + DCSlot.ino]
    jne .Ldcf_stale
    mov rax, [r12 + FileStat.mtime]
    cmp rax, [r13 + DCSlot.mtime]
    jne .Ldcf_stale
    mov eax, [r12 + FileStat.mtime_nsec]
    cmp eax, [r13 + DCSlot.mtime_ns]
    jne .Ldcf_stale

    call dircache_fetch__part1
    # Reusable as-is only with an empty snapshot filter and identical view settings
    call dircache_fetch__reusable_as_only_empty
    mov rax, [r13 + DCSlot.bytes]
    sub [rip + g_dc_bytes], rax
    mov dword ptr [r13 + DCSlot.used], 0   # arrays now owned by m
    mov eax, r12d
    jmp .Ldcf_ret
.Ldcf_stale:
    mov rdi, r13
    call dc_free_slot
.Ldcf_miss:
    xor eax, eax
.Ldcf_ret:
    pop r13
    pop r12
    pop rbx
    ret

# dircache_fetch step (runs on the caller's frame)
dircache_fetch__part1:
    lea rsp, [rsp - 8]
    mov rdi, [rbx + DirModel.entries]
    call mem_free
    mov rdi, [rbx + DirModel.order]
    call mem_free
    mov rdi, [rbx + DirModel.name_pool]
    call mem_free
    mov rax, [r13 + DCSlot.entries]
    mov [rbx + DirModel.entries], rax
    mov rax, [r13 + DCSlot.order]
    mov [rbx + DirModel.order], rax
    mov rax, [r13 + DCSlot.name_pool]
    mov [rbx + DirModel.name_pool], rax
    mov rax, [r13 + DCSlot.raw_count]
    mov [rbx + DirModel.raw_count], rax
    mov rax, [r13 + DCSlot.raw_cap]
    mov [rbx + DirModel.raw_cap], rax
    mov rax, [r13 + DCSlot.name_used]
    mov [rbx + DirModel.name_used], rax
    mov rax, [r13 + DCSlot.name_cap]
    mov [rbx + DirModel.name_cap], rax
    mov rax, [r13 + DCSlot.count]
    mov [rbx + DirModel.count], rax
    mov rax, [r13 + DCSlot.dev]
    mov [rbx + DirModel.dir_dev], rax
    mov rax, [r13 + DCSlot.ino]
    mov [rbx + DirModel.dir_ino], rax
    mov rax, [r13 + DCSlot.mtime]
    mov [rbx + DirModel.dir_mtime], rax
    mov eax, [r13 + DCSlot.mtime_ns]
    mov [rbx + DirModel.dir_mtime_ns], eax
    mov eax, [r13 + DCSlot.dir_count]
    mov [rbx + DirModel.dir_count], eax
    mov eax, [r13 + DCSlot.file_count]
    mov [rbx + DirModel.file_count], eax
    mov eax, [r13 + DCSlot.has_dotdot]
    mov [rbx + DirModel.has_dotdot], eax
    mov eax, [r13 + DCSlot.is_unsorted]
    mov [rbx + DirModel.is_unsorted], eax
    mov eax, [r13 + DCSlot.huge_mode]
    mov [rbx + DirModel.huge_mode], eax

.Ldircache_fetch__part1_ret:
    lea rsp, [rsp + 8]
    ret

# dircache_fetch step: Reusable as is only with an empty snapshot filter and identical view settings (runs on the caller's frame)
dircache_fetch__reusable_as_only_empty:
    lea rsp, [rsp - 8]
    mov r12d, 1
    cmp byte ptr [r13 + DCSlot.filter], 0
    jne .Ldcf_refilter
    mov eax, [r13 + DCSlot.show_hidden]
    cmp eax, [rbx + DirModel.show_hidden]
    jne .Ldcf_refilter
    mov eax, [r13 + DCSlot.sort_mode]
    cmp eax, [rbx + DirModel.sort_mode]
    jne .Ldcf_refilter
    mov eax, [r13 + DCSlot.sort_desc]
    cmp eax, [rbx + DirModel.sort_desc]
    je .Ldcf_release
.Ldcf_refilter:
    mov r12d, 2
.Ldcf_release:
.Ldircache_fetch__reusable_as_only_empty_ret:
    lea rsp, [rsp + 8]
    ret

# void dircache_invalidate(const char *path) -- drop a snapshot (e.g. on inotify events)
dircache_invalidate:
    sub rsp, 8
    call dc_find
    test rax, rax
    jz .Ldci_ret
    mov rdi, rax
    call dc_free_slot
.Ldci_ret:
    add rsp, 8
    ret
