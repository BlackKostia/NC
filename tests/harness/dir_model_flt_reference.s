# Frozen reference oracle: prepare_filter and entry_passes_filter as they were in src/fs/dir_model_load.s before they moved to
# src/fs/dir_model_filter.c (tests/test_c_dir_model_filter.py links them next to the frozen dir_model_filter oracle)
.intel_syntax noprefix
.include "pal.inc"
.include "classes.inc"

.section .text
.global prepare_filter
.global entry_passes_filter

# ==============================================================================
# Helper: void prepare_filter(DirModel *this)
# Lowercases DirModel.filter once into flt_lc so per-entry matching is a pure SIMD scan.
# ==============================================================================
prepare_filter:
    xor ecx, ecx
.Lpf_loop:
    movzx eax, byte ptr [rdi + DirModel.filter + rcx]
    cmp eax, 'A'
    jb .Lpf_store
    cmp eax, 'Z'
    ja .Lpf_store
    add eax, 32
.Lpf_store:
    mov [rdi + DirModel.flt_lc + rcx], al
    test eax, eax
    jz .Lpf_done
    inc ecx
    cmp ecx, FILTER_MAX - 1
    jb .Lpf_loop
    mov byte ptr [rdi + DirModel.flt_lc + rcx], 0
.Lpf_done:
    mov [rdi + DirModel.flt_lc_len], ecx
    ret

# ==============================================================================
# Helper: int entry_passes_filter(const DirModel *this, uint32_t flags, const char *name)
# Requires prepare_filter() to have run for the current DirModel.filter.
# ==============================================================================
entry_passes_filter:
    test edx, FE_IS_PARENT
    jnz .Lepf_yes
    test edx, FE_IS_HIDDEN
    jz .Lepf_chk_str
    cmp dword ptr [rdi + DirModel.show_hidden], 0
    je .Lepf_no
.Lepf_chk_str:
    mov edx, [rdi + DirModel.flt_lc_len]
    test edx, edx
    jz .Lepf_yes
    lea rsi, [rdi + DirModel.flt_lc]
    mov rdi, rcx              # name
    jmp os_str_contains_ci_fast
.Lepf_yes:
    mov eax, 1
    ret
.Lepf_no:
    xor eax, eax
    ret

