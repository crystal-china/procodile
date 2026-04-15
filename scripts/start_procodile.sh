#!/usr/bin/env bash
set -eu

# 这个脚本的目的是，测试：当运行这个脚本，并且 sleep attached 到终端上时，
# 按下 Ctrl + C 会不会让 supervisor 也挂掉。

ROOT="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && builtin pwd -P)"

cd $ROOT/..

bin/procodile kill || true
bin/procodile start
sleep 1000
