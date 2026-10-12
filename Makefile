# wallhaven-cr build helpers.
#
# raylib and raygui are expected to be findable by pkg-config/ld.so. When they
# live under ~/.local (the usual case on this workstation) both paths are added.

LOCAL_PREFIX ?= $(HOME)/.local
RAYGUI_SRC   ?= /tmp/raygui
RAYGUI_SO    := $(LOCAL_PREFIX)/lib/libraygui.so
BIN          := bin/wallhaven-cr

export PKG_CONFIG_PATH := $(LOCAL_PREFIX)/lib/pkgconfig:$(PKG_CONFIG_PATH)
export LD_LIBRARY_PATH := $(LOCAL_PREFIX)/lib:$(LD_LIBRARY_PATH)

.PHONY: all build release run test clean raygui

all: build

build: $(BIN)

$(BIN): $(shell find src -name '*.cr') shard.yml shard.lock
	@mkdir -p bin
	crystal build src/main.cr -o $(BIN)

# raygui ships as a single header; compile it into a shared library once.
raygui: $(RAYGUI_SO)

$(RAYGUI_SO):
	@mkdir -p $(RAYGUI_SRC) $(LOCAL_PREFIX)/lib
	@test -f $(RAYGUI_SRC)/raygui.h || curl -sL -o $(RAYGUI_SRC)/raygui.h https://raw.githubusercontent.com/raysan5/raygui/4.0/src/raygui.h
	@printf '#define RAYGUI_IMPLEMENTATION\n#include "raygui.h"\n' > $(RAYGUI_SRC)/raygui_impl.c
	gcc -shared -fPIC -O2 -I$(LOCAL_PREFIX)/include -I$(RAYGUI_SRC) \
		$(RAYGUI_SRC)/raygui_impl.c -o $(RAYGUI_SO) -L$(LOCAL_PREFIX)/lib -lraylib

# Optimized build. `--debug` is kept on purpose: it only costs binary size, and
# without symbols a core dump is addresses with no names (addr2line/gdb get
# nothing), which is exactly what we needed the last time this app segfaulted.
release:
	@mkdir -p bin
	crystal build --release --debug src/main.cr -o $(BIN)

# Smallest binary, no symbols. Cores from this build are not readable.
release-tiny:
	@mkdir -p bin
	crystal build --release --no-debug src/main.cr -o $(BIN)

run: build
	./$(BIN)

test:
	crystal spec

clean:
	rm -rf bin .crystal
