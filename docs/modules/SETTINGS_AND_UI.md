# Settings and native UI

Every setting has exactly one owning module and one area: `general`, `panel` or
`feature`. Application-level general settings contain language, launch at login,
global notifications, updating and quit. Panel-level application settings own
module order, total layout, menu-bar provider and preview. Business parameters
belong to the relevant module's feature page.

A setting may declare `visibleWhen` with another setting ID and an equality
value. The host validates that reference and value type, then evaluates the
condition against the same saved configuration snapshot. This supports module
sub-options without hard-coded host page branches.

The host stores three independent states: installed, enabled and visible.
Module configuration is a fourth, versioned namespace. A change includes the
last observed revision. The host checks type, range and permission, optionally
asks the worker for business validation, writes atomically, increments revision,
then broadcasts the new snapshot. Hardware operations display pending, applied
or failed separately from the saved switch value.

Modules declaring the notification capability also receive a host-owned
per-module notification switch in General settings. Delivery requires the
global notification switch, this module switch and the module's granted core
permission; disabling presentation does not silently change notification
policy.

Module updates migrate configuration as part of the same transaction as the
worker health check. If schema validation, initialization or activation fails,
the prior module files, registry entry, schema and configuration revision are
restored together.

Presentation JSON supports only host-owned components. Protocol 1.0 includes
info rows, sections, buttons, toggles, progress and dividers. Icons are SF Symbol
names or validated resource IDs. Modules cannot choose arbitrary fonts, window
chrome or custom backgrounds. Preview and the live panel share the renderer;
sample data is the default and live preview is an explicit option.

A component may contain a `binding` key. Values published through
`presentation.publishState` are resolved against that key and update the
existing native view; the static `value` is used until state arrives.

The application panel settings contain one menu-bar provider picker. A module
becomes eligible by declaring at least one `menuBar` component. The host renders
its SF Symbol and bound text with `NSStatusBarButton`; modules cannot replace
the native highlight surface. Selecting the state fallback displays only the
application icon and creates no telemetry demand.

Changing a value in the preview does not create a sampler. Visibility is
reported to the demand system only when the real panel is open or live preview
is enabled. Structural or height changes rebuild layout; value changes update
the existing view.
