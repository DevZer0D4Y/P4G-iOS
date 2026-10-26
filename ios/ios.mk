# The iOS app's compile and link (ios/build.sh runs it; make -f ios/ios.mk from the repository root).
#   GEN   the game code generated at the iOS guest base (ios/build.sh: make gen BASE=0x7000000000 GEN=...)
#   DEPS  SDL3 and FFmpeg built for iOS (include/, lib/)
#   B     build folder
GEN  ?= $(HOME)/P4G-iOS/gen-ios
DEPS ?= $(HOME)/P4G-iOS/deps-ios
B    ?= $(HOME)/P4G-iOS/build-ios

SDK      := $(shell xcrun -sdk iphoneos --show-sdk-path)
CC       := $(shell xcrun -sdk iphoneos -f clang)
TARGET   := -target arm64-apple-ios16.0 -isysroot $(SDK)
GENFLAGS := $(TARGET) -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -fvisibility=hidden -Iruntime
# -fdebug-prefix-map / -ffile-prefix-map: no build machine paths in the binary (asserts and logs keep source names)
PREFIX   := -ffile-prefix-map=$(CURDIR)/=  -ffile-prefix-map=$(HOME)/=~/
RTFLAGS  := $(TARGET) -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Wno-unused-variable \
            -Wno-unused-but-set-variable -Wno-deprecated-declarations -Wno-format -DGAMELIB_STATIC \
            -Iruntime -Iruntime/nvn -I$(DEPS)/include -I$(B)/inc -Ithird_party/smaa/Textures $(PREFIX)
FRAMEWORKS := UIKit Foundation CoreFoundation Metal MetalFX QuartzCore CoreGraphics CoreText ImageIO GameController AVFoundation \
              AudioToolbox CoreAudio CoreHaptics CoreMotion CoreBluetooth UniformTypeIdentifiers CoreVideo CoreMedia \
              VideoToolbox Security
LDFLAGS  := $(TARGET) -L$(DEPS)/lib -lSDL3 -lavformat -lavcodec -lswscale -lavutil -lc++ -liconv \
            $(addprefix -framework ,$(FRAMEWORKS))

RT_SRC   := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c) runtime/platform/macos.c
RT_M     := $(wildcard runtime/nvn/*.m) $(wildcard ios/src/*.m)
RT_HDRS  := $(wildcard runtime/*.h runtime/*/*.h runtime/nvn/maxwell/*.h ios/src/*.h)
RT_OBJ   := $(patsubst %.c,$(B)/rt/%.o,$(RT_SRC)) $(patsubst %.m,$(B)/rt/%.o,$(RT_M))
GEN_SRC  := $(wildcard $(GEN)/main/*.c) $(wildcard $(GEN)/sdk/*.c)
GEN_OBJ  := $(patsubst $(GEN)/%.c,$(B)/game/%.o,$(GEN_SRC)) $(B)/game/gamelib_entry.o

GAMELIB_ID    := $(shell cat tools/gen.py tools/lifter.py tools/analyze.py tools/nso.py tools/passes.py tools/simd_c.py \
                   tools/patches_p4g.py tools/builds.py runtime/cpu.h runtime/simd.h runtime/simd_fp.h runtime/gamelib.h \
                   | shasum -a 256 | cut -c1-16)
GAMELIB_BUILD := $(shell cut -c1-16 $(GEN)/main/main_build_id.txt 2>/dev/null)
TRANSLATOR_ID := $(shell cat runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h | shasum -a 256 | cut -c1-12)

EXE := $(B)/P4G

all: $(EXE)

$(B)/rt/%.o: %.c $(RT_HDRS) | $(B)/inc/smaa_hlsl.inc $(B)/inc/shader_variants.inc
	@mkdir -p $(dir $@)
	@$(CC) $(RTFLAGS) -c $< -o $@ && echo "cc $<"

$(B)/rt/%.o: %.m $(RT_HDRS) | $(B)/inc/smaa_hlsl.inc
	@mkdir -p $(dir $@)
	@$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@ && echo "cc $<"

$(B)/rt/runtime/nvn/shader_prep.o: RTFLAGS += -DSHADER_TRANSLATOR_ID='"$(TRANSLATOR_ID)"'
$(B)/rt/runtime/gamelib.o: RTFLAGS += -DGAMELIB_ID='"$(GAMELIB_ID)"'

$(B)/game/%.o: $(GEN)/%.c runtime/cpu.h runtime/simd.h runtime/simd_fp.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@ && echo "game $(notdir $<)"

$(B)/game/gamelib_entry.o: tools/gamelib_entry.c runtime/gamelib.h $(wildcard $(GEN)/main/main_build_id.txt)
	@mkdir -p $(dir $@)
	$(CC) $(GENFLAGS) -DGAMELIB_ID='"$(GAMELIB_ID)-$(GAMELIB_BUILD)"' -c $< -o $@

$(EXE): $(RT_OBJ) $(GEN_OBJ)
	$(CC) -o $@ $^ $(LDFLAGS)

$(B)/inc/smaa_hlsl.inc: third_party/smaa/SMAA.hlsl
	@mkdir -p $(dir $@)
	LC_ALL=C tr -d '\r' < $< | LC_ALL=C tr '\200-\377' '?' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/' > $@

$(B)/inc/shader_variants.inc: runtime/nvn/shader_variants.txt
	@mkdir -p $(dir $@)
	(LC_ALL=C tr -d '\r' < $< | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/'; echo '""') > $@

.PHONY: all
