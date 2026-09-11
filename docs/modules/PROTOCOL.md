# Worker protocol 1.0

Workers use JSON-RPC 2.0 over standard input and output. Each UTF-8 line is one
complete message and must be at most 1 MiB. Standard error is reserved for
diagnostic logs. No local network port is opened.

The host calls `initialize`, `activate`, `updateDemand`,
`validateConfigurationPatch`, `configurationChanged`, `handleAction`,
`deactivate` and `shutdown`.
Initialization supplies negotiated protocol version, locale, host capabilities,
configuration revision and recoverable state. Calls are idempotent and may be
cancelled. Initialization must not start every collector.

Before a settings-page edit is persisted, a running business worker receives
`validateConfigurationPatch` with `expectedRevision`, `schemaVersion`, the
current values and the proposed patch. It may return
`{"accepted":false,"message":"…"}` to reject an invalid business combination.
No result, or `accepted: true`, accepts it. The host still performs its own
schema validation and optimistic revision check; worker validation cannot
bypass either check. Modules opt into this lifecycle call with the
`settings.validation.v1` capability, so workers built for the earlier 1.0
surface remain compatible.

`updateDemand` always includes a `kind`. A `service` demand contains the
service ID, merged field list, effective interval and `active: true`. When its
last subscriber disappears, a still-running multi-role provider receives
`active: false` and must stop that collector. A `presentation` demand
contains `purposes` (`visiblePanel`, `preview`, `menuBar`) and the exact visible
component IDs. Empty presentation purposes mean display-only work must stop;
an active control or background task may keep the process alive.

Modules call `services.subscribe`, `services.unsubscribe`, `services.publish`,
`settings.read`, `settings.proposePatch`, `presentation.publishState`,
`control.acquire`, `control.renew`, `control.apply`, `control.release`,
`tasks.reportProgress`, `tasks.finish` and `notifications.post`.

The Swift SDK exposes typed `subscribe`, `unsubscribe`, `publish` and
`publishPresentationState` helpers. `ModuleServiceSnapshot.decode` validates
and decodes host notifications. The Metric Provider and Metric Dashboard
examples demonstrate an independent provider and consumer whose only shared
knowledge is the `example.metrics` service contract.

The host invokes declared UI actions through the worker's `handleAction`
lifecycle method. Workers do not receive a reflective “invoke any host action”
endpoint.

The SDK uses one continuous input reader and a request multiplexer. A worker
may therefore call the host while handling `initialize`, `activate` or an
action without deadlocking the lifecycle request. Host-to-worker snapshots use
the `services.snapshot` notification, delivered to the SDK worker's
`handleNotification` callback. Unknown notifications may be ignored; requests
with unknown methods return an error. Lifecycle calls and notifications are
processed through one FIFO queue; host responses bypass that queue so a worker
can await a host call without deadlocking or reordering control messages. Both
host and SDK enforce the 1 MiB limit
while bytes are arriving, including messages that never send a newline.

Ordinary requests time out after five seconds. Long operations immediately
return a task ID and publish progress with `tasks.reportProgress` (`taskID`,
`title`, optional `detail`, optional 0…1 `progress`). They finish with
`tasks.finish` and state `succeeded`, `failed` or `cancelled`. state keeps a
short per-module history in the module's General page; if the worker exits,
every running task is marked failed. Telemetry may collapse queued updates to
the newest snapshot. Control messages are ordered and are never silently
dropped. Responses from an older session or sequence cannot overwrite current
state.

The connection identifies the module. A `moduleID` field in JSON is treated as
untrusted metadata and never grants permissions or control ownership.

Control workers should acquire resources through the SDK's
`ModuleControlLease`. It creates a per-acquisition session, validates the host
reply, renews at the host-provided interval, and supplies typed `apply` and
`release` operations. A worker still releases leases during `deactivate` or
`shutdown`; a crash simply stops renewal and lets the host recovery deadline
take effect.
