# Core String, Formatting, and Path Utilities

.intel_syntax noprefix
.include "linux_sys.inc"

.section .rodata
hex_digits:
    .ascii "0123456789abcdef"
size_units:
    .ascii "BKMGTPE"

.section .text
.global str_len
.global str_copy
.global str_cat
.global str_cmp
.global str_casecmp
.global str_contains_ci
.global str_chr
.global str_rchr
.global str_starts_with
.global u64_to_dec
.global u64_to_hex
.global format_size
.global format_perms
.global format_datetime
.global path_join
.global path_dirname
.global path_basename

# size_t str_len(const char *s)
str_len:
    xor eax, eax
    test rdi, rdi
    jz .Lsl_done
.Lsl_loop:
    cmp byte ptr [rdi + rax], 0
    je .Lsl_done
    inc rax
    jmp .Lsl_loop
.Lsl_done:
    ret

# size_t str_copy(char *dst, const char *src, size_t cap)
# Safely copies src into dst (NUL-terminated if cap > 0). Returns chars written.
str_copy:
    xor eax, eax
    test rdx, rdx
    jz .Lsc_done
    test rsi, rsi
    jz .Lsc_null
    dec rdx                   # reserve 1 byte for NUL
.Lsc_loop:
    cmp rax, rdx
    jae .Lsc_null
    mov cl, byte ptr [rsi + rax]
    test cl, cl
    jz .Lsc_null
    mov byte ptr [rdi + rax], cl
    inc rax
    jmp .Lsc_loop
.Lsc_null:
    mov byte ptr [rdi + rax], 0
.Lsc_done:
    ret

# size_t str_cat(char *dst, const char *src, size_t cap)
str_cat:
    push rbx
    push r12
    push r13
    mov rbx, rdi              # dst
    mov r12, rsi              # src
    mov r13, rdx              # cap
    call str_len
    cmp rax, r13
    jae .Lscat_done
    lea rdi, [rbx + rax]
    mov rsi, r12
    mov rdx, r13
    sub rdx, rax
    push rax
    call str_copy
    pop rcx
    add rax, rcx
.Lscat_done:
    pop r13
    pop r12
    pop rbx
    ret

# int str_cmp(const char *a, const char *b)
str_cmp:
.Lscmp_loop:
    movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp eax, ecx
    jne .Lscmp_diff
    test eax, eax
    jz .Lscmp_eq
    inc rdi
    inc rsi
    jmp .Lscmp_loop
.Lscmp_diff:
    sub eax, ecx
    ret
.Lscmp_eq:
    xor eax, eax
    ret

# int str_casecmp(const char *a, const char *b)
str_casecmp:
.Lscc_loop:
    movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp eax, 'A'
    jb .Lscc_a_ok
    cmp eax, 'Z'
    ja .Lscc_a_ok
    add eax, 32
.Lscc_a_ok:
    cmp ecx, 'A'
    jb .Lscc_c_ok
    cmp ecx, 'Z'
    ja .Lscc_c_ok
    add ecx, 32
.Lscc_c_ok:
    cmp eax, ecx
    jne .Lscc_diff
    test eax, eax
    jz .Lscc_eq
    inc rdi
    inc rsi
    jmp .Lscc_loop
.Lscc_diff:
    sub eax, ecx
    ret
.Lscc_eq:
    xor eax, eax
    ret

# int str_contains_ci(const char *haystack, const char *needle)
# Returns 1 if needle occurs in haystack (case-insensitive ASCII), else 0
str_contains_ci:
    cmp byte ptr [rsi], 0
    je .Lsci_found
.Lsci_outer:
    cmp byte ptr [rdi], 0
    je .Lsci_not_found
    mov r8, rdi
    mov r9, rsi
.Lsci_inner:
    movzx ecx, byte ptr [r9]
    test ecx, ecx
    jz .Lsci_found
    movzx eax, byte ptr [r8]
    test eax, eax
    jz .Lsci_not_found
    cmp eax, 'A'
    jb .Lsci_a1
    cmp eax, 'Z'
    ja .Lsci_a1
    add eax, 32
