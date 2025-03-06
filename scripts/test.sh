#!/usr/bin/env bash

set -eu

ROOT=${0%/*}/..

cd $ROOT

if perl -v >/dev/null 2>/dev/null; then
    RESET=`perl -e 'print("\e[0m")'`
    BOLD=`perl -e 'print("\e[1m")'`
    YELLOW=`perl -e 'print("\e[33m")'`
    BLUE_BG=`perl -e 'print("\e[44m")'`
elif python -V >/dev/null 2>/dev/null; then
    RESET=`echo 'import sys; sys.stdout.write("\033[0m")' | python`
    BOLD=`echo 'import sys; sys.stdout.write("\033[1m")' | python`
    YELLOW=`echo 'import sys; sys.stdout.write("\033[33m")' | python`
    BLUE_BG=`echo 'import sys; sys.stdout.write("\033[44m")' | python`
else
    RESET=
    BOLD=
    YELLOW=
    BLUE_BG=
fi

function header()
{
    local title="$1"
    echo "${BLUE_BG}${YELLOW}${BOLD}${title}${RESET}"
    echo "------------------------------------------"
    sleep 1
}

cat <<HEREDOC > Procfile
app1: sh ${ROOT}/scripts/foo.sh
app2: sh ${ROOT}/scripts/foo.sh
app3: sh ${ROOT}/scripts/foo.sh
HEREDOC

cat <<'HEREDOC' > Procfile.local
app_name: test
pid_root: new_pids
env:
  foo: foo

processes:
  app1:
    allocate_port_from: 28128
  app2:
    allocate_port_from: 28320
  app3:
    allocate_port_from: 28502
HEREDOC

header 'Running spec'
crystal spec
header 'Building ...'
header "Make sure print \`(15) Successful' to pass the test."
which shards && [ -f shard.yml ] && shards build
bin/procodile
bin/procodile kill && sleep 3  # ensure kill before test.
header '(1) Checking procodile start ...'
bin/procodile start && sleep 3
bin/procodile -r spec/apps/basic/ start && sleep 3
header '(2) Checking procodile status --simple ...'
bin/procodile status --simple |grep '^OK || app1\[1\], app2\[1\], app3\[1\]$'
header '(2.1) Checking PORT envs'
bin/procodile status |grep 'app1\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28128'
bin/procodile status |grep 'app2\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28320'
bin/procodile status |grep 'app3\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28502'
[ -s new_pids/procodile.pid ]
header '(3) Checking procodile restart when started ...'
bin/procodile restart && sleep 3
bin/procodile status --simple |grep '^OK || app1\[1\], app2\[1\], app3\[1\]$'
header '(4) Checking procodile stop -papp1,app2 ...'
bin/procodile stop -papp1,app2 && sleep 3
bin/procodile status --simple |grep '^Issues || app1 has 0 instances (should have 1), app2 has 0 instances (should have 1)$'
header '(5) Checking procodile stop ...'
bin/procodile stop && sleep 3
bin/procodile status --simple |grep '^Issues || app1 has 0 instances (should have 1), app2 has 0 instances (should have 1), app3 has 0 instances (should have 1)$'
header '(5.1) Checking procodile start when stopped ...'
bin/procodile start && sleep 3
bin/procodile status --simple |grep '^OK || app1\[1\], app2\[1\], app3\[1\]$'
header '(5.2) Checking procodile stop when started ...'
bin/procodile stop && sleep 3
bin/procodile status --simple |grep '^Issues || app1 has 0 instances (should have 1), app2 has 0 instances (should have 1), app3 has 0 instances (should have 1)$'
header '(6) Checking procodile restart when stopped ...'
bin/procodile restart && sleep 3
bin/procodile status --simple |grep '^OK || app1\[1\], app2\[1\], app3\[1\]$'
header '(7) Checking procodile status ...'
bin/procodile status

header '(8) Change Procfile.local to set quantity of app1 from 1 to 2 ...'

cat <<'HEREDOC' > Procfile.local
app_name: test
pid_root: new_pids
env:
  foo: foo

processes:
  app1:
    allocate_port_from: 28128
    quantity: 2
  app2:
    allocate_port_from: 28320
  app3:
    allocate_port_from: 28502
HEREDOC

header '(9) Checking procodile check_concurrency ...'
bin/procodile check_concurrency
bin/procodile status --simple |grep '^OK || app1\[2\], app2\[1\], app3\[1\]$'
header '(9.1) Checking PORT envs for app1'
bin/procodile status |grep 'app1\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28128'
bin/procodile status |grep 'app1\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28129'
header '(10) Checking procodile log ...'
bin/procodile log

header '(11) Change Procfile to set app3 lunch bar.sh instead of foo.sh'

cat <<HEREDOC > Procfile
app1: sh ${ROOT}/scripts/foo.sh
app2: sh ${ROOT}/scripts/foo.sh
app3: sh ${ROOT}/scripts/bar.sh
HEREDOC

header '(12) Checking procodile restart will failed when run app3.sh ...'
bin/procodile restart && sleep 3
header '(12.1) Checking procodile restart app3.sh Unknown status ...'
bin/procodile status |grep -F 'app3.5' |grep -F 'Unknown'

while ! bin/procodile status |grep -F 'app3.5' |grep -F 'Failed' |grep -F 'respawns:5'; do
    sleep 1
    echo 'Waiting respawns to become 5'
done

header '(12.1) Checking procodile restart app3.sh Failed status ...'
bin/procodile status |grep -F 'app3.5' |grep -F 'Failed'

header '(13) Change Procfile to set correct env for app3.sh'

cat <<'HEREDOC' > Procfile.local
app_name: test
pid_root: new_pids
env:
  foo: foo

processes:
  app1:
    allocate_port_from: 28128
    quantity: 2
  app2:
    allocate_port_from: 28320
    quantity: 1
  app3:
    env:
      bar: bar
HEREDOC

header '(14) Checking procodile restart -papp3  ...'
bin/procodile restart -papp3 && sleep 3
bin/procodile status --simple |grep '^OK || app1\[2\], app2\[1\], app3\[1\]$'
bin/procodile kill && sleep 3
bin/procodile -r spec/apps/basic/ kill

header '(15) Successful'
