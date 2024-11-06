#!/usr/bin/env bash

set -eu

while true; do
    echo "$(date) - Hello, World!" 1>&2
    echo $foo
    sleep 1
done