.Lsci_a1:
    cmp ecx, 'A'
    jb .Lsci_c1
    cmp ecx, 'Z'
    ja .Lsci_c1
    add ecx, 32
.Lsci_c1:
    cmp eax, ecx
    jne .Lsci_next
    inc r8
    inc r9
    jmp .Lsci_inner
.Lsci_next:
    inc rdi
    jmp .Lsci_outer
.Lsci_found:
    mov eax, 1
    ret
.Lsci_not_found:
    xor eax, eax
    ret

# const char *str_chr(const char *s, int ch)
str_chr:
.Lschr_loop:
    movzx eax, byte ptr [rdi]
    cmp eax, esi
    je .Lschr_hit
    test eax, eax
    jz .Lschr_miss
    inc rdi
    jmp .Lschr_loop
.Lschr_hit:
    mov rax, rdi
    ret
.Lschr_miss:
    xor eax, eax
    ret

# const char *str_rchr(const char *s, int ch)
str_rchr:
    xor eax, eax
.Lsrchr_loop:
    movzx ecx, byte ptr [rdi]
    cmp ecx, esi
    cmove rax, rdi
    test ecx, ecx
    jz .Lsrchr_done
    inc rdi
    jmp .Lsrchr_loop
.Lsrchr_done:
    ret

# int str_starts_with(const char *s, const char *prefix)
str_starts_with:
.Lssw_loop:
    movzx ecx, byte ptr [rsi]
    test ecx, ecx
    jz .Lssw_yes
    movzx eax, byte ptr [rdi]
    cmp eax, ecx
    jne .Lssw_no
    inc rdi
    inc rsi
    jmp .Lssw_loop
.Lssw_yes:
    mov eax, 1
    ret
.Lssw_no:
    xor eax, eax
    ret

# size_t u64_to_dec(uint64_t val, char *buf)
# buf must have >= 21 bytes. Returns length (NUL-terminated).
u64_to_dec:
    mov rax, rdi
    mov r8, rsi               # buf start
    sub rsp, 32
    xor ecx, ecx              # digit count
    mov r9, 10
.Lud_div:
    xor edx, edx
    div r9
    add dl, '0'
    mov byte ptr [rsp + rcx], dl
    inc rcx
    test rax, rax
    jnz .Lud_div

    mov rax, rcx              # return length
    xor r10d, r10d
.Lud_rev:
    dec rcx
    mov dl, byte ptr [rsp + rcx]
    mov byte ptr [r8 + r10], dl
    inc r10
    test rcx, rcx
    jnz .Lud_rev

    mov byte ptr [r8 + r10], 0
    add rsp, 32
    ret

# size_t u64_to_hex(uint64_t val, char *buf, int min_digits)
u64_to_hex:
    push rbx
    mov rax, rdi
    mov r8, rsi
    mov r9d, edx
    sub rsp, 32
    xor ecx, ecx
    lea rbx, [rip + hex_digits]
.Luh_div:
    mov r10, rax
    and r10, 15
    mov dl, byte ptr [rbx + r10]
    mov byte ptr [rsp + rcx], dl
    inc ecx
    shr rax, 4
    test rax, rax
    jnz .Luh_div
.Luh_pad:
    cmp ecx, r9d
    jge .Luh_rev_prep
    mov byte ptr [rsp + rcx], '0'
    inc ecx
    jmp .Luh_pad
.Luh_rev_prep:
    mov eax, ecx
    xor r10d, r10d
.Luh_rev:
    dec ecx
    mov dl, byte ptr [rsp + rcx]
    mov byte ptr [r8 + r10], dl
    inc r10
    test ecx, ecx
    jnz .Luh_rev
    mov byte ptr [r8 + r10], 0
    add rsp, 32
    pop rbx
    ret

