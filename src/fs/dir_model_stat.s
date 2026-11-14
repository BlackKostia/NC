# src/fs/dir_model.s - Compact 32B DirModel, zero-stat d_type scan, streaming & lazy stat — dir model stat (split from dir_model.s)

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"
.equ BATCH_STAT_CHUNK, 1024
.equ CHUNK_ENTRIES_OFF, 0
.equ CHUNK_NAMES_OFF,   (BATCH_STAT_CHUNK * 8)
.equ CHUNK_STATS_OFF,   (CHUNK_NAMES_OFF + BATCH_STAT_CHUNK * 8)
.equ CHUNK_ERRS_OFF,    (CHUNK_STATS_OFF + BATCH_STAT_CHUNK * FileStat._size)
.equ CHUNK_BUF_SIZE,    (CHUNK_ERRS_OFF + BATCH_STAT_CHUNK * 4)
.extern DirModel_sort
.extern Object_dtor
.extern mem_alloc
.extern mem_realloc
.extern mem_free
.extern str_copy
.extern str_cmp
.extern str_contains_ci
.extern str_starts_with
.extern utf8_display_width
.extern os_statat
.extern os_batch_stat
.extern os_dir_read
.extern os_dir_next_ex

.section .text
.global apply_stat_to_entry
.global DirModel_ensure_entry_stat
.global DirModel_stat_range

# ==============================================================================
# Helper: void apply_stat_to_entry(DirModel *model, FileEntry *entry,
#                                  const FileStat *st, int dirfd)
# Populates size/mtime/mode/flags cleanly and marks FE_STAT_READY.
# ==============================================================================
apply_stat_to_entry:
    push rbx
    push r12
    push r13
    sub rsp, FileStat._size + 8   # aligned stack + tmp FileStat
    mov rbx, rdi              # model
    mov r12, rsi              # entry
    mov r13, rdx              # st
    mov [rsp + FileStat._size], ecx  # dirfd

    mov r8d, [r12 + FileEntry.flags]
    test r8d, FE_STAT_READY
    jnz .Lase_done

    mov rax, [r13 + FileStat.size]
    mov [r12 + FileEntry.size], rax
    mov rax, [r13 + FileStat.mtime]
    mov [r12 + FileEntry.mtime], rax
    mov eax, [r13 + FileStat.mode]
    mov [r12 + FileEntry.mode], eax

    and r8d, ~(FE_DT_UNKNOWN | FE_IS_EXEC)
    mov r9d, eax
    and r9d, S_IFMT
    cmp r9d, S_IFDIR
    je .Lase_dir
    cmp r9d, S_IFLNK
    je .Lase_lnk

    # Regular or special non-dir file
    test eax, 0111
    jz .Lase_non_dir_cnt
    or r8d, FE_IS_EXEC
.Lase_non_dir_cnt:
    mov rax, [r13 + FileStat.size]
    add [rbx + DirModel.total_bytes], rax
    jmp .Lase_commit

