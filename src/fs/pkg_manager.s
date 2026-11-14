# src/fs/pkg_manager.s - Package install, list, verify & remove for Duop
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.equ PKG_ENTRY_SZ, 296
.equ AENT_SIZE,    288

.section .rodata
pkm_env_dir:   .asciz "DUOP_PKG_DIR="
pkm_env_xdg:   .asciz "XDG_CONFIG_HOME="
pkm_env_home:  .asciz "HOME="
pkm_sub_cfg:   .asciz "/.config/duop/packages"
pkm_sub_duop:  .asciz "/duop/packages"
pkm_http:      .asciz "http://"
pkm_https:     .asciz "https://"
pkm_dl_tmp:    .asciz "/tmp/duop_pkg_dl.tar.gz"
pkm_manifest:  .asciz "manifest.ini"
pkm_sha_file:  .asciz "sha256"
pkm_files_lst: .asciz "files.list"
pkm_ext_lang:  .asciz ".lang"
pkm_ext_lay:   .asciz ".layout"
pkm_dir_lang:  .asciz "/../lang"
pkm_dir_lay:   .asciz "/../layouts"
pkm_dotdot:    .asciz ".."

.section .text
.global pkg_get_root
.global pkg_list
.global pkg_install_archive
.global pkg_remove
.global pkg_verify

.extern cfg_getenv
.extern fs_read_file_head
.extern hash_file
.extern mem_alloc
.extern mem_free
.extern mem_zero
.extern os_dir_read
.extern os_dir_next_ex
.extern path_basename
.extern path_join
.extern pkg_extract_entry_to
.extern pkg_fetch_url
.extern pkg_free_archive
.extern pkg_load_archive
.extern pkg_mkdir_p
.extern pkg_parse_manifest
.extern pkg_write_file
.extern str_casecmp
.extern str_cat
.extern str_cmp
.extern str_copy
.extern str_len
.extern str_starts_with

# void pkg_get_root(char **envp, char *out, int cap)
pkg_get_root:
    push rbx; push r12; push r13
    mov rbx, rdi; mov r12, rsi; mov r13d, edx
    lea rsi, [rip + pkm_env_dir]; call cfg_getenv
    test rax, rax; jz .Lpgr_xdg
    mov rdi, r12; mov rsi, rax; mov edx, r13d; call str_copy; jmp .Lpgr_ret
.Lpgr_xdg:
    mov rdi, rbx; lea rsi, [rip + pkm_env_xdg]; call cfg_getenv
    test rax, rax; jz .Lpgr_home
    mov rdi, r12; mov rsi, rax; mov edx, r13d; call str_copy
    mov rdi, r12; lea rsi, [rip + pkm_sub_duop]; mov edx, r13d; call str_cat; jmp .Lpgr_ret
.Lpgr_home:
    mov rdi, rbx; lea rsi, [rip + pkm_env_home]; call cfg_getenv
    test rax, rax; jz .Lpgr_empty
    mov rdi, r12; mov rsi, rax; mov edx, r13d; call str_copy
    mov rdi, r12; lea rsi, [rip + pkm_sub_cfg]; mov edx, r13d; call str_cat; jmp .Lpgr_ret
.Lpgr_empty:
    mov byte ptr [r12], 0
.Lpgr_ret:
    pop r13; pop r12; pop rbx; ret

# int pkm_safe_name(const char *s) -> 1 safe, 0 unsafe
pkm_safe_name:
    test rdi, rdi; jz .Lpsn_no
    cmp byte ptr [rdi], 0; je .Lpsn_no
    lea rsi, [rip + pkm_dotdot]; call str_cmp
    test eax, eax; jz .Lpsn_no
.Lpsn_loop:
    mov al, [rdi]; test al, al; jz .Lpsn_ok
    cmp al, '/'; je .Lpsn_no
    inc rdi; jmp .Lpsn_loop
.Lpsn_ok:
    mov eax, 1; ret
.Lpsn_no:
    xor eax, eax; ret

# int pkg_list(char **envp, PkgEntry *out, int max) -> count
pkg_list:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16384 + 32
    mov r12, rsi; mov r13d, edx; xor r14d, r14d
    lea rsi, [rsp + 32]; mov edx, PATH_MAX; call pkg_get_root
    mov edi, AT_FDCWD; lea rsi, [rsp + 32]
    mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC; xor r10d, r10d; OS_OPENAT
    test rax, rax; js .Lpl_ret
    mov ebx, eax