# size_t format_size(int64_t bytes, char *buf)
# Formats human-readable size (e.g. "512 B", "4.2 K", "128 M") into buf (>= 16 bytes)
format_size:
    push rbx
    push r12
    mov rbx, rsi              # buf
    mov rax, rdi
    test rax, rax
    jns .Lfs_nonneg
    xor eax, eax
.Lfs_nonneg:
    cmp rax, 1024
    jae .Lfs_scaled

    # < 1024 bytes: "<N> B"
    mov rdi, rax
    mov rsi, rbx
    call u64_to_dec
    mov byte ptr [rbx + rax], ' '
    mov byte ptr [rbx + rax + 1], 'B'
    mov byte ptr [rbx + rax + 2], 0
    add rax, 2
    pop r12
    pop rbx
    ret

.Lfs_scaled:
    # Scale by 1024 keeping remainder for 1 decimal digit
    xor r12d, r12d            # unit index: 0=B, 1=K, 2=M, 3=G, 4=T, 5=P, 6=E
    xor edx, edx
.Lfs_loop:
    cmp rax, 1024
    jb .Lfs_got_unit
    cmp r12d, 6
    jae .Lfs_got_unit
    mov rcx, 1024
    xor edx, edx
    div rcx                   # rax = quotient, rdx = remainder (0..1023)
    inc r12d
    jmp .Lfs_loop

.Lfs_got_unit:
    # rdx has remainder; compute tenth = (rdx * 10) / 1024
    imul rdx, rdx, 10
    shr rdx, 10               # 0..9
    push rdx
    push rax
    mov rdi, rax
    mov rsi, rbx
    call u64_to_dec           # rax = digits written
    pop rcx                   # quotient
    pop rdx                   # tenth digit
    cmp rcx, 100
    jae .Lfs_no_dec           # >= 100: skip decimal (e.g. "512 K")
    mov byte ptr [rbx + rax], '.'
    add dl, '0'
    mov byte ptr [rbx + rax + 1], dl
    add rax, 2
.Lfs_no_dec:
    mov byte ptr [rbx + rax], ' '
    lea rcx, [rip + size_units]
    mov cl, byte ptr [rcx + r12]
    mov byte ptr [rbx + rax + 1], cl
    mov byte ptr [rbx + rax + 2], 0
    add rax, 2
    pop r12
    pop rbx
    ret

# void format_perms(uint32_t mode, char *buf)
# Writes 10 chars + NUL (e.g. "drwxr-xr-x")
format_perms:
    mov eax, edi
    and eax, S_IFMT
    mov cl, '-'
    cmp eax, S_IFDIR
    je .Lfp_is_dir
    cmp eax, S_IFLNK
    je .Lfp_is_lnk
    jmp .Lfp_type_ok
.Lfp_is_dir:
    mov cl, 'd'
    jmp .Lfp_type_ok
.Lfp_is_lnk:
    mov cl, 'l'
.Lfp_type_ok:
    mov byte ptr [rsi], cl

    # 9 permission bits from bit 8 down to bit 0
    # Pattern: r, w, x repeated 3 times
    mov ecx, 8
    mov r8d, 1                # write index
.Lfp_loop:
    mov eax, edi
    bt eax, ecx
    jnc .Lfp_dash
    # Select 'r', 'w', or 'x' based on (8 - ecx) % 3
    mov eax, 8
    sub eax, ecx
    xor edx, edx
    mov r9d, 3
    div r9d                   # edx = 0(r), 1(w), 2(x)
    mov al, 'r'
    cmp edx, 0
    je .Lfp_put
    mov al, 'w'
    cmp edx, 1
    je .Lfp_put
    mov al, 'x'
    jmp .Lfp_put
.Lfp_dash:
    mov al, '-'
.Lfp_put:
    mov byte ptr [rsi + r8], al
    inc r8d
    dec ecx
    jns .Lfp_loop
    mov byte ptr [rsi + 10], 0
    ret

