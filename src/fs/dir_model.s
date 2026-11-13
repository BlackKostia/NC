# DirModel Class: Directory Listing (PAL dir_read/statat), Filtering, Sorting, Selection
# Inherits from Object.

.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .rodata
str_DirModel:
    .asciz "DirModel"
str_dotdot:
    .asciz ".."
str_slash:
    .asciz "/"

.global DirModel_vtbl
DirModel_vtbl:
    OBJECT_VTBL_SLOTS str_DirModel, Object_vtbl, DirModel._size, DirModel_dtor

.section .text
.global DirModel_new
.global DirModel_dtor
.global DirModel_reload
.global DirModel_chdir
.global DirModel_sort
.global DirModel_get_entry
.global DirModel_toggle_select
.global DirModel_select_all_toggle
.global DirModel_count_selected
.global DirModel_find_by_name

# DirModel *DirModel_new(const char *initial_path)
DirModel_new:
    push rbx
    push r12
    mov r12, rdi              # initial_path

    NEW_OBJ DirModel_vtbl, DirModel._size
    test rax, rax
    jz .Ldmn_fail
    mov rbx, rax

    mov edi, INITIAL_FILE_CAP * FileEntry._size
    call mem_alloc
    test rax, rax
    jz .Ldmn_fail_free
    mov [rbx + DirModel.entries], rax
    mov qword ptr [rbx + DirModel.cap], INITIAL_FILE_CAP
    mov dword ptr [rbx + DirModel.show_hidden], 1
    mov dword ptr [rbx + DirModel.sort_mode], SORT_NAME
    mov dword ptr [rbx + DirModel.sort_desc], 0

    test r12, r12
    jnz .Ldmn_use_arg
    # Use current working directory
    lea rdi, [rbx + DirModel.path]
    mov esi, PATH_MAX
    OS_GETCWD
    test rax, rax
    jns .Ldmn_reload
    lea rdi, [rbx + DirModel.path]
    lea rsi, [rip + str_slash]
    mov edx, PATH_MAX
    call str_copy
    jmp .Ldmn_reload

.Ldmn_use_arg:
    lea rdi, [rbx + DirModel.path]
    mov rsi, r12
    mov edx, PATH_MAX
    call str_copy

.Ldmn_reload:
    mov rdi, rbx
    call DirModel_reload
    mov rax, rbx
    pop r12
    pop rbx
    ret

.Ldmn_fail_free:
    mov rdi, rbx
    call mem_free
.Ldmn_fail:
    xor eax, eax
    pop r12
    pop rbx
    ret

# void DirModel_dtor(DirModel *this)
DirModel_dtor:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + DirModel.entries]
    call mem_free
    mov qword ptr [rbx + DirModel.entries], 0
    pop rbx
    ret

# Internal: FileEntry *alloc_entry_slot(DirModel *this)
alloc_entry_slot:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + DirModel.count]
    cmp rax, [rbx + DirModel.cap]
    jb .Laes_ok

    mov rcx, [rbx + DirModel.cap]
    shl rcx, 1
    push rcx
    imul rsi, rcx, FileEntry._size
    mov rdi, [rbx + DirModel.entries]
    call mem_realloc
    pop rcx
    test rax, rax
    jz .Laes_fail
    mov [rbx + DirModel.entries], rax
    mov [rbx + DirModel.cap], rcx

.Laes_ok:
    mov rax, [rbx + DirModel.count]
    imul rcx, rax, FileEntry._size
    add rcx, [rbx + DirModel.entries]
    inc qword ptr [rbx + DirModel.count]
    # Zero entry slot
    push rcx
    mov rdi, rcx
    mov esi, FileEntry._size
    call mem_zero
    pop rax
    pop rbx
    ret

.Laes_fail:
    xor eax, eax
    pop rbx
    ret

