# Erlang Node Diagnostic UX: Health Gauges Analysis

Goal: define the most important BEAM/OTP health gauges for a diagnostic tool UX. Priority is based on how reliably a metric signals node health and how actionable it is in production.

## P0 (Always-on, top-level health)
- Scheduler pressure (scheduler utilization + run queue length / imbalance)
  - Signals CPU saturation and unfairness across schedulers.
- Total memory + memory by category
  - Track total plus buckets: Processes, ETS, Binary, Code.
- Message queue length (per-process)
  - Primary bottleneck indicator; long queues drive memory blowups.
- Process memory (per-process)
  - Identifies the biggest suspects and leaking processes.

## P1 (Early warning / root-cause hints)
- Binary memory pressure
  - Large refc binaries held by slices can keep memory alive.
- ETS growth
  - ETS is off-heap and not GC’d by process; runaway tables are silent leaks.
- Atom table usage
  - Atoms never GC; dynamic atom creation can crash the VM.
- Code memory growth
  - Hot upgrades / module load churn can bloat code memory.

## P2 (Drill-down diagnostics)
- Reductions rate per process (work done)
  - Helps find CPU hogs beyond simple process counts.
- Process status mix (running / runnable / waiting)
  - Distinguishes CPU-bound vs blocked/idle overload.
- Heap / total_heap_size trends for hot processes
  - Growth over time suggests leaking state.

## UX notes
- Default dashboard: show P0 at node level + “top offenders” list for queues and memory.
- Drill-down: process card shows queue length, memory, reductions, status, and heap trend.
