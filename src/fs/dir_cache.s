# LRU Directory Cache: keeps the fully loaded listings of recently left directories
#
# Leaving a directory donates its DirModel arrays (entries / order / name_pool) to a slot
# (ownership transfer, no copy). Coming back validates the snapshot with the directory's
# dev / inode / mtime (seconds + nanoseconds, captured when the listing was loaded) and, on a
# match, hands the arrays back in O(1): no getdents64, no UTF-8 scan, no sort.
# Budget: DC_SLOTS snapshots and DC_BUDGET bytes in total (LRU eviction), so a huge directory
# never pins hundreds of MiB.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .bss
.align 8
g_dc_slots: .space 8          # DCSlot[DC_SLOTS] (heap, allocated on first use)
g_dc_bytes: .space 8          # sum of DCSlot.bytes of used slots
g_dc_clock: .space 8          # LRU clock

.section .text
.global dircache_store
.global dircache_fetch
.global dircache_invalidate

# Internal: void dc_free_slot(DCSlot *slot) -- releases arrays, marks free
dc_free_slot:
    push rbx
    mov rbx, rdi
    cmp dword ptr [rbx + DCSlot.used], 0
    je .Ldfs_ret
    mov rdi, [rbx + DCSlot.entries]
    call mem_free
    mov rdi, [rbx + DCSlot.order]
    call mem_free
    mov rdi, [rbx + DCSlot.name_pool]
    call mem_free
.Ldfs_drop:
    mov rax, [rbx + DCSlot.bytes]
    sub [rip + g_dc_bytes], rax
    mov dword ptr [rbx + DCSlot.used], 0
.Ldfs_ret:
    pop rbx
    ret

# Internal: DCSlot *dc_find(const char *path) -> used slot with that path, or NULL
dc_find:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov rbx, [rip + g_dc_slots]
    test rbx, rbx
    jz .Ldf_none
    xor r13d, r13d
.Ldf_loop:
    cmp r13d, DC_SLOTS
    jae .Ldf_none
    cmp dword ptr [rbx + DCSlot.used], 0
    je .Ldf_next
    lea rdi, [rbx + DCSlot.path]
    mov rsi, r12
    call str_cmp
    test eax, eax
    jz .Ldf_hit
.Ldf_next:
    add rbx, DCSlot._size
    inc r13d
    jmp .Ldf_loop
.Ldf_hit:
    mov rax, rbx
    jmp .Ldf_ret
.Ldf_none:
    xor eax, eax
.Ldf_ret:
    pop r13
    pop r12
    pop rbx
    ret

# Internal: DCSlot *dc_victim(void) -> a free slot, else the least recently used one
dc_victim:
    mov rax, [rip + g_dc_slots]
    xor ecx, ecx
    xor edx, edx                      # best (LRU) slot
    mov r8, -1                        # best lru
.Ldv_loop:
    cmp ecx, DC_SLOTS
    jae .Ldv_done
    cmp dword ptr [rax + DCSlot.used], 0
    je .Ldv_free
    mov r9, [rax + DCSlot.lru]
    cmp r9, r8
    jae .Ldv_next
    mov r8, r9
    mov rdx, rax
.Ldv_next:
    add rax, DCSlot._size
    inc ecx
    jmp .Ldv_loop
.Ldv_free:
    ret
.Ldv_done:
    mov rax, rdx
    ret

# Internal: DCSlot *dc_lru_used(void) -> least recently used occupied slot, or NULL
dc_lru_used:
    mov rcx, [rip + g_dc_slots]
    xor eax, eax
    mov r8, -1
    xor edx, edx
.Ldlu_loop:
    cmp edx, DC_SLOTS
    jae .Ldlu_ret
    cmp dword ptr [rcx + DCSlot.used], 0
    je .Ldlu_next
    mov r9, [rcx + DCSlot.lru]
    cmp r9, r8
    jae .Ldlu_next
    mov r8, r9
    mov rax, rcx
.Ldlu_next:
    add rcx, DCSlot._size
    inc edx
    jmp .Ldlu_loop
.Ldlu_ret:
    ret

# int dircache_store(DirModel *m)
# Donates a complete listing to the cache. Returns 1 when taken (m's arrays become NULL and
# its capacities 0), or 0 when m keeps its arrays (incomplete load, unknown stamp, too big).
dircache_store:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rbx + DirModel.is_loading], 0
    jne .Lds_ret
    cmp dword ptr [rbx + DirModel.load_aborted], 0
    jne .Lds_ret
    cmp qword ptr [rbx + DirModel.dir_ino], 0
    je .Lds_ret
    cmp qword ptr [rbx + DirModel.entries], 0
    je .Lds_ret
    mov r12, [rbx + DirModel.raw_cap]
    imul r12, r12, FileEntry._size + 4
    add r12, [rbx + DirModel.name_cap]    # footprint
    cmp r12, DC_BUDGET
    ja .Lds_no

    mov rax, [rip + g_dc_slots]
    test rax, rax
    jnz .Lds_have_tbl
    mov edi, DC_SLOTS * DCSlot._size
    call mem_alloc
    test rax, rax
    jz .Lds_no
    mov [rip + g_dc_slots], rax
