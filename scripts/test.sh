#!/usr/bin/env bash

set -eu

shards build &&
    bin/procodile &&
    bin/procodile help &&
    echo 'Checking procodile start ...' &&
(bin/procodile start; sleep 3) &&
    echo 'Checking procodile status ...' &&
    (bin/procodile status; sleep 1) &&
    echo 'Checking procodile stop ...' &&
    (bin/procodile stop; sleep 3) &&
    (bin/procodile start; sleep 3) &&
    echo 'Checking procodile restart when start ...' &&
    (bin/procodile restart; sleep 3) &&
    (bin/procodile stop; sleep 3) &&
    echo 'Checking procodile restart when stop ...' &&
    (bin/procodile restart; sleep 3) &&
    echo 'Checking procodile check_concurrency ...' &&
    bin/procodile check_concurrency &&
    echo 'Checking procodile log ...' &&
    bin/procodile log &&
    echo 'Checking procodile reload ...' &&
    bin/procodile reload &&
    echo 'Checking procodile kill ...' &&
    bin/procodile kill