# void format_datetime(int64_t epoch_sec, char *buf)
# Formats UTC timestamp as "YYYY-MM-DD HH:MM" (16 chars + NUL, buf >= 20 bytes)
format_datetime:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi              # buf

    # z = epoch / 86400, rem = epoch % 86400 (Euclidean floor)
    mov rax, rdi
    mov rcx, 86400
    cqo
    idiv rcx                  # rax = days, rdx = rem
    test rdx, rdx
    jns .Lfdt_rem_ok
    add rdx, 86400
    dec rax
.Lfdt_rem_ok:
    mov r12, rdx              # seconds in day (0..86399)
    add rax, 719468           # shift to 0000-03-01 epoch

    # era = (z >= 0 ? z : z - 146096) / 146097
    mov r8, rax
    test r8, r8
    jns .Lfdt_era_pos
    sub r8, 146096
.Lfdt_era_pos:
    mov r9, rax               # save z
    mov rax, r8
    mov rcx, 146097
    cqo
    idiv rcx
    mov r13, rax              # era

    # doe = z - era * 146097 (0..146096)
    imul rcx, r13, 146097
    mov r14, r9
    sub r14, rcx              # doe

    # yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, r14
    xor edx, edx
    mov rcx, 1460
    div rcx
    mov r8, r14
    sub r8, rax

    mov rax, r14
    xor edx, edx
    mov rcx, 36524
    div rcx
    add r8, rax

    mov rax, r14
    xor edx, edx
    mov rcx, 146096
    div rcx
    sub r8, rax

    mov rax, r8
    xor edx, edx
    mov rcx, 365
    div rcx
    mov r15, rax              # yoe (0..399)

    # doy = doe - (365*yoe + yoe/4 - yoe/100)
    imul r8, r15, 365
    mov rax, r15
    shr rax, 2
    add r8, rax
    mov rax, r15
    xor edx, edx
    mov rcx, 100
    div rcx
    sub r8, rax
    mov r9, r14
    sub r9, r8                # doy (0..365)

    # mp = (5*doy + 2) / 153
    lea rax, [r9 + r9*4 + 2]
    xor edx, edx
    mov rcx, 153
    div rcx
    mov r10, rax              # mp (0..11)

    # day = doy - (153*mp + 2)/5 + 1
    imul rax, r10, 153
    add rax, 2
    xor edx, edx
    mov rcx, 5
    div rcx
    mov r8, r9
    sub r8, rax
    inc r8                    # day (1..31)

    # month = mp + (mp < 10 ? 3 : -9)
    mov r9, r10
    cmp r10, 10
    jae .Lfdt_m_sub
    add r9, 3
    jmp .Lfdt_m_ok
.Lfdt_m_sub:
    sub r9, 9
.Lfdt_m_ok:
    # year = yoe + era*400 + (month <= 2 ? 1 : 0)
    imul rax, r13, 400
    add rax, r15
    cmp r9, 2
    ja .Lfdt_y_ok
    inc rax
.Lfdt_y_ok:
    # rax = year, r9 = month, r8 = day, r12 = sec_in_day
    # Clamp year to 0..9999 for 4-digit print
    cmp rax, 0
    jge .Lfdt_y_nonneg
    xor eax, eax
.Lfdt_y_nonneg:
    cmp rax, 9999
    jle .Lfdt_y_fit
    mov rax, 9999