.Lpl_read:
    mov edi, ebx; lea rsi, [rsp + 32 + PATH_MAX * 2]; mov edx, 16384; call os_dir_read
    test rax, rax; jle .Lpl_close
    mov [rsp], rax; mov qword ptr [rsp + 8], 0
.Lpl_ent:
    cmp r14d, r13d; jge .Lpl_close
    lea rdi, [rsp + 32 + PATH_MAX * 2]; mov rsi, [rsp]
    lea rdx, [rsp + 8]; lea rcx, [rsp + 16]; lea r8, [rsp + 24]
    call os_dir_next_ex
    test rax, rax; jz .Lpl_read
    mov r15, rax
    mov rdi, r15; call pkm_safe_name; test eax, eax; jz .Lpl_ent
    lea rdi, [rsp + 32 + PATH_MAX]; lea rsi, [rsp + 32]; mov rdx, r15; mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 32 + PATH_MAX]; mov rsi, rdi; lea rdx, [rip + pkm_manifest]; mov ecx, PATH_MAX
    call path_join
    lea rdi, [rsp + 32 + PATH_MAX]; lea rsi, [rsp + 32 + PATH_MAX * 2]; mov edx, 4096
    lea rcx, [rsp + 24]; call fs_read_file_head
    test rax, rax; js .Lpl_ent
    imul rax, r14, PKG_ENTRY_SZ; lea rdx, [r12 + rax]
    lea rdi, [rsp + 32 + PATH_MAX * 2]; mov esi, [rsp + 24]; call pkg_parse_manifest
    imul rax, r14, PKG_ENTRY_SZ; cmp byte ptr [r12 + rax], 0; je .Lpl_ent
    inc r14d; jmp .Lpl_ent
.Lpl_close:
    mov edi, ebx; OS_CLOSE
.Lpl_ret:
    mov eax, r14d
    add rsp, PATH_MAX * 2 + 16384 + 32
    pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkm_ends_with(const char *s, const char *suf) -> 1 match, 0 no
pkm_ends_with:
    push rbx; push r12
    mov rbx, rdi; mov r12, rsi
    call str_len; push rax
    mov rdi, r12; call str_len
    pop rcx
    cmp rcx, rax; jl .Lpew_no
    sub rcx, rax; lea rdi, [rbx + rcx]; mov rsi, r12; call str_cmp
    test eax, eax; jnz .Lpew_no
    mov eax, 1; pop r12; pop rbx; ret
.Lpew_no:
    xor eax, eax; pop r12; pop rbx; ret

# Helper: activate *.lang / *.layout into sibling lang/ or layouts/ dir and append to files.list
pkm_activate_file:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 16
    mov r12, rdi; mov r13, rsi; mov r14, rcx; mov r15, r8
    mov rdi, rdx; call path_basename; mov rbx, rax
    mov rdi, rbx; lea rsi, [rip + pkm_ext_lang]; call pkm_ends_with
    test eax, eax; jnz .Lpaf_lang
    mov rdi, rbx; lea rsi, [rip + pkm_ext_lay]; call pkm_ends_with
    test eax, eax; jz .Lpaf_ret
    lea rsi, [rip + pkm_dir_lay]; jmp .Lpaf_cp
.Lpaf_lang:
    lea rsi, [rip + pkm_dir_lang]
.Lpaf_cp:
    mov rdi, rsp; push rsi; mov rsi, r12; mov edx, PATH_MAX; call str_copy
    pop rsi; mov rdi, rsp; mov edx, PATH_MAX; call str_cat
    mov rdi, rsp; call pkg_mkdir_p
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; mov rdx, rbx; mov ecx, PATH_MAX; call path_join
    mov edi, 524288; call mem_alloc; test rax, rax; jz .Lpaf_ret
    mov [rsp + PATH_MAX * 2], rax
    mov rdi, r13; mov rsi, rax; mov edx, 524288; lea rcx, [rsp + PATH_MAX * 2 + 8]
    call fs_read_file_head; test rax, rax; js .Lpaf_free
    lea rdi, [rsp + PATH_MAX]; mov rsi, [rsp + PATH_MAX * 2]; mov rdx, [rsp + PATH_MAX * 2 + 8]
    call pkg_write_file
    test eax, eax; jnz .Lpaf_free
    mov rdi, r14; lea rsi, [rsp + PATH_MAX]; mov edx, 8192; call str_cat
    mov rdi, r14; call str_len; mov word ptr [r14 + rax], 0x000A
    inc rax; mov [r15], rax
