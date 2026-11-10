#!/usr/bin/env bash
#
# mayhem/build.sh — builds goaccess three ways from one autoreconf'd tree (all out-of-tree under
# mayhem/build-*, which mayhem/.gitignore ignores):
#   build-tests  normal flags            -> the oracle mayhem/test.sh runs
#   build-fuzz   sanitized + SanCov      -> libFuzzer harness fuzz_parse_line (+ -standalone reproducer)
#   build-afl    sanitized, afl-clang-fast -> the goaccess and bin2c CLIs as AFL file-input targets
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem"
CONF_OPTS=(--enable-utf8 --with-openssl --with-zlib --enable-geoip=mmdb)

# The project's own build runs bin2c (to embed the HTML report assets) under the sanitizers, and
# ASan's leak check would fail it. Build-time only; the shipped binaries carry lsan_off instead.
export ASAN_OPTIONS=detect_leaks=0

autoreconf -fi

# Configure out-of-tree in $1 with the remaining args as configure args.
configure_in() {
  local d="$1"; shift
  mkdir -p "$d"
  (cd "$d" && "$SRC/configure" "${CONF_OPTS[@]}" "$@")
}
# The value of a makefile variable from the configured build dir $1.
mkvar() {
  make -s -C "$1" -f Makefile -f <(printf 'print-%%:\n\t@echo $($*)\n') "print-$2"
}

# 1) Oracle build: the project's normal flags.
configure_in "$B/build-tests" CC="$CC" CFLAGS="-O2 -g $COVERAGE_FLAGS"
make -s -C "$B/build-tests" -j"$MAYHEM_JOBS"

# Leak-sanitizer opt-out, linked into every sanitized binary.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$B/lsan_off.cc" -o "$B/lsan_off.o"

# 2) libFuzzer harness: every goaccess object except main(), compiled with SanCov.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
configure_in "$B/build-fuzz" CC="$CC" CFLAGS="$FUZZ_CFLAGS"
make -s -C "$B/build-fuzz" -j"$MAYHEM_JOBS" bin2c bin2c_LDADD="$B/lsan_off.o"
# shellcheck disable=SC2046
make -s -C "$B/build-fuzz" -j"$MAYHEM_JOBS" $(mkvar "$B/build-fuzz" BUILT_SOURCES)
# shellcheck disable=SC2046
make -s -C "$B/build-fuzz" -j"$MAYHEM_JOBS" CFLAGS="$FUZZ_CFLAGS -Dmain=goaccess_main" $(mkvar "$B/build-fuzz" goaccess_OBJECTS)
OBJS_FUZZ="$(for o in $(mkvar "$B/build-fuzz" goaccess_OBJECTS); do printf '%s ' "$B/build-fuzz/$o"; done)"
LIBS_FUZZ="$(mkvar "$B/build-fuzz" LIBS) -lz -lm -lpthread"
# shellcheck disable=SC2046
$CC $FUZZ_CFLAGS $LIB_FUZZING_ENGINE -I"$B/build-fuzz/src" -I"$SRC/src" -DHAVE_CONFIG_H \
  "$B/fuzz_parse_line.c" $OBJS_FUZZ \
  "$B/lsan_off.o" $LIBS_FUZZ -o "$SRC/fuzz_parse_line"
# shellcheck disable=SC2046
$CC $FUZZ_CFLAGS "$STANDALONE_FUZZ_MAIN" -I"$B/build-fuzz/src" -I"$SRC/src" -DHAVE_CONFIG_H \
  "$B/fuzz_parse_line.c" $OBJS_FUZZ \
  "$B/lsan_off.o" $LIBS_FUZZ -o "$SRC/fuzz_parse_line-standalone"

# 3) AFL targets: the real CLIs, built once with afl-clang-fast.
#    goaccess also links stdin_null.o (see that file): it must not block on an inherited stdin pipe.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$B/stdin_null.c" -o "$B/stdin_null.o"
configure_in "$B/build-afl" CC=afl-clang-fast CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -s -C "$B/build-afl" -j"$MAYHEM_JOBS" goaccess_LDADD="-lm $B/lsan_off.o $B/stdin_null.o" bin2c_LDADD="$B/lsan_off.o"
cp "$B/build-afl/goaccess" "$SRC/goaccess"
cp "$B/build-afl/bin2c" "$SRC/bin2c"
