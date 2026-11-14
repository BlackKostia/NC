# Duop — Multi-Platform Pure Assembly Project Makefile (compile-time OS & ARCH selection)

OS      ?= linux
ARCH    ?= x86_64
TARGET  := duop
BUILD   := build
VERSION := $(strip $(shell cat VERSION))
VER_INC := $(BUILD)/version.inc
PAL_INC := include/os/$(OS)/$(ARCH)

AS      := as
LD      := ld
ASFLAGS := -I $(PAL_INC) -I include -I $(BUILD) -g
LDFLAGS :=

SRCS := \
	src/main.s \
	src/core/memory.s \
	src/core/string.s \
	src/core/utf8.s \
	src/core/oop_rt.s \
	src/core/syscall.s \
	src/core/config.s \
	src/core/hash.s \
	src/tui/theme.s \
	src/tui/i18n.s \
	src/tui/i18n_env.s \
	src/tui/screen.s \
	src/tui/input.s \
	src/fs/dir_model.s \
	src/fs/dir_sort.s \
	src/fs/dir_cache.s \
	src/fs/file_ops.s \
	src/fs/task.s \
	src/fs/task_conflict.s \
	src/fs/dir_watch.s \
	src/fs/preview_io.s \
	src/fs/nav_state.s \
	src/fs/dir_search_match.s \
	src/fs/dir_search.s \
	src/fs/dir_fuzzy.s \
	src/fs/dir_diff.s \
	src/fs/inflate.s \
	src/fs/disk_usage.s \
	src/fs/archive_vfs.s \
	src/fs/git_status.s \
	src/fs/trash_undo.s \
	src/ui/header_bar.s \
	src/ui/function_bar.s \
	src/ui/status_bar.s \
	src/ui/file_pane.s \
	src/ui/preview_pane.s \
	src/ui/dialogs.s \
	src/ui/viewer_dialog.s \
	src/ui/progress_dialog.s \
	src/ui/conflict_dialog.s \
	src/ui/user_menu_dlg.s \
	src/ui/bookmark_dlg.s \
	src/ui/search_dialog.s \
	src/ui/attr_dialogs.s \
	src/ui/info_dialog.s \
	src/ui/fuzzy_dialog.s \
	src/ui/img_preview.s \
	src/ui/du_render.s \
	src/ui/git_render.s \
	src/ui/bulk_rename.s \
	src/ui/popup_menu.s \
	src/ui/term_pane.s \
	src/ui/term_keys.s \
	src/ui/syntax.s \
	src/ui/elf_inspect.s \
	src/ui/hex_edit.s \
	src/app/app.s \
	src/app/app_task.s \
	src/app/app_events.s \
	src/app/app_attr.s \
	src/app/app_ext.s \
	src/app/app_arc.s \
	src/app/app_menu.s

PAL_SRCS := \
	src/os/$(OS)/$(ARCH)/pal_os.s \
	src/os/$(OS)/$(ARCH)/pal_uring.s \
	src/os/$(OS)/$(ARCH)/pal_simd.s \
	src/os/$(OS)/$(ARCH)/pal_pty.s

OBJS := $(patsubst src/%.s,$(BUILD)/%.o,$(SRCS) $(PAL_SRCS))
INCS := $(wildcard include/*.inc) $(wildcard $(PAL_INC)/*.inc)

.PHONY: all release run test verify hooks clean

all: $(TARGET)

release: ASFLAGS := -I $(PAL_INC) -I include -I $(BUILD)
release: LDFLAGS := -s
release: clean $(TARGET)

$(TARGET): $(OBJS)
	$(LD) $(LDFLAGS) $(OBJS) -o $@

$(VER_INC): VERSION
	@mkdir -p $(BUILD)
	@printf '.macro DUOP_VER_ASCII\n    .ascii "$(VERSION)"\n.endm\n.macro DUOP_VER_ASCIZ\n    .asciz "$(VERSION)"\n.endm\n' > $@

$(BUILD)/%.o: src/%.s $(INCS) $(VER_INC)
	@mkdir -p $(dir $@)
	$(AS) $(ASFLAGS) $< -o $@

run: $(TARGET)
	./$(TARGET)

test: $(TARGET)
	python3 tests/test_pal_architecture.py
	python3 tests/test_pty.py
	python3 tests/test_fs_reliability.py
	python3 tests/test_performance_dir.py
	python3 tests/test_bg_tasks.py
	python3 tests/test_fastpath.py
	python3 tests/test_choosedir.py
	python3 tests/test_config_usermenu.py
	python3 tests/test_nav_tabs.py
	python3 tests/test_search_virtual.py
	python3 tests/test_trash_undo_attr.py
	python3 tests/test_fuzzy_palette.py
	python3 tests/test_img_preview.py
	python3 tests/test_disk_usage.py
	python3 tests/test_archive_vfs.py
	python3 tests/test_git_status.py
	python3 tests/test_bulk_rename.py
	python3 tests/test_viewer_pro.py
	python3 tests/test_diff_menu_clip.py
	python3 tests/test_term_pane.py
	python3 tests/test_nav_viewer.py
	python3 tests/test_event_loop.py

verify:
	./.agents/skills/duop-pty-verify/scripts/verify_build.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/* .agents/hooks/*.py .agents/skills/*/scripts/*

clean:
	rm -rf $(BUILD) $(TARGET)
