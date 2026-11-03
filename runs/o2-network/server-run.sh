#!/usr/bin/env bash
# Collect the network experiment and restore the original service on every exit.
set -euo pipefail
cd /home/ubuntu/lab2
run_dir=/home/ubuntu/lab2/runs/o2-network
mkdir -p "$run_dir"
chown ubuntu:ubuntu "$run_dir"
cp /tmp/lab2-o2-prediction.md "$run_dir/prediction.md"
date -Is > "$run_dir/started.txt"
iptables -S INPUT > "$run_dir/firewall-before.txt"
curl -fsS http://127.0.0.1:8080/config > "$run_dir/original-config.json"
old_pid=$(python3 -c 'import json; print(json.load(open("runs/o2-network/original-config.json"))["pid"])')
collectors=()
service_pid=""
changed=0

# Close the experiment listener before removing its temporary access rules.
cleanup() {
    trap - EXIT INT TERM
    if [ -n "$service_pid" ]; then
        kill -TERM "$service_pid" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$service_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
    for pid in "${collectors[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    if [ "$changed" -eq 1 ]; then
        runuser -u ubuntu -- sh -c 'cd /home/ubuntu/lab2; nohup env GOMAXPROCS=1 taskset -c 1 bin/enrolld -sync interval > runs/o2-network/enrolld-restored.log 2>&1 < /dev/null &'
        for _ in {1..50}; do
            curl -fsS http://127.0.0.1:8080/config > "$run_dir/restored-config.json" 2>/dev/null && break
            sleep 0.1
        done
    fi
    iptables -D INPUT -p tcp --dport 8080 -j LAB2_O2
    iptables -F LAB2_O2
    iptables -X LAB2_O2
    iptables -S INPUT > "$run_dir/firewall-after.txt"
    ss -ltn '( sport = :8080 )' > "$run_dir/listen-after.txt"
    date -Is > "$run_dir/completed.txt"
    chown -R ubuntu:ubuntu "$run_dir"
}

# Keep the existing firewall intact and restrict only this experiment's port.
iptables -N LAB2_O2
iptables -A LAB2_O2 -i lo -j ACCEPT
iptables -A LAB2_O2 -s 192.168.0.142/32 -j ACCEPT
iptables -A LAB2_O2 -p tcp -j REJECT --reject-with tcp-reset
iptables -I INPUT 1 -p tcp --dport 8080 -j LAB2_O2
trap cleanup EXIT INT TERM
iptables -S INPUT > "$run_dir/firewall-during.txt"
iptables -S LAB2_O2 >> "$run_dir/firewall-during.txt"
kill -TERM "$old_pid"
changed=1
for _ in {1..50}; do
    kill -0 "$old_pid" 2>/dev/null || break
    sleep 0.1
done
runuser -u ubuntu -- sh -c 'cd /home/ubuntu/lab2; nohup env GOMAXPROCS=1 taskset -c 1 bin/enrolld -addr 0.0.0.0:8080 -sync interval > runs/o2-network/enrolld.log 2>&1 < /dev/null &'
for _ in {1..50}; do
    curl -fsS http://127.0.0.1:8080/config > "$run_dir/config.json" 2>/dev/null && break
    sleep 0.1
done
service_pid=$(python3 -c 'import json; print(json.load(open("runs/o2-network/config.json"))["pid"])')
ss -ltn '( sport = :8080 )' > "$run_dir/listen-during.txt"
export LC_ALL=C S_TIME_FORMAT=ISO
sar -n DEV,EDEV,TCP,ETCP 1 > "$run_dir/sar.log" & collectors+=($!)
mpstat -P ALL 1 > "$run_dir/mpstat.log" & collectors+=($!)
pidstat -h -u -r -w -p "$service_pid" 1 > "$run_dir/pidstat.log" & collectors+=($!)
(
    while true; do
        date -Is
        ss -tin '( sport = :8080 and dst 192.168.0.142 )'
        sleep 3
    done
) > "$run_dir/ss.log" & collectors+=($!)
curl -fsS http://127.0.0.1:8080/metrics > "$run_dir/metrics-start.txt"
touch "$run_dir/READY"
# Limit the listener lifetime even if the controlling SSH connection fails.
for _ in {1..1200}; do
    [ ! -f "$run_dir/DONE" ] || break
    sleep 1
done
curl -fsS http://127.0.0.1:8080/metrics > "$run_dir/metrics-end.txt"
