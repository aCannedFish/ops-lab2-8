#!/usr/bin/env bash
# Measure CPU and request deltas around the same 20-second profile capture.
set -euo pipefail
cd /home/ubuntu/lab2
export PATH=/home/ubuntu/apps/go/bin:$PATH
GEN_CPUS=0 SLO=0.05 scripts/run.sh r1-profile-window -url http://127.0.0.1:8080/api/courses/1 -rates 307 -step 40s -seed 1 > /tmp/lab2-profile-window.log 2>&1 &
runner=$!
sleep 10
date -Is > runs/r1-profile-window/profile-start-time.txt
curl -fsS http://127.0.0.1:8080/metrics > runs/r1-profile-window/profile-start.txt
curl -fsS 'http://127.0.0.1:8080/debug/pprof/profile?seconds=20' > runs/r1-profile-window/profile.pb.gz
curl -fsS http://127.0.0.1:8080/metrics > runs/r1-profile-window/profile-end.txt
date -Is > runs/r1-profile-window/profile-end-time.txt
wait "$runner"
go tool pprof -top -nodecount=15 bin/enrolld runs/r1-profile-window/profile.pb.gz > runs/r1-profile-window/pprof-top.txt
