# Ente background manager

A small Flutter plugin for Photos' background execution. Android uses Jetpack WorkManager; iOS uses Background Tasks. Photos owns sync, ML, credentials, progress, and domain locks.

## Photos rollout

`flagService.internalUser` alone selects the backend: internal users use this plugin, and everyone else uses the existing Workmanager integration. There is no separate background-processing setting. Selection is checked again at native admission and in the background Dart callback, following the existing internal-user rules for debug builds and the internal-user disable override.

`lib/utils/background_tasks.dart` owns configuration and backend migration. It preserves the existing refresh/processing task policies. Both backends use Photos' existing `background_process` lock during migration. A running legacy callback notices a change to native eligibility, stops admitting work, and retires its schedules after draining. Configuring Photos without internal eligibility requests a stop and removes the native schedules; Android defers cancellation of an active worker's registration until retirement so cancellation does not cut short cooperative cleanup.

The initial Photos configuration supplies runtime budgets and omits `foregroundStopTimeout`. Native expiration still ends a run. Supplying a foreground timeout later requires validating the lifetime of Photos' native/FFI operations: destroying a Flutter engine does not establish that those operations have stopped.

Both Android backends resolve the app's existing Jetpack WorkManager 2.10.2 dependency, keeping the shared native scheduler version unchanged during this rollout.

## Consumer interface

- `BackgroundManager.configure` supplies a retained top-level dispatcher, task configurations, scheduling enablement, and an outcome handler. Repeated configuration reconciles persistent schedules.
- `BackgroundManager.executeTask` runs the callback inside the dispatcher and handles readiness, stop delivery, errors, and completion.
- `BackgroundTask` exposes its identifier, elapsed time, optional remaining budget, and a latched stop signal. The callback stops admitting work, drains cleanup, and returns a `BackgroundTaskResult`.
- `BackgroundManager.stopActiveRun` requests stopping of the current invocation and completes after retirement. It preserves future registrations and is an immediate no-op when idle. Use it from the foreground; a background callback should return after cleanup instead of awaiting its own retirement.
- `BackgroundManager.scheduledTasks` queries native registrations. A pending registration is not a guarantee that the OS will run it.

Task configuration supports refresh/processing kind, frequency, initial delay, supported native constraints, and two optional durations. `runBudget` requests cooperative stopping from native entry, including engine startup. `foregroundStopTimeout` starts force teardown after the first foreground arrival. Omission disables the corresponding timer; zero acts immediately and negative durations are rejected. Android supports periodic flex and device-idle constraints. iOS supports network/power constraints only for processing tasks; unsupported combinations are rejected.

## Native lifecycle

Each platform has one process-local runtime. Admission checks backend eligibility, the active execution slot, and native foreground visibility before creating an engine. Busy or foreground deliveries finish as skips. Every admitted run captures its configuration and dispatcher binding and creates a fresh engine.

The slot remains occupied during startup, execution, cleanup, and teardown. Native callbacks and timers are tied to a unique invocation. Foreground entry always requests stopping, including during startup. Stops remain latched; repeated visibility changes cannot revive a task or extend its grace. Configuration updates affect later runs only.

Normal completion, startup failure, system interruption, and configured forced teardown share one retirement path. Retirement invalidates timers, detaches the task channel, destroys the background engine, and completes the native invocation once. iOS re-arms normal future opportunities independently of Dart. No plugin retry loop, work queue, engine pool, or persistent event history is used.

Photos logs its task activity. Skips, stops, forced teardown, and failures are forwarded to an available outcome handler; otherwise the plugin writes one native log line (`EnteBackgroundManager` on Android, `io.ente.background` on iOS).

## Native installation

Android installs the plugin runtime from `EnteApplication` before workers can start. Activity lifecycle callbacks provide foreground visibility, with an early `MainActivity.onCreate` signal during foreground engine creation.

iOS installs the runtime and generated plugin registrant in `AppDelegate`, registers both task identifiers before launch completes, and declares them in `BGTaskSchedulerPermittedIdentifiers`. Both integrations retain the old Workmanager registration while the rollout flag is available.

## Validation

The Android test runs the real worker, scheduler configuration, method-channel encoding, and lifecycle/timer logic with mocked Flutter engines. It covers foreground and busy admission, ownership during teardown, startup stops, cooperative completion, foreground grace, configuration changes during a run, stale events, bootstrap failure, and preservation of recurring scheduling after active-run stopping.

From `mobile/apps/photos/android`:

```sh
./gradlew :ente_background_manager:testDebugUnitTest :ente_background_manager:lintDebug
```

Device rollout checks remain necessary for OS-delivered refresh/processing opportunities, cold launch, system expiration, foreground handoff during real uploads/inference, and release-mode callback retention. Exercise internal and non-internal eligibility and verify the selected backend's future schedules after relaunch.