.Lfdt_y_fit:
    # Write YYYY
    mov rcx, 1000
    xor edx, edx
    div rcx
    add al, '0'
    mov byte ptr [rbx + 0], al
    mov rax, rdx
    mov rcx, 100
    xor edx, edx
    div rcx
    add al, '0'
    mov byte ptr [rbx + 1], al
    mov rax, rdx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 2], al
    mov byte ptr [rbx + 3], dl
    mov byte ptr [rbx + 4], '-'

    # Write MM
    mov rax, r9
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 5], al
    mov byte ptr [rbx + 6], dl
    mov byte ptr [rbx + 7], '-'

    # Write DD
    mov rax, r8
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 8], al
    mov byte ptr [rbx + 9], dl
    mov byte ptr [rbx + 10], ' '

    # hh = r12 / 3600, mm = (r12 % 3600) / 60
    mov rax, r12
    xor edx, edx
    mov rcx, 3600
    div rcx
    mov r8, rdx               # rem sec
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 11], al
    mov byte ptr [rbx + 12], dl
    mov byte ptr [rbx + 13], ':'

    mov rax, r8
    xor edx, edx
    mov rcx, 60
    div rcx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov byte ptr [rbx + 14], al
    mov byte ptr [rbx + 15], dl
    mov byte ptr [rbx + 16], 0

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void path_join(char *dst, const char *dir, const char *name, size_t cap)
# rdi=dst, rsi=dir, rdx=name, rcx=cap
path_join:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi              # dst
    mov r12, rsi              # dir
    mov r13, rdx              # name
    mov r14, rcx              # cap

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call str_copy             # rax = len(dir)

    test rax, rax
    jz .Lpj_append_name
    cmp byte ptr [rbx + rax - 1], '/'
    je .Lpj_append_name

    # Append '/'
    lea rcx, [rax + 1]
    cmp rcx, r14
    jae .Lpj_done
    mov byte ptr [rbx + rax], '/'
    mov byte ptr [rbx + rax + 1], 0

.Lpj_append_name:
    mov rsi, r13
    # Skip leading '/' in name if any
.Lpj_skip_slash:
    cmp byte ptr [rsi], '/'
    jne .Lpj_cat
    inc rsi
    jmp .Lpj_skip_slash
.Lpj_cat:
    mov rdi, rbx
    mov rdx, r14
    call str_cat
.Lpj_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# void path_dirname(const char *path, char *dst, size_t cap)
# rdi=path, rsi=dst, rdx=cap
path_dirname:
    push rbx
    push r12
    push r13
    mov rbx, rsi              # dst
    mov r12, rdx              # cap
    mov r13, rdi              # src

    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    call str_copy             # rax = len

    # Strip trailing slashes (except root "/")
.Lpd_strip:
    cmp rax, 1
    jbe .Lpd_find_slash
    cmp byte ptr [rbx + rax - 1], '/'
    jne .Lpd_find_slash
    dec rax
    mov byte ptr [rbx + rax], 0
    jmp .Lpd_strip

.Lpd_find_slash:
    test rax, rax
    jz .Lpd_dot
.Lpd_back:
    dec rax
    cmp byte ptr [rbx + rax], '/'
    je .Lpd_at_slash
    test rax, rax
    jnz .Lpd_back
    # No slash found -> "."
.Lpd_dot:
    cmp r12, 2
    jb .Lpd_done
    mov byte ptr [rbx], '.'
    mov byte ptr [rbx + 1], 0
    jmp .Lpd_done

.Lpd_at_slash:
    test rax, rax
    jnz .Lpd_cut
    # Slash is at index 0 -> "/"
    cmp r12, 2
    jb .Lpd_done
    mov byte ptr [rbx + 1], 0
    jmp .Lpd_done

.Lpd_cut:
    mov byte ptr [rbx + rax], 0
.Lpd_done:
    pop r13
    pop r12
    pop rbx
    ret

# const char *path_basename(const char *path)
path_basename:
    push rbx
    mov rbx, rdi
    mov esi, '/'
    call str_rchr
    test rax, rax
    jz .Lpb_ret_full
    inc rax
    cmp byte ptr [rax], 0
    jne .Lpb_done
    # Trailing slash: if only "/", return "/"
    cmp byte ptr [rbx + 1], 0
    je .Lpb_ret_full
.Lpb_done:
    pop rbx
    ret
.Lpb_ret_full:
    mov rax, rbx
    pop rbx
    ret
