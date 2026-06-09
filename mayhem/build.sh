#!/usr/bin/env bash
#
# selinux/mayhem/build.sh — build the OSS-Fuzz libFuzzer harnesses for libsepol & libselinux,
# with the FUZZED libraries themselves instrumented by $SANITIZER_FLAGS (ASan+UBSan, halting by
# default) so Mayhem finds memory AND undefined-behaviour defects in selinux's own code, not just
# the harness. Each harness is linked twice: once with $LIB_FUZZING_ENGINE (the libFuzzer binary)
# and once with $STANDALONE_FUZZ_MAIN (a non-fuzzer run-once reproducer, /mayhem/<t>-standalone).
#
# Five harnesses (mirrors scripts/oss-fuzz.sh):
#   secilc-fuzzer              libsepol  (CIL compiler)
#   binpolicy-fuzzer           libsepol  (binary policy reader)
#   checkpolicy-fuzzer         libsepol + checkpolicy parser objects
#   selabel_file_text-fuzzer   libselinux (PCRE2)
#   selabel_file_compiled-fuzzer libselinux (PCRE2)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV (overridable). SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# --build-arg SANITIZER_FLAGS= builds with NO sanitizers (natural crash); the others use `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

DESTDIR="$SRC/DESTDIR"
export DESTDIR

# Instrument the fuzzed libraries with $SANITIZER_FLAGS. fuzzer-no-link lets the libs compile with
# the fuzzer instrumentation while we link the libFuzzer/standalone main into each harness below.
# FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION gates the fuzz entry points in the harness sources.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
export CFLAGS="$FUZZ_CFLAGS -I$DESTDIR/usr/include -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64"
export CXXFLAGS="$FUZZ_CFLAGS"

rm -rf "$DESTDIR"
make -C libsepol clean
make -C libselinux/src clean
make -C libselinux/include clean

# libsepol: build + install the sanitized static lib + headers into DESTDIR.
# LIBSO/LIBMAP are expanded inside the Makefile, hence single-quoted.
# shellcheck disable=SC2016
make -C libsepol V=1 LD_SONAME_FLAGS='-soname,$(LIBSO),--version-script=$(LIBMAP)' -j"$MAYHEM_JOBS" install

# libselinux: build ONLY the sanitized static lib (src) + install its headers. We deliberately do
# NOT run libselinux's full `install` — that also builds utils/, which links the libselinux SHARED
# object (-lsepol) we don't produce here, and is irrelevant to the fuzz harnesses. Building src
# directly bypasses the top libselinux/Makefile's PCRE detection, so pass the PCRE2 flags ourselves
# (otherwise src defaults to PCRE1 and fails on <pcre.h>).
PCRE_CFLAGS="-DUSE_PCRE2 -DPCRE2_CODE_UNIT_WIDTH=8 $(pkg-config --cflags libpcre2-8)"
PCRE_LDLIBS="$(pkg-config --libs libpcre2-8)"
# shellcheck disable=SC2016
make -C libselinux/src V=1 -j"$MAYHEM_JOBS" \
     PCRE_CFLAGS="$PCRE_CFLAGS" PCRE_LDLIBS="$PCRE_LDLIBS" libselinux.a
make -C libselinux/include install

# Helper: link one C libFuzzer harness as both the fuzzer binary and the standalone reproducer.
# C harnesses, so the standalone driver ($STANDALONE_FUZZ_MAIN, C) links directly with $CC.
#   build_target <name> <harness.c> <extra-cflags> <libs...>
build_target() {
  local name="$1" src="$2" extra="$3"; shift 3
  # shellcheck disable=SC2086
  $CC $CFLAGS $extra -c -o "/tmp/$name.o" "$src"
  # shellcheck disable=SC2086
  $CXX $CXXFLAGS $LIB_FUZZING_ENGINE "/tmp/$name.o" "$@" -o "/mayhem/$name"
  # shellcheck disable=SC2086
  $CC $CFLAGS $extra -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
  # shellcheck disable=SC2086
  $CXX $CXXFLAGS /tmp/standalone_main.o "/tmp/$name.o" "$@" -o "/mayhem/$name-standalone"
}

LIBSEPOL_A="$DESTDIR/usr/lib/libsepol.a"
LIBSELINUX_A="$SRC/libselinux/src/libselinux.a"

## secilc fuzzer (libsepol) ##
build_target secilc-fuzzer    libsepol/fuzz/secilc-fuzzer.c    "" "$LIBSEPOL_A"

