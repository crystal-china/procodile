#!/usr/bin/env bash

set -eu

echo "start cron"
sleep 0.5
echo "cron running"

deadline=$((SECONDS + 20))

while  (( SECONDS < deadline )); do
    sleep 0.3
    echo -n '.'
done
echo
echo "cron quiting"
sleep 0.5
echo "cron done"
