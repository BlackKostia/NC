# src/fs/dir_model.s - Compact 32B DirModel, zero-stat d_type scan, streaming & lazy stat — dir model stream (split from dir_model.s)

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
.global DirModel_step_load
.global DirModel_cancel_load

# ==============================================================================
# int DirModel_step_load(DirModel *this, size_t max_entries)
# Reads and appends up to max_entries (or g_stream_batch if 0) using d_type only.
# Returns 1 if more entries may follow, 0 on EOF/done, or -errno on read error.
# ==============================================================================
DirModel_step_load:
    cmp dword ptr [rdi + DirModel.is_loading], 0
    jne .Ldsl_active
    xor eax, eax
    ret
.Ldsl_active:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40               # align: 6 pushes=48 + 40 + 8 = 96 = 0 mod 16
    # Stack frame:
    # [rsp + 0]  = budget
    # [rsp + 8]  = added
    # [rsp + 16] = d_name ptr
    # [rsp + 24] = name_len (qword)
    # [rsp + 32] = ext_off (byte), d_type (byte at +33), disp_w (byte at +34)
    mov rbx, rdi
    mov dword ptr [rbx + DirModel.flt_valid], 0
    push rsi
    sub rsp, 8
    call prepare_filter
    add rsp, 8
    pop rsi
    test rsi, rsi
    jnz .Ldsl_got_budget
    mov rsi, [rip + g_stream_batch]
    test rsi, rsi
    jnz .Ldsl_got_budget
    mov rsi, STREAM_BATCH_BUDGET
.Ldsl_got_budget:
    mov [rsp + 0], rsi
    mov qword ptr [rsp + 8], 0

.Ldsl_loop:
    mov rax, [rsp + 8]
    cmp rax, [rsp + 0]
    jae .Ldsl_more

    # Refill 1 MiB getdents64 buffer when exhausted
    mov rax, [rbx + DirModel.load_pos]
    cmp rax, [rbx + DirModel.load_bytes]
    jb .Ldsl_next_dentry

    mov edi, [rbx + DirModel.load_dirfd]
    mov rsi, [rbx + DirModel.load_buf]
    mov edx, DIRENTS_BUF_SIZE
    call os_dir_read
    test rax, rax
    js .Ldsl_read_err
    jz .Ldsl_eof
    mov [rbx + DirModel.load_bytes], rax
    mov qword ptr [rbx + DirModel.load_pos], 0

.Ldsl_next_dentry:
    mov rdi, [rbx + DirModel.load_buf]
    mov rsi, [rbx + DirModel.load_bytes]
    lea rdx, [rbx + DirModel.load_pos]
    lea rcx, [rsp + 33]       # &d_type (byte)
    call os_dir_next_ex
    test rax, rax
    jz .Ldsl_loop
    mov r12, rax              # d_name

    # Skip "." and ".."
    cmp byte ptr [r12], '.'
    jne .Ldsl_scan_name
    cmp byte ptr [r12 + 1], 0
    je .Ldsl_loop
    cmp byte ptr [r12 + 1], '.'
    jne .Ldsl_scan_name
    cmp byte ptr [r12 + 2], 0
    je .Ldsl_loop

.Ldsl_scan_name:
    # Inline scan: compute name_len, last_dot, ASCII vs UTF-8
    xor ecx, ecx              # len = 0
    xor edx, edx              # last_dot = 0
    xor r8d, r8d              # high_bit_or = 0
.Ldsl_scan_loop:
    movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz .Ldsl_scan_done
    or r8d, eax
    cmp eax, '.'
    jne .Ldsl_scan_next
    test rcx, rcx
    jz .Ldsl_scan_next
    mov edx, ecx
.Ldsl_scan_next:
    inc rcx
    jmp .Ldsl_scan_loop

.Ldsl_scan_done:
    mov [rsp + 16], r12
    mov [rsp + 24], rcx       # name_len
    cmp edx, 255
    jbe .Ldsl_ext_ok
    xor edx, edx
.Ldsl_ext_ok:
    mov [rsp + 32], dl        # ext_offset

    # ASCII fast-path display width vs utf8_display_width
    test r8d, 0x80
    jz .Ldsl_ascii_w
    mov rdi, r12
    call utf8_display_width
    cmp rax, 255
    jbe .Ldsl_w_ok
    mov eax, 255
    jmp .Ldsl_w_ok
.Ldsl_ascii_w:
    mov rax, [rsp + 24]
    cmp rax, 255
    jbe .Ldsl_w_ok
    mov eax, 255
