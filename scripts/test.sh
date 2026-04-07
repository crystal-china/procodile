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

function init_procfile () {
    mkdir -p pids/new_pids

    cat <<HEREDOC > $ROOT/Procfile
app1: bash ${ROOT}/scripts/foo.sh
app2: bash ${ROOT}/scripts/foo.sh
app3: bash ${ROOT}/scripts/foo.sh
app4__at__*/10 * * * * *: sh scripts/../scripts/cron.sh
app5__at__*/20 * * * **: sh scripts/../scripts/cron.sh
app6: scripts/../scripts/baz1.sh
HEREDOC

    cat <<'HEREDOC' > Procfile.local
app_name: test
pid_root: pids/new_pids
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
}

trap init_procfile INT TERM EXIT

function header()
{
    local title="$1"
    echo "${BLUE_BG}${YELLOW}${BOLD}${title}${RESET}"
    echo "------------------------------------------"
    sleep 1
}

function waiting() {
    local command=$1

    while ! eval "$command"; do
        sleep 1
        echo 'Waiting ...'
    done
}

init_procfile

header 'Running spec'
crystal spec --order=random --error-on-warnings
header 'Building ...'
which shards && [ -f shard.yml ] && shards build
header "Make sure print \`(15) Successful' to pass the test."
bin/procodile
bin/procodile kill && sleep 3  # ensure kill before test.
while ! bin/procodile status --simple |grep -qs "NotRunning || Procodile supervisor isn't running"; do
    sleep 1
    echo 'Waiting kill previous running'
done
bin/procodile -r spec/apps/http kill && sleep 3
while ! bin/procodile -r spec/apps/http status --simple |grep -qs "NotRunning || Procodile supervisor isn't running"; do
    sleep 1
    echo 'Waiting kill previous running'
done
header '(1) Checking procodile start ...'
bin/procodile start && sleep 3
header '(1.1) Checking procodile -r spec/apps/http/ start ...'
bin/procodile -r spec/apps/http start --proxy -e && sleep 3
header '(2) Checking procodile status --simple ...'
waiting "bin/procodile status --simple |grep -F 'OK || app1[1], app2[1], app3[1], app4[1], app5[0], app6[0]'"
bin/procodile status |grep 'app1\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28128'
bin/procodile status |grep 'app2\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28320'
bin/procodile status |grep 'app3\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28502'
bin/procodile status |grep -F '|| app4' -A3 |grep 'Schedule' |grep -F '*/10 * * * * *'
bin/procodile status 2>&1 |grep -F "Scheduled process 'app5' has invalid cron schedule '*/20 * * * **'"
bin/procodile status 2>&1 |grep -F "Process 'app6' failed to start: Error executing process: 'scripts/../scripts/baz1.sh'"
bin/procodile status 2>&1 |grep -F "Wrap it in a shell and try again"
header '(2.1) Fix invalid cron and reload'
sed -i 's#\*\*:#\* \*:#' $ROOT/Procfile
bin/procodile reload
! bin/procodile status 2>&1 |grep -F "Scheduled process 'app5' has invalid cron schedule '*/20 * * * **'"
header '(2.2) Fix failed to start process and restart'
sed -i 's#baz1\.sh#baz\.sh#' $ROOT/Procfile
bin/procodile restart -p app6
! bin/procodile status 2>&1 |grep -F "Process 'app6' failed to start: Error executing process: 'scripts/../scripts/baz1.sh'"
while ! bin/procodile status |grep -F 'app6.2' |grep -F 'Failed' |grep -F 'respawns:5'; do
    sleep 1
    echo 'Waiting respawns to become 5'
done
bin/procodile status 2>&1 |grep 'This does not look like a long-running process'
sed -i 's#baz\.sh#baz_loop.sh#' $ROOT/Procfile
bin/procodile restart -p app6
while ! bin/procodile status --simple |grep -F 'OK || app1[1], app2[1], app3[1], app4[1], app5[1], app6[1]'; do
    sleep 1
    echo 'Waiting restart successful'
done
header '(3) check proxy'
bin/procodile -r spec/apps/http status |grep 'Address/Port' |grep '0.0.0.0:3829'
bin/procodile -r spec/apps/http status --simple |grep 'OK || http\[2\]'
curl http://127.0.0.1:3829/ping |grep "pong"
header '(4) check kill http'
bin/procodile -r spec/apps/http kill
bin/procodile -r spec/apps/http status --simple |grep "NotRunning || Procodile supervisor isn't running"
# [ -s pids/new_pids/procodile.pid ]
header '(5.1) Checking procodile stop when started ...'
bin/procodile stop && sleep 3
bin/procodile status --simple |grep -F 'Issues || app1 has 0 instances (should have 1), app2 has 0 instances (should have 1), app3 has 0 instances (should have 1)'
header '(5.2) Checking procodile start when stopped ...'
bin/procodile start && sleep 3
bin/procodile status
while ! bin/procodile status --simple |grep -F 'OK || app1[1], app2[1], app3[1], app4[1]'; do
    sleep 1
    echo 'Waiting start successful'
