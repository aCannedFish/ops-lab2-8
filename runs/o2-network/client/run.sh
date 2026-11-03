#!/usr/bin/env bash
# Capture the load generator and both network and CPU counters on host B.
set -euo pipefail
cd /home/ubuntu/lab2-o2
export LC_ALL=C S_TIME_FORMAT=ISO
sar -n DEV,EDEV,TCP,ETCP 1 > sar.log &
sar_pid=$!
mpstat -P ALL 1 > mpstat.log &
mpstat_pid=$!
trap 'kill "$sar_pid" "$mpstat_pid" 2>/dev/null || true' EXIT
curl --max-time 8 -fsS http://192.168.0.134:8080/config > config.json
date -Is > started.txt
taskset -c 0,1 ./loadgen -url 'http://192.168.0.134:8080/api/export?kb=256' -rates 100,250,400,500,700,1000,1500,2500 -step 30s -seed 1 -out steps.csv > loadgen.log 2>&1
date -Is > completed.txt