# int DirModel_reload(DirModel *this)
# Returns 0 on success, or -errno on error.
DirModel_reload:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64               # [rsp+0..39]=FileStat, [rsp+48]=dir_cursor
    mov rbx, rdi              # this

    # Open directory
    mov edi, AT_FDCWD
    lea rsi, [rbx + DirModel.path]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d
    OS_OPENAT
    test rax, rax
    js .Ldmr_err
    mov r12d, eax             # dirfd

    # Allocate temporary dents buffer
    mov edi, DIRENTS_BUF_SIZE
    call mem_alloc
    test rax, rax
    jz .Ldmr_close_err
    mov r13, rax              # dents_buf

    # Reset model counts
    mov qword ptr [rbx + DirModel.count], 0
    mov qword ptr [rbx + DirModel.total_bytes], 0
    mov dword ptr [rbx + DirModel.dir_count], 0
    mov dword ptr [rbx + DirModel.file_count], 0

    # Add synthetic ".." if path != "/"
    cmp byte ptr [rbx + DirModel.path], '/'
    jne .Ldmr_add_parent
    cmp byte ptr [rbx + DirModel.path + 1], 0
    je .Ldmr_read_dents
.Ldmr_add_parent:
    mov rdi, rbx
    call alloc_entry_slot
    test rax, rax
    jz .Ldmr_dents_loop_done
    mov r14, rax
    mov dword ptr [r14 + FileEntry.flags], FE_IS_DIR | FE_IS_PARENT
    mov dword ptr [r14 + FileEntry.mode], S_IFDIR | 0755
    lea rdi, [r14 + FileEntry.name]
    lea rsi, [rip + str_dotdot]
    mov edx, NAME_MAX
    call str_copy
    mov [r14 + FileEntry.name_len], ax
    mov word ptr [r14 + FileEntry.disp_width], 2

.Ldmr_read_dents:
    mov edi, r12d
    mov rsi, r13
    mov edx, DIRENTS_BUF_SIZE
    call os_dir_read
    test rax, rax
    jle .Ldmr_dents_loop_done
    mov r15, rax              # bytes read
    mov qword ptr [rsp + 48], 0

.Ldmr_entry_loop:
    mov rdi, r13
    mov rsi, r15
    lea rdx, [rsp + 48]
    call os_dir_next
    test rax, rax
    jz .Ldmr_read_dents
    mov r14, rax              # d_name

    # Skip "." and ".."
    cmp byte ptr [r14], '.'
    jne .Ldmr_chk_hidden
    cmp byte ptr [r14 + 1], 0
    je .Ldmr_skip_entry
    cmp byte ptr [r14 + 1], '.'
    jne .Ldmr_chk_hidden
    cmp byte ptr [r14 + 2], 0
    je .Ldmr_skip_entry

.Ldmr_chk_hidden:
    cmp byte ptr [r14], '.'
    jne .Ldmr_chk_filter
    cmp dword ptr [rbx + DirModel.show_hidden], 0
    je .Ldmr_skip_entry

.Ldmr_chk_filter:
    cmp byte ptr [rbx + DirModel.filter], 0
    je .Ldmr_stat_entry
    mov rdi, r14
    lea rsi, [rbx + DirModel.filter]
    call str_contains_ci
    test eax, eax
    jz .Ldmr_skip_entry

.Ldmr_stat_entry:
    # os_statat(dirfd, name, &st, follow=0)
    mov edi, r12d
    mov rsi, r14
    mov rdx, rsp
    xor ecx, ecx
    call os_statat
    test rax, rax
    js .Ldmr_skip_entry

    mov rdi, rbx
    call alloc_entry_slot
    test rax, rax
    jz .Ldmr_skip_entry
    mov r8, rax               # FileEntry *

    # Populate FileEntry from FileStat at [rsp]
    mov rax, [rsp + FileStat.size]
    mov [r8 + FileEntry.size], rax
    mov rax, [rsp + FileStat.mtime]
    mov [r8 + FileEntry.mtime], rax
    mov eax, [rsp + FileStat.mode]
    mov [r8 + FileEntry.mode], eax

    xor r10d, r10d            # flags
    cmp byte ptr [r14], '.'
    jne .Ldmr_mode_type
    or r10d, FE_IS_HIDDEN

