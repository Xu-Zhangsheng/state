# Architecture

## Dependency rule

The direction is fixed:

```text
App shell -> StasisCore -> StasisContracts
Native UI -> StasisContracts
Module worker -> StasisModuleSDK -> StasisContracts
Platform helper -> macOS hardware APIs
```

The host never imports a feature module. Modules never import host internals,
AppKit views, SwiftUI views, SMC types, or another module. A dependency between
modules is expressed as a versioned service requirement and resolved by the
service broker.

## Host components

- `ModuleRegistry` stores installed, enabled and visible as independent states.
  It also owns module order, the menu-bar provider and the selected provider
  for each versioned service. Multiple providers may be installed, but only
  the selected provider receives demand.
- `RuntimeSupervisor` starts at most one worker process for each active module,
  frames bidirectional JSON-RPC messages, drains diagnostic output, enforces the
  1 MiB limit and resolves timeouts.
- `ServiceBroker` allows one selected provider per service contract, returns a
  cached snapshot first and rejects stale sequence numbers.
- `DemandScheduler` merges fields and update intervals for all consumers. The
  fastest supported interval wins, while fields are unioned.
- `ModuleSettingsStore` stores one versioned JSON namespace per module and uses
  optimistic revisions to prevent lost updates.
- `ModuleInstaller` stages imports, rejects traversal and symlinks, validates
  protocol/architecture/checksums, then switches the installed version.
- `PermissionBroker` limits access to host-provided services. It is not a claim
  of OS sandboxing for a native third-party executable.
- `ControlLeaseManager` grants one owner for a hardware control resource and
  expires the lease after 15 seconds without renewal. Expiry and worker exit
  invoke a fixed host recovery path that restores charging and external power.
  Lease time is paused while macOS sleeps; orderly application termination
  releases every lease and waits for the helper to restore system defaults.
- `NativeRenderer` interprets a constrained component descriptor. Module code
  never enters the host view hierarchy.

## Activation

Installing, enabling, showing and activating are different operations.

1. Installed means files and metadata passed validation.
2. Enabled means the module may satisfy dependencies or run background work.
3. Visible means its presentation participates in the menu layout.
4. Active means the supervisor has an actual reason to run its worker.

If a required service loses its selected provider, the dependent worker is
stopped and shown as failed with the missing service ID. Installing or enabling
a compatible provider clears that condition on the next reconciliation.

Initialization does not start sampling. Activation occurs only when at least
one service subscription, visible presentation, menu-bar provider or persistent
background task requires it. Deactivation cancels display subscriptions and
releases ordinary resources. A control or calibration module can remain active
after the panel closes, but must retain a declared background-task demand.

## Data path

For third-level power flow, the renderer first reports visibility. The power
module then subscribes to only the fields used by its enabled branches. The
scheduler merges that demand with other consumers and sends one effective
demand to the telemetry provider. Snapshots carry session, sequence, sample
window, timestamp, unit and quality. A missing reading is `unavailable`, never
zero. Closing the panel or switching to second-level presentation cancels chip
and external-device demand.

## Control path

A control worker requests permission and then acquires a lease for a named
resource such as `battery.charging`. The host associates ownership with the
connected process, not a module ID inside the message. The worker renews every
five seconds. If it stops renewing for fifteen active seconds, is disabled, is
removed or disconnects, the host invokes the fixed recovery operation.

The privileged helper independently verifies the connecting application's
code identity. Production builds require the Stasis identifier and team;
legacy ad-hoc migration is restricted to the exact application path under
`/Applications`. The helper exposes only typed charging, external-power,
indicator and sampling operations.

Charging policy submits those controls as one ordered power-state operation.
Force discharge disables charging before switching the external-power path;
normal operation restores the external-power path before charging, and applies
the indicator last. A failed step returns its real error and triggers a
best-effort reset of every supported control to its system default.

Policy priority is capability recovery, heat protection, explicit temporary
user action, calibration override, then normal limit/sailing. Calibration calls
the charging-policy service and never writes SMC keys or the user's persistent
charging configuration directly.

## Migration boundary

The 1.0 Beta uses built-in compatibility adapters for the current battery,
power, energy-app and charging implementations. The shell now sees module IDs,
not the old feature enumeration. Each adapter will move behind a service
contract independently; the compatibility path can be deleted only after its
module passes identical behavior and resource tests.

## Enforced boundaries

`Tools/verify-architecture.sh` runs in CI before the Apple Silicon host build.
It rejects UI or hardware imports in the public contracts and core
package, hardware access in the native renderer, and host-internal imports from
example modules. The dependency direction is therefore an executable check,
not only a documentation convention.
