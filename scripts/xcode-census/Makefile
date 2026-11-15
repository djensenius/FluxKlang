# Hosted only until independent source review authorizes execution.
# Fixed local build directory, no clean target and no caller-supplied recipes.
override CC := /Applications/Xcode_27.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
override SDK := $(shell /usr/bin/xcrun --sdk macosx --show-sdk-path)
override CFLAGS := -std=c11 -D_DARWIN_C_SOURCE -arch arm64 -isysroot "$(SDK)" \
	-mmacosx-version-min=14.0 -O2 -Wall -Wextra -Werror -Wpedantic \
	-Wconversion -Wsign-conversion -Wshadow -Wstrict-prototypes \
	-Wmissing-prototypes -Wformat=2 -fstack-protector-strong
override LDFLAGS := -Wl,-fatal_warnings

.PHONY: all check
all: build/xcode-census

build:
	mkdir build

build/xcode-census: census.c census.h main.c | build
	$(CC) $(CFLAGS) census.c main.c $(LDFLAGS) -o $@

build/test-census: census.c census.h test_census.c | build
	$(CC) $(CFLAGS) -DXC_FIXTURE census.c test_census.c $(LDFLAGS) -o $@

check: build/test-census
	./build/test-census