.Lpaf_free:
    mov rdi, [rsp + PATH_MAX * 2]; call mem_free
.Lpaf_ret:
    add rsp, PATH_MAX * 2 + 16; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# void pkm_extract_all(ArcCtx *ctx, const char *pkg_dir, const char *pkg_root, char *files_buf, uint64_t *files_len)
pkm_extract_all:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX + 24
    mov r12, rdi; mov r13, rsi; mov [rsp + PATH_MAX], rdx
    mov r15, rcx; mov [rsp + PATH_MAX + 8], r8
    xor r14d, r14d
.Lpea_loop:
    cmp r14d, [r12 + 4]; jge .Lpea_done
    imul rbx, r14, AENT_SIZE; add rbx, [r12 + 24]
    cmp dword ptr [rbx + 284], 0; jne .Lpea_next
    mov rdi, rbx; call path_basename
    mov [rsp + PATH_MAX + 16], rax
    mov rdi, rax; call pkm_safe_name; test eax, eax; jz .Lpea_next
    mov rdi, rsp; mov rsi, r13; mov rdx, [rsp + PATH_MAX + 16]; mov ecx, PATH_MAX; call path_join
    mov rdi, r12; mov rsi, rbx; mov rdx, rsp; call pkg_extract_entry_to
    test eax, eax; jnz .Lpea_next
    mov rdi, [rsp + PATH_MAX]; mov rsi, rsp; mov rdx, [rsp + PATH_MAX + 16]
    mov rcx, r15; mov r8, [rsp + PATH_MAX + 8]; call pkm_activate_file
.Lpea_next:
    inc r14d; jmp .Lpea_loop
.Lpea_done:
    add rsp, PATH_MAX + 24; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkm_install_from_ctx(char **envp, ArcCtx *ctx, const char *sha_hex) -> 0 ok, -1 err
pkm_install_from_ctx:
    push rbx; push r12; push r13; push r14; push r15
    sub rsp, PATH_MAX * 2 + 320
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    xor r14d, r14d
.Lpi_find:
    cmp r14d, [r12 + 4]; jge .Lpi_err
    imul rax, r14, AENT_SIZE; add rax, [r12 + 24]
    mov rdi, rax; call path_basename
    mov rdi, rax; lea rsi, [rip + pkm_manifest]; call str_cmp
    test eax, eax; jz .Lpi_got_mf
    inc r14d; jmp .Lpi_find
