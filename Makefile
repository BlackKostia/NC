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
	src/tui/theme.s \
	src/tui/i18n.s \
	src/tui/screen.s \
	src/tui/input.s \
	src/fs/dir_model.s \
	src/fs/dir_sort.s \
	src/fs/file_ops.s \
	src/fs/task.s \
	src/ui/header_bar.s \
	src/ui/function_bar.s \
	src/ui/status_bar.s \
	src/ui/file_pane.s \
	src/ui/preview_pane.s \
	src/ui/dialogs.s \
	src/ui/progress_dialog.s \
	src/app/app.s \
	src/app/app_task.s

PAL_SRCS := \
	src/os/$(OS)/$(ARCH)/pal_os.s \
	src/os/$(OS)/$(ARCH)/pal_uring.s \
	src/os/$(OS)/$(ARCH)/pal_simd.s

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

verify:
	./.agents/skills/duop-pty-verify/scripts/verify_build.sh

hooks:
	git config core.hooksPath .githooks
	chmod +x .githooks/* .agents/hooks/*.py .agents/skills/*/scripts/*

clean:
	rm -rf $(BUILD) $(TARGET)