## binary policy fuzzer (libsepol) ##
build_target binpolicy-fuzzer libsepol/fuzz/binpolicy-fuzzer.c "" "$LIBSEPOL_A"

## checkpolicy fuzzer (libsepol + checkpolicy parser objects) ##
make -C checkpolicy clean
make -C checkpolicy V=1 -j"$MAYHEM_JOBS" checkobjects
build_target checkpolicy-fuzzer checkpolicy/fuzz/checkpolicy-fuzzer.c "-Icheckpolicy/" checkpolicy/*.o "$LIBSEPOL_A"

## selabel-file text fcontext fuzzer (libselinux, PCRE2) ##
build_target selabel_file_text-fuzzer     libselinux/fuzz/selabel_file_text-fuzzer.c     "-DUSE_PCRE2 -DPCRE2_CODE_UNIT_WIDTH=8" "$LIBSELINUX_A" "$LIBSEPOL_A" -lpcre2-8
build_target selabel_file_compiled-fuzzer libselinux/fuzz/selabel_file_compiled-fuzzer.c "-DUSE_PCRE2 -DPCRE2_CODE_UNIT_WIDTH=8" "$LIBSELINUX_A" "$LIBSEPOL_A" -lpcre2-8

echo "built: secilc-fuzzer binpolicy-fuzzer checkpolicy-fuzzer selabel_file_text-fuzzer selabel_file_compiled-fuzzer (+ -standalone)"

# ---------------------------------------------------------------------------------------------------
# libsepol CUnit functional suite (PATCH-grade oracle for mayhem/test.sh)
# ---------------------------------------------------------------------------------------------------
# libsepol/tests builds `libsepol-tests`, which links the STATIC libsepol (../src/libsepol.a) and the
# checkpolicy parser objects (../../checkpolicy/*.o) so it can load source policies, plus -lcunit
# (libcunit1-dev, installed in mayhem/Dockerfile). Its `test:` recipe also runs ../../checkpolicy/
# checkpolicy to pre-generate the downgrade test policy. mayhem/test.sh only RUNS the binary, so we
# build EVERYTHING it needs here — as a SEPARATE CLEAN build with the project's NORMAL flags (NOT the
# fuzz sanitizer/libFuzzer flags) so the suite stays an honest oracle and won't false-fail on benign
# UB. This rebuilds the in-tree libsepol.a + checkpolicy objects (the fuzz harnesses above are already
# linked and saved under /mayhem, so clobbering the in-tree build artifacts now is safe).
echo "building libsepol CUnit test suite (libsepol-tests, normal flags) ..."

# Normal flags: drop SANITIZER_FLAGS / fuzzer instrumentation. Let the Makefiles use their own CFLAGS;
# we only clear the env CFLAGS/CXXFLAGS the fuzz build exported so they don't leak the fuzzer flags in.
unset CFLAGS CXXFLAGS

make -C libsepol clean
make -C checkpolicy clean
make -C libsepol/tests clean

# Clean NORMAL-flags libsepol static lib (in-tree ../src/libsepol.a, where the tests expect it).
# shellcheck disable=SC2016
make -C libsepol V=1 LD_SONAME_FLAGS='-soname,$(LIBSO),--version-script=$(LIBMAP)' -j"$MAYHEM_JOBS"

TEST_LIBSEPOL_A="$SRC/libsepol/src/libsepol.a"

# checkpolicy: the tests link its parser objects (checkobjects) and the `test:` recipe runs the
# checkpolicy binary. Build both explicitly (not `all`, which recurses into checkpolicy/test). Point
# it at the just-built static libsepol so the binary links without the system libsepol, and at the
# in-tree libsepol headers (we install no DESTDIR for this normal build, so pass -I libsepol/include).
make -C checkpolicy V=1 -j"$MAYHEM_JOBS" \
     LIBSEPOLA="$TEST_LIBSEPOL_A" CPPFLAGS="-I$SRC/libsepol/include" \
     checkobjects checkpolicy

# Build the test binary + generate the m4 test policies (everything in the `test:` recipe except the
# final `./libsepol-tests` run, which mayhem/test.sh performs). Generate the downgrade policy.hi the
# same way the Makefile's `test:` target does, so test.sh can just execute the binary.
make -C libsepol/tests V=1 -j"$MAYHEM_JOBS" libsepol-tests policies
env -i mkdir -p libsepol/tests/policies/test-downgrade
checkpolicy/checkpolicy -M libsepol/tests/policies/test-cond/refpolicy-base.conf \
    -o libsepol/tests/policies/test-downgrade/policy.hi

echo "built: libsepol/tests/libsepol-tests (CUnit, normal flags)"