.Lpi_got_mf:
    imul rax, r14, AENT_SIZE; add rax, [r12 + 24]; mov r15, rax
    mov rdi, rbx; lea rsi, [rsp]; mov edx, PATH_MAX; call pkg_get_root
    mov rdi, rsp; call pkg_mkdir_p
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; lea rdx, [rip + pkm_manifest]; mov ecx, PATH_MAX; call path_join
    mov rdi, r12; mov rsi, r15; lea rdx, [rsp + PATH_MAX]; call pkg_extract_entry_to
    test eax, eax; jnz .Lpi_err
    mov edi, 4096; call mem_alloc; test rax, rax; jz .Lpi_err
    mov r14, rax
    lea rdi, [rsp + PATH_MAX]; mov rsi, r14; mov edx, 4096; lea rcx, [rsp + PATH_MAX * 2]
    call fs_read_file_head; push rax
    mov edi, AT_FDCWD; lea rsi, [rsp + PATH_MAX + 8]; xor edx, edx; OS_UNLINKAT
    pop rax; test rax, rax; js .Lpi_free_mf
    mov rdi, r14; mov esi, [rsp + PATH_MAX * 2]; lea rdx, [rsp + PATH_MAX * 2 + 16]; call pkg_parse_manifest
    mov rdi, r14; call mem_free
    lea rdi, [rsp + PATH_MAX * 2 + 16]; call pkm_safe_name; test eax, eax; jz .Lpi_err
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; lea rdx, [rsp + PATH_MAX * 2 + 16]
    mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + PATH_MAX]; call pkg_mkdir_p
    mov edi, 8192; call mem_alloc; test rax, rax; jz .Lpi_err
    mov r15, rax; mov byte ptr [r15], 0; mov qword ptr [rsp + PATH_MAX * 2 + 8], 0
    mov rdi, r12; lea rsi, [rsp + PATH_MAX]; mov rdx, rsp; mov rcx, r15
    lea r8, [rsp + PATH_MAX * 2 + 8]; call pkm_extract_all
    sub rsp, PATH_MAX
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX * 2]; lea rdx, [rip + pkm_sha_file]; mov ecx, PATH_MAX; call path_join
    mov rdi, rsp; mov rsi, r13; mov rdx, 64; call pkg_write_file
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX * 2]; lea rdx, [rip + pkm_files_lst]; mov ecx, PATH_MAX; call path_join
    mov rdi, r15; call str_len; mov rdx, rax; mov rdi, rsp; mov rsi, r15; call pkg_write_file
    add rsp, PATH_MAX
    mov rdi, r15; call mem_free; xor eax, eax; jmp .Lpi_ret
.Lpi_free_mf:
    mov rdi, r14; call mem_free
.Lpi_err:
    mov eax, -1
.Lpi_ret:
    add rsp, PATH_MAX * 2 + 320; pop r15; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_install_archive(char **envp, const char *path_or_url, const char *expected_sha256) -> 0 ok, <0 err
pkg_install_archive:
    push rbx; push r12; push r13; push r14
    sub rsp, 104
    mov rbx, rdi; mov r12, rsi; mov r13, rdx
    mov dword ptr [rsp + 96], 0
    mov rdi, r12; lea rsi, [rip + pkm_http]; call str_starts_with
    test eax, eax; jnz .Lpia_dl
    mov rdi, r12; lea rsi, [rip + pkm_https]; call str_starts_with
    test eax, eax; jz .Lpia_hash
.Lpia_dl:
    mov rdi, rbx; mov rsi, r12; lea rdx, [rip + pkm_dl_tmp]; call pkg_fetch_url
    test eax, eax; jnz .Lpia_err
    lea r12, [rip + pkm_dl_tmp]; mov dword ptr [rsp + 96], 1
.Lpia_hash:
    mov rdi, r12; lea rsi, [rsp]; lea rdx, [rsp + 8]; call hash_file
    test eax, eax; js .Lpia_err
    test r13, r13; jz .Lpia_load
    cmp byte ptr [r13], 0; je .Lpia_load
    lea rdi, [rsp + 8]; mov rsi, r13; call str_casecmp
    test eax, eax; jnz .Lpia_err
.Lpia_load:
    mov rdi, r12; call pkg_load_archive
    test rax, rax; jz .Lpia_err
    mov r14, rax
    mov rdi, rbx; mov rsi, r14; lea rdx, [rsp + 8]; call pkm_install_from_ctx
    push rax; mov rdi, r14; call pkg_free_archive; pop rax
    jmp .Lpia_clean
.Lpia_err:
    mov eax, -1
.Lpia_clean:
    cmp dword ptr [rsp + 96], 0; je .Lpia_ret
    push rax; mov edi, AT_FDCWD; lea rsi, [rip + pkm_dl_tmp]; xor edx, edx; OS_UNLINKAT; pop rax
.Lpia_ret:
    add rsp, 104; pop r14; pop r13; pop r12; pop rbx; ret

# int pkg_verify(char **envp, const char *name) -> 0 ok, -1 err
pkg_verify:
    push rbx; push r12; sub rsp, PATH_MAX * 2 + 80
    mov rbx, rdi; mov r12, rsi
    mov rdi, r12; call pkm_safe_name; test eax, eax; jz .Lpv_err
    mov rdi, rbx; mov rsi, rsp; mov edx, PATH_MAX; call pkg_get_root
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; mov rdx, r12; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + PATH_MAX]; mov rsi, rdi; lea rdx, [rip + pkm_sha_file]; mov ecx, PATH_MAX; call path_join
    lea rdi, [rsp + PATH_MAX]; lea rsi, [rsp + PATH_MAX * 2]; mov edx, 72; lea rcx, [rsp + PATH_MAX * 2 + 72]
    call fs_read_file_head
    test rax, rax; js .Lpv_err
    cmp qword ptr [rsp + PATH_MAX * 2 + 72], 64; jl .Lpv_err
    xor eax, eax; jmp .Lpv_ret