.Ldmr_mode_type:
    mov ecx, eax
    and ecx, S_IFMT
    cmp ecx, S_IFDIR
    je .Ldmr_is_dir
    cmp ecx, S_IFLNK
    je .Ldmr_is_lnk

    # Regular or other non-dir file
    inc dword ptr [rbx + DirModel.file_count]
    mov rdx, [r8 + FileEntry.size]
    add [rbx + DirModel.total_bytes], rdx
    test eax, 0111
    jz .Ldmr_save_flags
    or r10d, FE_IS_EXEC
    jmp .Ldmr_save_flags

.Ldmr_is_dir:
    or r10d, FE_IS_DIR
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldmr_save_flags

.Ldmr_is_lnk:
    or r10d, FE_IS_LINK
    # Check if symlink target is a directory (follow link)
    push r8
    push r10
    mov edi, r12d
    mov rsi, r14
    lea rdx, [rsp + 16]       # account for 2 pushes -> [rsp+16] is FileStat buf
    mov ecx, 1                # follow = 1
    call os_statat
    pop r10
    pop r8
    test rax, rax
    js .Ldmr_lnk_file_cnt
    mov eax, [rsp + FileStat.mode]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .Ldmr_lnk_file_cnt
    or r10d, FE_LINK_DIR
    inc dword ptr [rbx + DirModel.dir_count]
    jmp .Ldmr_save_flags
.Ldmr_lnk_file_cnt:
    inc dword ptr [rbx + DirModel.file_count]

.Ldmr_save_flags:
    mov [r8 + FileEntry.flags], r10d

    # Copy name, compute name_len, disp_width, ext_offset
    push r8
    lea rdi, [r8 + FileEntry.name]
    mov rsi, r14
    mov edx, NAME_MAX
    call str_copy
    pop r8
    mov [r8 + FileEntry.name_len], ax

    push r8
    lea rdi, [r8 + FileEntry.name]
    call utf8_display_width
    pop r8
    mov [r8 + FileEntry.disp_width], ax

    # Find last '.' after index 0
    mov word ptr [r8 + FileEntry.ext_offset], 0
    movzx ecx, word ptr [r8 + FileEntry.name_len]
    cmp ecx, 2
    jbe .Ldmr_skip_entry
.Ldmr_ext_scan:
    dec ecx
    jle .Ldmr_skip_entry
    cmp byte ptr [r8 + FileEntry.name + rcx], '.'
    jne .Ldmr_ext_scan
    mov [r8 + FileEntry.ext_offset], cx

.Ldmr_skip_entry:
    jmp .Ldmr_entry_loop

.Ldmr_dents_loop_done:
    mov rdi, r13
    call mem_free
    mov edi, r12d
    OS_CLOSE

    mov rdi, rbx
    call DirModel_sort

    xor eax, eax
    jmp .Ldmr_ret

.Ldmr_close_err:
    mov edi, r12d
    OS_CLOSE
    mov rax, -ENOMEM
    jmp .Ldmr_ret

.Ldmr_err:
    # rax already holds -errno
.Ldmr_ret:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# int DirModel_chdir(DirModel *this, const char *target)
# Resolves target relative to this->path (or absolute), validates it, updates this->path & reloads.
DirModel_chdir:
    push rbx
    push r12
    push r13
    sub rsp, PATH_MAX + 32
    mov rbx, rdi              # this
    mov r12, rsi              # target

    # Save current process cwd on stack (rsp)
    mov rdi, rsp
    mov esi, PATH_MAX
    OS_GETCWD
    mov r13, rax              # >= 0 if getcwd ok

    # If target is relative, chdir to current model->path first
    cmp byte ptr [r12], '/'
    je .Ldmc_go_target
    lea rdi, [rbx + DirModel.path]
    OS_CHDIR
    test rax, rax
    js .Ldmc_restore_err

