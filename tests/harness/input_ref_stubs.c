/* aarch64 has no frozen asm oracle: the harness' ref_* entry points forward to the C modules so input_cli.c links unchanged. */
#include "duop_tui.h"

int ref_input_next_event(Event *e, int ms) { return input_next_event(e, ms); }
int ref_input_probe_eof(void) { return input_probe_eof(); }
int ref_input_is_eof(void) { return input_is_eof(); }
void ref_input_set_aux_fd(int slot, int fd) { input_set_aux_fd(slot, fd); }
uint64_t ref_parse_uint(const char *s) { return parse_uint(s); }
void ref_term_caps_init(char **envp) { term_caps_init(envp); }
void ref_term_caps_refresh(int c, int r) { term_caps_refresh(c, r); }
int ref_term_caps_filter(uint8_t *b, int from, int len) { return term_caps_filter(b, from, len); }
int ref_term_img_proto(void) { return term_img_proto(); }
CellPx ref_term_cell_px(void) { return term_cell_px(); }
int ref_term_caps_changed(void) { return term_caps_changed(); }
