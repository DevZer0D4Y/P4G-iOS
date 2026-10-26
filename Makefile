# Persona 4 Golden recomp: the Mac build (bring-up and debugging) and the game code generation.
# The iOS app is built by ios/build.sh, from the same runtime and the same generated code.
#
#   make gen GAME=<folder with exefs/ and romfs/>   lift the game's code to C (in $(GEN))
#   make -j2                                         the Mac runtime and the game code library
#   build/p4g <game folder>                          run it
#
# Nothing from the game is in this repository: $(GEN) and build/ are made from the player's own files.

# local.mk (not in git) can set your own GAME / GEN / PY
-include local.mk
GAME    ?= work
GEN     ?= $(HOME)/P4G-iOS/gen-mac
B       ?= build
PY      ?= python3 -E -s

# Guest layout (runtime/rt.h): the generated code has the module bases built in, so each platform has its own $(GEN)
MAC_BASE := 0x7000000000
IOS_BASE := 0x7000000000
SDK_OFF  := 0x20000000

CC       := clang
CXX      := clang++
SDL      := /opt/homebrew/opt/sdl3
FFMPEG   := /opt/homebrew/opt/ffmpeg
GENFLAGS := -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -fvisibility=hidden -Iruntime
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime -Iruntime/nvn -I$(SDL)/include -I$(FFMPEG)/include
LDFLAGS  := -L$(SDL)/lib -lSDL3 -Wl,-rpath,$(SDL)/lib -L$(FFMPEG)/lib -lavformat -lavcodec -lavutil -lswscale \
            -Wl,-rpath,$(FFMPEG)/lib -framework CoreFoundation -framework Foundation -framework Metal -framework MetalFX \
            -framework QuartzCore -framework AppKit -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers

RT_SRC   := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c) runtime/platform/macos.c
RT_M     := $(wildcard runtime/nvn/*.m) $(wildcard runtime/ui/*.m)
RT_HDRS  := $(wildcard runtime/*.h runtime/*/*.h runtime/nvn/maxwell/*.h)
RT_OBJ   := $(patsubst runtime/%.c,$(B)/rt/%.o,$(RT_SRC)) $(patsubst runtime/%.m,$(B)/rt/%.o,$(RT_M))

GEN_SRC  := $(strip $(wildcard $(GEN)/main/*.c) $(wildcard $(GEN)/sdk/*.c))
GEN_OBJ  := $(patsubst $(GEN)/%.c,$(B)/obj/%.o,$(GEN_SRC)) $(B)/obj/gamelib_entry.o
GAMELIB_ID := $(shell cat tools/gen.py tools/lifter.py tools/analyze.py tools/nso.py tools/passes.py tools/simd_c.py \
                tools/patches_p4g.py tools/builds.py runtime/cpu.h runtime/simd.h runtime/simd_fp.h runtime/gamelib.h \
                | shasum -a 256 | cut -c1-16)
GAMELIB_BUILD := $(shell cut -c1-16 $(GEN)/main/main_build_id.txt 2>/dev/null)

EXE      := $(B)/p4g
GAMELIB  := $(B)/p4ggame.dylib

all: $(EXE) $(if $(GEN_SRC),$(GAMELIB))

$(B)/rt/%.o: runtime/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

$(B)/rt/%.o: runtime/%.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@

$(B)/rt/gamelib.o: RTFLAGS += -DGAMELIB_ID='"$(GAMELIB_ID)"'

$(EXE): $(RT_OBJ)
	$(CC) -o $@.tmp $^ $(LDFLAGS)
	mv -f $@.tmp $@

$(B)/obj/%.o: $(GEN)/%.c runtime/cpu.h runtime/simd.h runtime/simd_fp.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

$(B)/obj/gamelib_entry.o: tools/gamelib_entry.c runtime/gamelib.h $(wildcard $(GEN)/main/main_build_id.txt)
	@mkdir -p $(dir $@)
	$(CC) $(GENFLAGS) -DGAMELIB_ID='"$(GAMELIB_ID)-$(GAMELIB_BUILD)"' -c $< -o $@

$(GAMELIB): $(GEN_OBJ) | $(EXE)
	$(CC) -dynamiclib -undefined dynamic_lookup -o $@.tmp $^
	mv -f $@.tmp $@
	echo "$(GAMELIB_ID)-$(GAMELIB_BUILD)" > $@.id

# gen: GEN=<dir> BASE=<guest base> (the Mac's by default; ios/build.sh runs it with IOS_BASE into its own folder)
BASE ?= $(MAC_BASE)
gen:
	cd tools && $(PY) gen.py sdk $(GAME)/exefs/sdk $$(printf '0x%x' $$(( $(BASE) + $(SDK_OFF) ))) $(GEN)/sdk \
	    --hle ../runtime/hle/hle_symbols.txt
	cd tools && $(PY) gen.py main $(GAME)/exefs/main $(BASE) $(GEN)/main

runtime-objs: $(RT_OBJ)

clean:
	rm -rf $(B)

.PHONY: all gen runtime-objs clean

# SMAA (third_party/smaa, MIT): the reference shader as a C string for runtime/nvn/smaa_data.c
$(B)/inc/smaa_hlsl.inc: third_party/smaa/SMAA.hlsl
	@mkdir -p $(dir $@)
	LC_ALL=C tr -d '\r' < $< | LC_ALL=C tr '\200-\377' '?' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/' > $@
$(B)/rt/nvn/smaa_data.o: $(B)/inc/smaa_hlsl.inc
$(B)/rt/nvn/smaa_data.o: RTFLAGS += -I$(B)/inc -Ithird_party/smaa/Textures

# The shader preparation's variant list as a C string for runtime/nvn/shader_prep.c
$(B)/inc/shader_variants.inc: runtime/nvn/shader_variants.txt
	@mkdir -p $(dir $@)
	(LC_ALL=C tr -d '\r' < $< | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/'; echo '""') > $@
TRANSLATOR_ID := $(shell cat runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h | shasum -a 256 | cut -c1-12)
$(B)/rt/nvn/shader_prep.o: $(B)/inc/shader_variants.inc runtime/nvn/maxwell/translate.c
$(B)/rt/nvn/shader_prep.o: RTFLAGS += -I$(B)/inc -DSHADER_TRANSLATOR_ID='"$(TRANSLATOR_ID)"'