done
header '(5.3) Checking procodile restart successful when started ...'
bin/procodile restart && sleep 3
while ! bin/procodile status --simple |grep -F 'OK || app1[1], app2[1], app3[1], app4[1]'; do
    sleep 1
    echo 'Waiting restart successful'
done
header '(5.4) Checking procodile stop -papp1,app2 ...'
bin/procodile stop -papp1,app2 && sleep 3
bin/procodile status --simple |grep '^Issues || app1 has 0 instances (should have 1), app2 has 0 instances (should have 1)$'
header '(5.5) Checking procodile stop all after stop ...'
bin/procodile stop && sleep 3
bin/procodile status --simple |grep -F 'Issues || app1 has 0 instances (should have 1), app2 has 0 instances (should have 1), app3 has 0 instances (should have 1), app6 has 0 instances (should have 1)'
header '(5.6) Checking procodile restart when stopped ...'
bin/procodile restart && sleep 3
while ! bin/procodile status --simple |grep -F 'OK || app1[1], app2[1], app3[1], app4[1]'; do
    sleep 1
    echo 'Waiting restart successful'
done
header '(6) Check console command not set'
bin/procodile console 2>&1 |grep 'Error' || true
header '(7) Change Procfile.local to set quantity of app1 from 1 to 2, add console_command  ...'
cat <<'HEREDOC' > Procfile.local
app_name: test
pid_root: pids/new_pids
env:
  foo: foo
console_command: scripts/baz.sh
processes:
  app1:
    allocate_port_from: 28128
    quantity: 2
  app2:
    allocate_port_from: 28320
  app3:
    allocate_port_from: 28502
HEREDOC
header '(8) Check reload make console command work.'
bin/procodile reload
bin/procodile console |grep 'foo'
header '(9) Checking procodile check_concurrency ...'
bin/procodile check_concurrency
while ! bin/procodile status --simple |grep -F 'OK || app1[2], app2[1], app3[1], app4[1]'; do
    sleep 1
    echo 'Waiting change concurrency successful'
done
header '(9.1) Checking PORT envs for app1'
bin/procodile status |grep 'app1\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28128'
bin/procodile status |grep 'app1\.[0-9]*' |grep -o 'port:[0-9]*' |grep '28129'
header '(10) Checking procodile log ...'
bin/procodile log
header '(11) Checking procodile exec can know global env'
bin/procodile exec scripts/baz.sh |grep 'foo'
bin/procodile run scripts/baz.sh |grep 'foo'
header '(12) Change Procfile to set app3 lunch bar.sh instead of foo.sh'

cat <<HEREDOC > $ROOT/Procfile
app1: bash ${ROOT}/scripts/foo.sh
app2: bash ${ROOT}/scripts/foo.sh
app3: bash ${ROOT}/scripts/bar.sh
HEREDOC

header '(12.1) Checking procodile reload to see run app3.sh failed ...'
bin/procodile reload && sleep 3
header '(12.2) Checking reload command update app3 status and delete crontab ...'
bin/procodile status |grep 'app3' -A2 |grep 'Command' |grep 'bar.sh'
header '(12.3) Checking app3 status still running because process not restart ...'
bin/procodile status |grep 'app3.4' |grep 'Running'
bin/procodile restart -papp3 && sleep 3
bin/procodile status |grep -F 'app1.4' |grep -F 'Running'
bin/procodile status |grep -F 'app1.5' |grep -F 'Running'
bin/procodile status |grep -F 'app2.4' |grep -F 'Running'
bin/procodile status |grep -F 'app3.5' |grep -F 'Unknown'

while ! bin/procodile status |grep -F 'app3.5' |grep -F 'Failed' |grep -F 'respawns:5'; do
    sleep 1
    echo 'Waiting respawns to become 5'
done

header '(12.4) Checking procodile restart app3.sh Failed status ...'
bin/procodile status |grep -F 'app3.5' |grep -F 'Failed'
bin/procodile status 2>&1 |grep -F "Process 'app3' failed repeatedly and will not be respawned automatically"

header '(13) Change Procfile to set correct env for app3.sh only'

cat <<'HEREDOC' > Procfile.local
app_name: test
pid_root: pids/new_pids
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
bin/procodile status --simple |grep -F 'Issues || app6 has been removed from the Procfile but is still running'
! bin/procodile status 2>&1 |grep -F "Process 'app3' failed repeatedly and will not be respawned automatically"
bin/procodile restart && sleep 3
bin/procodile status |grep -F '|| => app6.6' |grep 'Running'
bin/procodile status --simple |grep -F 'Issues || app6 has been removed from the Procfile but is still running'
bin/procodile restart -p app6 2>&1 |grep -F "Error: Process 'app6' has been removed from the Procfile and cannot be started or restarted"
bin/procodile stop -papp6 && sleep 3
bin/procodile status --simple |grep -F 'OK || app1[2], app2[1], app3[1]'
! bin/procodile status |grep -F '* app6 has been removed from the Procfile but is still running'
bin/procodile kill && sleep 3
bin/procodile -r spec/apps/http/ kill

header '(15) Successful'
