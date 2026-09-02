#!/bin/bash
# Builds the real login helper with AddressSanitizer and drives its normal exec path with a custom
# argv[0]. A one-byte allocation mistake here corrupts memory on every terminal launch.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

clang -g -fsanitize=address -fno-omit-frame-pointer \
	NewTermLoginHelper/main.c -o "$WORK/NewTermLoginHelper"

cat > "$WORK/launch.c" <<'C'
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc != 3) {
		return 2;
	}
	char *helper_argv[] = {
		"-NewTermLoginHelper",
		argv[2],
		"/bin/sh",
		"-c",
		"exit 0",
		NULL
	};
	execv(argv[1], helper_argv);
	perror("execv");
	return 1;
}
C

clang "$WORK/launch.c" -o "$WORK/launch"
ASAN_OPTIONS=abort_on_error=1 "$WORK/launch" "$WORK/NewTermLoginHelper" "$WORK"
echo ok