.Lpv_err:
    mov eax, -1
.Lpv_ret:
    add rsp, PATH_MAX * 2 + 80; pop r12; pop rbx; ret

# int pkg_remove(char **envp, const char *name) -> 0 ok, -1 err
pkg_remove:
    push rbx; push r12; push r13; push r14
    sub rsp, PATH_MAX * 2 + 16384 + 32
    mov rbx, rdi; mov r12, rsi
    mov rdi, r12; call pkm_safe_name; test eax, eax; jz .Lpr_err
    mov rdi, rbx; mov rsi, rsp; mov edx, PATH_MAX; call pkg_get_root
    lea rdi, [rsp + PATH_MAX]; mov rsi, rsp; mov rdx, r12; mov ecx, PATH_MAX; call path_join
    sub rsp, PATH_MAX
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX * 2]; lea rdx, [rip + pkm_files_lst]; mov ecx, PATH_MAX; call path_join
    mov rdi, rsp; lea rsi, [rsp + PATH_MAX * 3 + 32]; mov edx, 8192; lea rcx, [rsp + PATH_MAX * 3 + 8]
    call fs_read_file_head
    add rsp, PATH_MAX
    test rax, rax; js .Lpr_dir
    lea r13, [rsp + PATH_MAX * 2 + 32]; mov r14, [rsp + PATH_MAX * 2 + 8]; add r14, r13
.Lpr_fl:
    cmp r13, r14; jae .Lpr_dir
    mov rdi, r13
.Lpr_nl:
    cmp rdi, r14; jae .Lpr_dir
    cmp byte ptr [rdi], '\n'; je .Lpr_un
    inc rdi; jmp .Lpr_nl
.Lpr_un:
    mov byte ptr [rdi], 0; push rdi
    mov edi, AT_FDCWD; mov rsi, r13; xor edx, edx; OS_UNLINKAT
    pop rdi; lea r13, [rdi + 1]; jmp .Lpr_fl
.Lpr_dir:
    mov edi, AT_FDCWD; lea rsi, [rsp + PATH_MAX]; mov edx, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor r10d, r10d; OS_OPENAT; test rax, rax; js .Lpr_err
    mov r13d, eax
.Lpr_rd:
    mov edi, r13d; lea rsi, [rsp + PATH_MAX * 2 + 32]; mov edx, 16384; call os_dir_read
    test rax, rax; jle .Lpr_rmdir
    mov [rsp + PATH_MAX * 2], rax; mov qword ptr [rsp + PATH_MAX * 2 + 8], 0
.Lpr_ent:
    lea rdi, [rsp + PATH_MAX * 2 + 32]; mov rsi, [rsp + PATH_MAX * 2]
    lea rdx, [rsp + PATH_MAX * 2 + 8]; lea rcx, [rsp + PATH_MAX * 2 + 16]; lea r8, [rsp + PATH_MAX * 2 + 24]
    call os_dir_next_ex
    test rax, rax; jz .Lpr_rd
    mov r14, rax
    mov rdi, r14; call pkm_safe_name; test eax, eax; jz .Lpr_ent
    mov edi, r13d; mov rsi, r14; xor edx, edx; OS_UNLINKAT
    jmp .Lpr_ent
.Lpr_rmdir:
    mov edi, r13d; OS_CLOSE
    mov edi, AT_FDCWD; lea rsi, [rsp + PATH_MAX]; mov edx, AT_REMOVEDIR; OS_UNLINKAT
    test rax, rax; js .Lpr_err
    xor eax, eax; jmp .Lpr_ret
.Lpr_err:
    mov eax, -1
.Lpr_ret:
    add rsp, PATH_MAX * 2 + 16384 + 32; pop r14; pop r13; pop r12; pop rbx; ret
