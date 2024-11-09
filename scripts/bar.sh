#!/usr/bin/env bash

set -eu

while true; do
    echo "$(date) - Hello, World!" 1>&2
    echo $foo
    echo $bar
    echo $PORT
    sleep 1
done
