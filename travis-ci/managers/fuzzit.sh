#!/bin/bash

set -e
set -x
set -u

# This should help to protect the systemd organization on Fuzzit from forks
# that are activated on Travis CI.
[[ "$TRAVIS_REPO_SLUG" = "systemd/systemd" ]] || exit 0

REPO_ROOT=${REPO_ROOT:-$(pwd)}

sudo bash -c "echo 'deb-src http://archive.ubuntu.com/ubuntu/ xenial main restricted universe multiverse' >>/etc/apt/sources.list"
sudo apt-get update -y
sudo apt-get build-dep systemd -y
sudo apt-get install -y python3-pip python3-setuptools
# The following should be dropped when debian packaging has been updated to include them
sudo apt-get install -y libfdisk-dev libp11-kit-dev libssl-dev libpwquality-dev
pip3 install ninja meson

cd $REPO_ROOT
export PATH="$HOME/.local/bin/:$PATH"

# TODO: figure out what to do about unsigned-integer-overflow: https://github.com/google/oss-fuzz/issues/910
export SANITIZER="address -fsanitize=undefined,unsigned-integer-overflow"
tools/oss-fuzz.sh

FUZZING_TYPE=${1:-regression}
if [ "$TRAVIS_PULL_REQUEST" = "false" ]; then
    FUZZIT_BRANCH="${TRAVIS_BRANCH}"
else
    FUZZIT_BRANCH="PR-${TRAVIS_PULL_REQUEST}"
fi

# Because we want Fuzzit to run on every pull-request and Travis/Azure doesn't support encrypted keys
# on pull-request we use a write-only key which is ok for now. maybe there will be a better solution in the future
export FUZZIT_API_KEY=af6992074353998676713818cc6435ef4a750439932dab58b51e9354d6742c54d740a3cd9fc1fc001db82f51734a24bc
FUZZIT_ADDITIONAL_FILES="./out/src/shared/libsystemd-shared-*.so"

# ASan options are borrowed almost verbatim from OSS-Fuzz
ASAN_OPTIONS=redzone=32:print_summary=1:handle_sigill=1:allocator_release_to_os_interval_ms=500:print_suppressions=0:strict_memcmp=1:allow_user_segv_handler=0:allocator_may_return_null=1:use_sigaltstack=1:handle_sigfpe=1:handle_sigbus=1:detect_stack_use_after_return=1:alloc_dealloc_mismatch=0:detect_leaks=1:print_scariness=1:max_uar_stack_size_log=16:handle_abort=1:check_malloc_usable_size=0:quarantine_size_mb=64:detect_odr_violation=0:handle_segv=1:fast_unwind_on_fatal=0
UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1:silence_unsigned_overflow=1
FUZZIT_ARGS="--type ${FUZZING_TYPE} --branch ${FUZZIT_BRANCH} --revision ${TRAVIS_COMMIT} -e ASAN_OPTIONS=${ASAN_OPTIONS} -e UBSAN_OPTIONS=${UBSAN_OPTIONS}"
wget -O fuzzit https://github.com/fuzzitdev/fuzzit/releases/latest/download/fuzzit_Linux_x86_64
chmod +x fuzzit

# Simple wrapper which retries given command up to three times if it fails
_retry() {
    local EC=1

    for _ in {0..2}; do
        if "$@"; then
            EC=0
            break
        fi

        sleep 1
    done

    return $EC
}

find out/ -maxdepth 1 -name 'fuzz-*' -executable -type f -exec basename '{}' \; | while read -r fuzzer; do
    _retry ./fuzzit create job ${FUZZIT_ARGS} ${fuzzer}-asan-ubsan out/${fuzzer} ${FUZZIT_ADDITIONAL_FILES}
done

export SANITIZER="memory -fsanitize-memory-track-origins"
FUZZIT_ARGS="--type ${FUZZING_TYPE} --branch ${FUZZIT_BRANCH} --revision ${TRAVIS_COMMIT}"
tools/oss-fuzz.sh

find out/ -maxdepth 1 -name 'fuzz-*' -executable -type f -exec basename '{}' \; | while read -r fuzzer; do
    _retry ./fuzzit create job ${FUZZIT_ARGS} ${fuzzer}-msan out/${fuzzer} ${FUZZIT_ADDITIONAL_FILES}
done