.Ldmc_go_target:
    mov rdi, r12
    OS_CHDIR
    test rax, rax
    js .Ldmc_restore_err

    # Read canonical resolved cwd into DirModel.path
    lea rdi, [rbx + DirModel.path]
    mov esi, PATH_MAX
    OS_GETCWD
    test rax, rax
    js .Ldmc_restore_err

    # Restore original process cwd
    test r13, r13
    js .Ldmc_reload
    mov rdi, rsp
    OS_CHDIR

.Ldmc_reload:
    # Clear filter when changing directories
    mov byte ptr [rbx + DirModel.filter], 0
    mov rdi, rbx
    call DirModel_reload
    jmp .Ldmc_done

.Ldmc_restore_err:
    push rax
    test r13, r13
    js .Ldmc_err_pop
    lea rdi, [rsp + 8]
    OS_CHDIR
.Ldmc_err_pop:
    pop rax
.Ldmc_done:
    add rsp, PATH_MAX + 32
    pop r13
    pop r12
    pop rbx
    ret

# Internal comparator: int entry_cmp(FileEntry *a, FileEntry *b, int sort_mode, int sort_desc)
entry_cmp:
    push rbx
    push r12
    mov rbx, rdi              # a
    mov r12, rsi              # b

    # Directories always precede non-directories
    mov eax, [rbx + FileEntry.flags]
    and eax, (FE_IS_DIR | FE_LINK_DIR)
    setnz al
    mov r8d, [r12 + FileEntry.flags]
    and r8d, (FE_IS_DIR | FE_LINK_DIR)
    setnz r8b
    cmp al, r8b
    je .Lec_same_kind
    # If a is dir (al=1, r8b=0), a < b -> return -1
    mov eax, -1
    mov ecx, 1
    cmp r8b, 1
    cmove eax, ecx
    pop r12
    pop rbx
    ret

.Lec_same_kind:
    # rdx = sort_mode, rcx = sort_desc
    push rcx                  # save sort_desc
    cmp edx, SORT_SIZE
    je .Lec_by_size
    cmp edx, SORT_MTIME
    je .Lec_by_mtime
    cmp edx, SORT_EXT
    je .Lec_by_ext

.Lec_by_name:
    lea rdi, [rbx + FileEntry.name]
    lea rsi, [r12 + FileEntry.name]
    call str_casecmp
    test eax, eax
    jnz .Lec_apply_dir
    lea rdi, [rbx + FileEntry.name]
    lea rsi, [r12 + FileEntry.name]
    call str_cmp
    jmp .Lec_apply_dir

.Lec_by_size:
    mov rax, [rbx + FileEntry.size]
    cmp rax, [r12 + FileEntry.size]
    je .Lec_by_name
    mov eax, -1
    mov ecx, 1
    cmovg eax, ecx
    jmp .Lec_apply_dir

.Lec_by_mtime:
    # Newest first by default when ASC, or chronological? Smaller timestamp < larger
    mov rax, [rbx + FileEntry.mtime]
    cmp rax, [r12 + FileEntry.mtime]
    je .Lec_by_name
    mov eax, -1
    mov ecx, 1
    cmovg eax, ecx
    jmp .Lec_apply_dir

.Lec_by_ext:
    movzx eax, word ptr [rbx + FileEntry.ext_offset]
    movzx ecx, word ptr [r12 + FileEntry.ext_offset]
    test eax, eax
    jnz .Lec_ext_a_ok
    lea rdi, [rbx + FileEntry.name]
    movzx edx, word ptr [rbx + FileEntry.name_len]
    add rdi, rdx              # empty string ""
    jmp .Lec_ext_b
.Lec_ext_a_ok:
    lea rdi, [rbx + FileEntry.name + rax + 1]
.Lec_ext_b:
    test ecx, ecx
    jnz .Lec_ext_b_ok
    lea rsi, [r12 + FileEntry.name]
    movzx edx, word ptr [r12 + FileEntry.name_len]
    add rsi, rdx
    jmp .Lec_ext_cmp