.Ldsl_w_ok:
    mov [rsp + 34], al        # disp_width

    # Ensure array + name_pool capacity for name_len + 1
    mov rdi, rbx
    mov rsi, [rsp + 24]
    inc rsi
    call ensure_capacity
    test eax, eax
    js .Ldsl_read_err

    # Copy name_len + 1 bytes into name_pool + name_used
    mov r13, [rbx + DirModel.name_used]       # name_off
    mov rdi, [rbx + DirModel.name_pool]
    add rdi, r13
    mov rsi, [rsp + 16]
    mov rcx, [rsp + 24]
    inc rcx
    rep movsb
    mov rax, [rsp + 24]
    lea r14, [r13 + rax + 1]
    mov [rbx + DirModel.name_used], r14

    # Derive zero-stat flags & fallback mode purely from d_type
    xor r10d, r10d
    mov r12, [rsp + 16]
    cmp byte ptr [r12], '.'
    jne .Ldsl_dt
    or r10d, FE_IS_HIDDEN
.Ldsl_dt:
    movzx eax, byte ptr [rsp + 33]
    cmp eax, PAL_DT_DIR
    je .Ldsl_dt_dir
    cmp eax, PAL_DT_LNK
    je .Ldsl_dt_lnk
    cmp eax, PAL_DT_UNKNOWN
    je .Ldsl_dt_unk
    mov r11d, S_IFREG | 0644
    jmp .Ldsl_fill_fe
.Ldsl_dt_dir:
    or r10d, FE_IS_DIR
    mov r11d, S_IFDIR | 0755
    jmp .Ldsl_fill_fe
.Ldsl_dt_lnk:
    or r10d, FE_IS_LINK
    mov r11d, S_IFLNK | 0777
    jmp .Ldsl_fill_fe
.Ldsl_dt_unk:
    or r10d, FE_DT_UNKNOWN
    xor r11d, r11d

.Ldsl_fill_fe:
    mov r14, [rbx + DirModel.raw_count]
    mov r15, r14
    shl r15, 5
    add r15, [rbx + DirModel.entries]
    mov qword ptr [r15 + FileEntry.size], 0
    mov qword ptr [r15 + FileEntry.mtime], 0
    mov [r15 + FileEntry.mode], r11d
    mov [r15 + FileEntry.flags], r10d
    mov [r15 + FileEntry.name_off], r13d
    mov ax, [rsp + 24]
    mov [r15 + FileEntry.name_len], ax
    mov al, [rsp + 34]
    mov [r15 + FileEntry.disp_width], al
    mov al, [rsp + 32]
    mov [r15 + FileEntry.ext_offset], al

    inc qword ptr [rbx + DirModel.raw_count]
    inc qword ptr [rsp + 8]

    # Trigger ls -f huge mode once raw_count reaches g_huge_threshold
    mov rax, [rip + g_huge_threshold]
    test rax, rax
    jnz .Ldsl_chk_huge
    mov eax, HUGE_DIR_THRESHOLD
.Ldsl_chk_huge:
    cmp [rbx + DirModel.raw_count], rax
    jb .Ldsl_chk_vis
    mov dword ptr [rbx + DirModel.huge_mode], 1
    mov dword ptr [rbx + DirModel.is_unsorted], 1

.Ldsl_chk_vis:
    # Filter incrementally so Frame 1 shows matched rows immediately
    mov rdi, rbx
    mov edx, [r15 + FileEntry.flags]
    mov rcx, [rbx + DirModel.name_pool]
    add rcx, r13
    call entry_passes_filter
    test eax, eax
    jz .Ldsl_loop

    mov rdi, [rbx + DirModel.order]
    mov rax, [rbx + DirModel.count]
    mov [rdi + rax * 4], r14d
    inc rax
    mov [rbx + DirModel.count], rax

    test dword ptr [r15 + FileEntry.flags], FE_IS_DIR | FE_LINK_DIR
    jz .Ldsl_inc_file
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldsl_loop
.Ldsl_inc_file:
    inc dword ptr [rbx + DirModel.file_count]
    jmp .Ldsl_loop

.Ldsl_eof:
    mov rdi, rbx
    xor esi, esi
    call finish_load_internal
    xor eax, eax
    jmp .Ldsl_exit

.Ldsl_read_err:
    push rax
    mov rdi, rbx
    xor esi, esi
    call finish_load_internal
    pop rax
    jmp .Ldsl_exit

.Ldsl_more:
    mov eax, 1

.Ldsl_exit:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

# ==============================================================================
# void DirModel_cancel_load(DirModel *this)
# Cancels active directory streaming (Esc), preserving already loaded entries.
# ==============================================================================
DirModel_cancel_load:
    cmp dword ptr [rdi + DirModel.is_loading], 0
    je .Ldcl_ret
    mov esi, 1
    jmp finish_load_internal
.Ldcl_ret:
    ret
