#!/usr/bin/env bash

set -eu

echo "start cron"
sleep 0.5
echo "cron running"
count=
while echo -n '.'; sleep 0.3; do
    if [ "$count" == '11111111111111111111111111111111111111111111111111111111111111111111111111111111' ]; then
        break
    fi
    count+=1
done
echo
echo "cron quiting"
sleep 0.5
echo "cron done"