.Lds_have_tbl:
    # Replace an older snapshot of the same path
    lea rdi, [rbx + DirModel.path]
    call dc_find
    test rax, rax
    jz .Lds_make_room
    mov rdi, rax
    call dc_free_slot
.Lds_make_room:
    call dc_victim
    mov r13, rax
    cmp dword ptr [r13 + DCSlot.used], 0
    je .Lds_budget
    mov rdi, r13
    call dc_free_slot
.Lds_budget:
    mov rax, [rip + g_dc_bytes]
    add rax, r12
    cmp rax, DC_BUDGET
    jbe .Lds_fill
    call dc_lru_used                  # evict LRU snapshots until this one fits
    test rax, rax
    jz .Lds_no
    mov rdi, rax
    call dc_free_slot
    jmp .Lds_budget
.Lds_fill:
    mov rax, [rbx + DirModel.entries]
    mov [r13 + DCSlot.entries], rax
    mov rax, [rbx + DirModel.order]
    mov [r13 + DCSlot.order], rax
    mov rax, [rbx + DirModel.name_pool]
    mov [r13 + DCSlot.name_pool], rax
    mov rax, [rbx + DirModel.raw_count]
    mov [r13 + DCSlot.raw_count], rax
    mov rax, [rbx + DirModel.raw_cap]
    mov [r13 + DCSlot.raw_cap], rax
    mov rax, [rbx + DirModel.name_used]
    mov [r13 + DCSlot.name_used], rax
    mov rax, [rbx + DirModel.name_cap]
    mov [r13 + DCSlot.name_cap], rax
    mov rax, [rbx + DirModel.count]
    mov [r13 + DCSlot.count], rax
    mov rax, [rbx + DirModel.dir_dev]
    mov [r13 + DCSlot.dev], rax
    mov rax, [rbx + DirModel.dir_ino]
    mov [r13 + DCSlot.ino], rax
    mov rax, [rbx + DirModel.dir_mtime]
    mov [r13 + DCSlot.mtime], rax
    mov eax, [rbx + DirModel.dir_mtime_ns]
    mov [r13 + DCSlot.mtime_ns], eax
    mov eax, [rbx + DirModel.dir_count]
    mov [r13 + DCSlot.dir_count], eax
    mov eax, [rbx + DirModel.file_count]
    mov [r13 + DCSlot.file_count], eax
    mov eax, [rbx + DirModel.has_dotdot]
    mov [r13 + DCSlot.has_dotdot], eax
    mov eax, [rbx + DirModel.sort_mode]
    mov [r13 + DCSlot.sort_mode], eax
    mov eax, [rbx + DirModel.sort_desc]
    mov [r13 + DCSlot.sort_desc], eax
    mov eax, [rbx + DirModel.show_hidden]
    mov [r13 + DCSlot.show_hidden], eax
    mov eax, [rbx + DirModel.is_unsorted]
    mov [r13 + DCSlot.is_unsorted], eax
    mov eax, [rbx + DirModel.huge_mode]
    mov [r13 + DCSlot.huge_mode], eax
    lea rdi, [r13 + DCSlot.filter]
    lea rsi, [rbx + DirModel.filter]
    mov edx, FILTER_MAX
    call str_copy
    lea rdi, [r13 + DCSlot.path]
    lea rsi, [rbx + DirModel.path]
    mov edx, PATH_MAX
    call str_copy
    mov [r13 + DCSlot.bytes], r12
    add [rip + g_dc_bytes], r12
    inc qword ptr [rip + g_dc_clock]
    mov rax, [rip + g_dc_clock]
    mov [r13 + DCSlot.lru], rax
    mov dword ptr [r13 + DCSlot.used], 1

    xor eax, eax
    mov [rbx + DirModel.entries], rax
    mov [rbx + DirModel.order], rax
    mov [rbx + DirModel.name_pool], rax
    mov [rbx + DirModel.raw_cap], rax
    mov [rbx + DirModel.name_cap], rax
    mov [rbx + DirModel.raw_count], rax
    mov [rbx + DirModel.count], rax
    mov [rbx + DirModel.name_used], rax
    mov eax, 1
    jmp .Lds_ret
.Lds_no:
    xor eax, eax
.Lds_ret:
    pop r13
    pop r12
    pop rbx
    ret

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

    # Reusable as-is only with an empty snapshot filter and identical view settings
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