.Lase_dir:
    test dword ptr [r12 + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jnz .Lase_commit
    or r8d, FE_IS_DIR
    inc dword ptr [rbx + DirModel.dir_count]
    cmp dword ptr [rbx + DirModel.file_count], 0
    je .Lase_commit
    dec dword ptr [rbx + DirModel.file_count]
    jmp .Lase_commit

.Lase_lnk:
    or r8d, FE_IS_LINK | FE_STAT_READY
    mov [r12 + FileEntry.flags], r8d
    cmp dword ptr [rsp + FileStat._size], -2
    je .Lase_done                     # batch caller resolves link targets via io_uring
    mov edi, [rsp + FileStat._size]
    mov esi, [r12 + FileEntry.name_off]
    add rsi, [rbx + DirModel.name_pool]
    mov rdx, rsp
    mov ecx, 1                # follow symlink to check FE_LINK_DIR
    call os_statat
    test rax, rax
    js .Lase_done
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Lase_done
    mov rdi, rbx
    mov rsi, r12
    call mark_link_dir
    jmp .Lase_done

.Lase_commit:
    or r8d, FE_STAT_READY
    mov [r12 + FileEntry.flags], r8d

.Lase_done:
    add rsp, FileStat._size + 8
    pop r13
    pop r12
    pop rbx
    ret

# ==============================================================================
# void DirModel_ensure_entry_stat(DirModel *this, FileEntry *entry)
# Lazy-stats a single FileEntry if FE_STAT_READY is not yet set.
# ==============================================================================
DirModel_ensure_entry_stat:
    test rdi, rdi
    jz .Lees_ret
    test rsi, rsi
    jz .Lees_ret
    test dword ptr [rsi + FileEntry.flags], FE_STAT_READY
    jnz .Lees_ret

    push rbx
    push r12
    push r13
    sub rsp, FileStat._size + 8
    mov rbx, rdi
    mov r12, rsi

    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Lees_mark_err
    mov r13d, eax

    mov edi, r13d
    mov esi, [r12 + FileEntry.name_off]
    add rsi, [rbx + DirModel.name_pool]
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Lees_close_err
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rsp
    mov ecx, r13d
    call apply_stat_to_entry
    jmp .Lees_close

.Lees_close_err:
    or dword ptr [r12 + FileEntry.flags], FE_STAT_READY
.Lees_close:
    mov edi, r13d
    OS_CLOSE
    jmp .Lees_done

.Lees_mark_err:
    or dword ptr [r12 + FileEntry.flags], FE_STAT_READY
.Lees_done:
    add rsp, FileStat._size + 8
    pop r13
    pop r12
    pop rbx
.Lees_ret:
    ret

# ==============================================================================
# void DirModel_stat_range(DirModel *this, size_t view_start, size_t view_len)
# Lazy-stats only visible viewport rows in FilePane_render lacking FE_STAT_READY.
# ==============================================================================
DirModel_stat_range:
    cmp qword ptr [rdi + DirModel.count], 0
    je .Ldsr_ret
    test rdx, rdx
    jz .Ldsr_ret

    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileStat._size + 16
    call DirModel_stat_range__idx
    jae .Ldsr_done

    # Quick check if any entry in [r12 .. r13) actually needs stat
    mov rax, [rbx + DirModel.order]
    mov rcx, [rbx + DirModel.entries]
    mov r8, r12
.Ldsr_scan_need:
    cmp r8, r13
    jae .Ldsr_done            # all visible rows already cached!
    mov edx, [rax + r8 * 4]
    shl rdx, 5
    test dword ptr [rcx + rdx + FileEntry.flags], FE_STAT_READY
    jz .Ldsr_open_dir
    inc r8
    jmp .Ldsr_scan_need

.Ldsr_open_dir:
    # Reuse open load_dirfd while streaming, otherwise open path once
    call DirModel_stat_range__reuse_open_load_dirfd
.Ldsr_done:
    add rsp, FileStat._size + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
.Ldsr_ret:
    ret

# DirModel_stat_range step: idx (runs on the caller's frame)
DirModel_stat_range__idx:
    lea rsp, [rsp - 8]
    mov rbx, rdi
    mov r12, rsi              # idx = view_start
    lea r13, [rsi + rdx]      # end = view_start + view_len
    mov rax, [rbx + DirModel.count]
    cmp r13, rax
    cmova r13, rax
    cmp r12, r13
.LDirModel_stat_range__idx_ret:
    lea rsp, [rsp + 8]
    ret

# DirModel_stat_range step: Reuse open load_dirfd while streaming otherwise open path once (runs on the caller's frame)
DirModel_stat_range__reuse_open_load_dirfd:
    lea rsp, [rsp - 8]
    xor r15d, r15d            # own_fd = 0
    mov r14d, [rbx + DirModel.load_dirfd]
    test r14d, r14d
    jns .Ldsr_loop
    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .LDirModel_stat_range__reuse_open_load_dirfd_ret
    mov r14d, eax
    mov r15d, 1               # own_fd = 1

.Ldsr_loop:
    cmp r12, r13
    jae .Ldsr_close_if_own
    mov rax, [rbx + DirModel.order]
    mov eax, [rax + r12 * 4]
    shl rax, 5
    add rax, [rbx + DirModel.entries]
    mov rbp, rax
    test dword ptr [rbp + FileEntry.flags], FE_STAT_READY
    jnz .Ldsr_next

    mov edi, r14d
    mov esi, [rbp + FileEntry.name_off]
    add rsi, [rbx + DirModel.name_pool]
    lea rdx, [rsp + 16]
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Ldsr_stat_fail
    mov rdi, rbx
    mov rsi, rbp
    lea rdx, [rsp + 16]
    mov ecx, r14d
    call apply_stat_to_entry
    jmp .Ldsr_next

.Ldsr_stat_fail:
    or dword ptr [rbp + FileEntry.flags], FE_STAT_READY

.Ldsr_next:
    inc r12
    jmp .Ldsr_loop

.Ldsr_close_if_own:
    test r15d, r15d
    jz .LDirModel_stat_range__reuse_open_load_dirfd_ret
    mov edi, r14d
    OS_CLOSE

.LDirModel_stat_range__reuse_open_load_dirfd_ret:
    lea rsp, [rsp + 8]
    ret
