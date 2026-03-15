# 2026-03-15 Performance Optimization Plan

## Goals

- Reduce end-to-end voice latency by 20%+.
- Reduce reconnect-to-ready time by 30%+.
- Reduce peak CPU usage on audio path by 25%+.
- Reduce UI frame drops in large channels by 50%+.
- Reduce 30-minute call energy usage by 10%+.

## Success Metrics

- `connect_begin -> connect_ready` total latency (ms)
- `connect_begin -> connect_opened` handshake latency (ms)
- `connect_opened -> connect_ready` auth/join latency (ms)
- reconnect success rate and average recovery time
- audio callback p95/p99 duration
- frame drop ratio in channel/message views

## Execution Phases

### Phase 1: Baseline Instrumentation (in progress)

- [x] Add connection/reconnect performance markers in `MUConnectionController`.
- [ ] Add audio callback timing markers in MumbleKit audio path.
- [ ] Add model rebuild timing in `ServerModelManager+ModelState`.
- [ ] Add message render timing in `MessagesView`.

### Phase 2: Hot Path Fixes

- [ ] Eliminate allocations on real-time audio callback path.
- [ ] Coalesce high-frequency notifications to reduce main-thread churn.
- [ ] Reduce full channel tree rebuild frequency (incremental updates).
- [ ] Tune reconnect strategy for jittery network transitions.

### Phase 3: Validation and Rollout

- [ ] Run iPhone + iPad + macOS baseline/after comparison.
- [ ] Validate weak network, bluetooth route change, background reconnect scenarios.
- [ ] Keep debug telemetry behind low-overhead logs and verify no regressions.

## Work Started in This Iteration

- Added baseline logs in `MUConnectionController.m`:
  - `PERF connect_begin`
  - `PERF connect_opened`
  - `PERF connect_ready`
  - `PERF connect_failed`
- These logs include reconnect flag, attempt number, and key durations in milliseconds.

## Immediate Next Tasks

1. Instrument audio callback timing in MumbleKit.
2. Instrument channel tree rebuild timing.
3. Produce first baseline report from real devices.
