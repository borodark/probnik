# Probnik (Erlang/BEAM Node Health Monitor)

Run:
```
iex --sname probnik@localhost --cookie secret_token -S mix scenic.run
```

## UI Overview (current layout)
1) Memory Top 5
   - Top processes by memory (MB).
2) Message Queue Top 5
   - Top processes by message_queue_len (count).
3) Scheduler Pressure
   - Tape-style gauge showing combined pressure:
     - avg scheduler utilization (wall-time)
     - normalized run-queue pressure
   - Run-queue stats printed inside the gauge:
     - RunQ total
     - RunQ average
     - RunQ skew (max - min)
     - avg util (%)
   - Run-queue trend (Δ runq/sec):
     - Large + / - values at left
     - Mini VSI dial to the right
4) Memory Breakdown
   - Total memory and distribution:
     - Processes, ETS, Binary, Code, Other

## Data Sources
- recon:proc_count/2 for per-process top 5 (memory, msgq)
- erlang:memory/0 for memory breakdown
- recon:scheduler_usage/1 + erlang:statistics/1 for scheduler pressure and run queue