.Lec_ext_b_ok:
    lea rsi, [r12 + FileEntry.name + rcx + 1]
.Lec_ext_cmp:
    call str_casecmp
    test eax, eax
    jz .Lec_by_name

.Lec_apply_dir:
    pop rcx                   # sort_desc
    test ecx, ecx
    jz .Lec_ret
    neg eax
.Lec_ret:
    pop r12
    pop rbx
    ret

# Internal: swap two FileEntry records (rdi = a, rsi = b)
swap_entries:
    cmp rdi, rsi
    je .Lse_done
    mov ecx, FileEntry._size / 8
.Lse_loop:
    mov rax, [rdi]
    mov rdx, [rsi]
    mov [rdi], rdx
    mov [rsi], rax
    add rdi, 8
    add rsi, 8
    dec ecx
    jnz .Lse_loop
.Lse_done:
    ret

# Internal: qsort_entries(DirModel *this, ssize_t lo, ssize_t hi)
qsort_entries:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FileEntry._size + 16
    mov rbx, rdi              # this
    mov r12, rsi              # lo
    mov r13, rdx              # hi

.Lqs_tail:
    cmp r12, r13
    jge .Lqs_done

    # Pivot = middle element copied to stack buffer [rsp]
    lea rax, [r12 + r13]
    shr rax, 1
    imul rax, rax, FileEntry._size
    add rax, [rbx + DirModel.entries]
    mov rdi, rsp
    mov rsi, rax
    mov edx, FileEntry._size
    call mem_copy

    mov r14, r12              # i = lo
    mov r15, r13              # j = hi

.Lqs_part:
.Lqs_inc_i:
    imul rdi, r14, FileEntry._size
    add rdi, [rbx + DirModel.entries]
    mov rsi, rsp
    mov edx, [rbx + DirModel.sort_mode]
    mov ecx, [rbx + DirModel.sort_desc]
    call entry_cmp
    cmp eax, 0
    jge .Lqs_dec_j
    inc r14
    jmp .Lqs_inc_i

.Lqs_dec_j:
    imul rdi, r15, FileEntry._size
    add rdi, [rbx + DirModel.entries]
    mov rsi, rsp
    mov edx, [rbx + DirModel.sort_mode]
    mov ecx, [rbx + DirModel.sort_desc]
    call entry_cmp
    cmp eax, 0
    jle .Lqs_chk_swap
    dec r15
    jmp .Lqs_dec_j

.Lqs_chk_swap:
    cmp r14, r15
    jg .Lqs_split
    imul rdi, r14, FileEntry._size
    add rdi, [rbx + DirModel.entries]
    imul rsi, r15, FileEntry._size
    add rsi, [rbx + DirModel.entries]
    call swap_entries
    inc r14
    dec r15
    cmp r14, r15
    jle .Lqs_part

.Lqs_split:
    # Recurse on smaller partition, tail-iterate larger
    mov rax, r15
    sub rax, r12              # left size
    mov rcx, r13
    sub rcx, r14              # right size
    cmp rax, rcx
    jge .Lqs_right_smaller

    cmp r12, r15
    jge .Lqs_tail_right
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    call qsort_entries
.Lqs_tail_right:
    mov r12, r14
    jmp .Lqs_tail

.Lqs_right_smaller:
    cmp r14, r13
    jge .Lqs_tail_left
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r13
    call qsort_entries
.Lqs_tail_left:
    mov r13, r15
    jmp .Lqs_tail

.Lqs_done:
    add rsp, FileEntry._size + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void DirModel_sort(DirModel *this)
DirModel_sort:
    mov rax, [rdi + DirModel.count]
    cmp rax, 2
    jb .Ldms_done
    xor esi, esi              # lo = 0
    mov rcx, [rdi + DirModel.entries]
    test dword ptr [rcx + FileEntry.flags], FE_IS_PARENT
    jz .Ldms_go
    mov esi, 1                # keep ".." pinned at index 0
.Ldms_go:
    lea rdx, [rax - 1]        # hi = count - 1
    cmp rsi, rdx
    jge .Ldms_done
    jmp qsort_entries
.Ldms_done:
    ret

# FileEntry *DirModel_get_entry(DirModel *this, ssize_t idx)
DirModel_get_entry:
    test rsi, rsi
    js .Ldmg_null
    cmp rsi, [rdi + DirModel.count]
    jae .Ldmg_null
    imul rax, rsi, FileEntry._size
    add rax, [rdi + DirModel.entries]
    ret
.Ldmg_null:
    xor eax, eax
    ret

# void DirModel_toggle_select(DirModel *this, ssize_t idx)
DirModel_toggle_select:
    call DirModel_get_entry
    test rax, rax
    jz .Ldmt_done
    test dword ptr [rax + FileEntry.flags], FE_IS_PARENT
    jnz .Ldmt_done
    xor dword ptr [rax + FileEntry.flags], FE_SELECTED
.Ldmt_done:
    ret

# void DirModel_select_all_toggle(DirModel *this)
DirModel_select_all_toggle:
    mov rcx, [rdi + DirModel.count]
    mov rdx, [rdi + DirModel.entries]
    xor r8d, r8d              # any_selected = 0
    xor r9d, r9d              # i = 0
.Lsa_scan:
    cmp r9, rcx
    jae .Lsa_apply
    imul rax, r9, FileEntry._size
    mov r10d, [rdx + rax + FileEntry.flags]
    test r10d, FE_IS_PARENT
    jnz .Lsa_next1
    test r10d, FE_SELECTED
    jz .Lsa_next1
    mov r8d, 1
    jmp .Lsa_apply
.Lsa_next1:
    inc r9
    jmp .Lsa_scan

.Lsa_apply:
    xor r9d, r9d
.Lsa_loop:
    cmp r9, rcx
    jae .Lsa_done
    imul rax, r9, FileEntry._size
    lea r10, [rdx + rax]
    test dword ptr [r10 + FileEntry.flags], FE_IS_PARENT
    jnz .Lsa_next2
    test r8d, r8d
    jnz .Lsa_clear
    or dword ptr [r10 + FileEntry.flags], FE_SELECTED
    jmp .Lsa_next2
.Lsa_clear:
    and dword ptr [r10 + FileEntry.flags], ~FE_SELECTED
.Lsa_next2:
    inc r9
    jmp .Lsa_loop
.Lsa_done:
    ret

# size_t DirModel_count_selected(DirModel *this, int64_t *out_bytes)
DirModel_count_selected:
    mov rcx, [rdi + DirModel.count]
    mov rdx, [rdi + DirModel.entries]
    xor eax, eax              # sel_count
    xor r8d, r8d              # sel_bytes
    xor r9d, r9d              # i
.Lcs_loop:
    cmp r9, rcx
    jae .Lcs_done
    imul r10, r9, FileEntry._size
    lea r11, [rdx + r10]
    test dword ptr [r11 + FileEntry.flags], FE_SELECTED
    jz .Lcs_next
    inc rax
    add r8, [r11 + FileEntry.size]
.Lcs_next:
    inc r9
    jmp .Lcs_loop
.Lcs_done:
    test rsi, rsi
    jz .Lcs_ret
    mov [rsi], r8
.Lcs_ret:
    ret

# ssize_t DirModel_find_by_name(DirModel *this, const char *name)
DirModel_find_by_name:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # this
    mov r12, rsi              # target name
    mov r13, [rbx + DirModel.count]
    xor r14d, r14d
.Lfbn_loop:
    cmp r14, r13
    jae .Lfbn_miss
    imul rax, r14, FileEntry._size
    add rax, [rbx + DirModel.entries]
    lea rdi, [rax + FileEntry.name]
    mov rsi, r12
    call str_cmp
    test eax, eax
    jz .Lfbn_hit
    inc r14
    jmp .Lfbn_loop
.Lfbn_hit:
    mov rax, r14
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.Lfbn_miss:
    mov rax, -1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
