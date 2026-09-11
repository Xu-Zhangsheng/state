# state Module SDK

state 1.0 separates the host from installable features. The host owns process
lifecycle, native rendering, settings persistence, demand scheduling and
privileged control. A module owns only its declared data, calculations and
actions.

Start here:

1. [Architecture](ARCHITECTURE.md)
2. [Package format](MODULE_FORMAT.md)
3. [Worker protocol](PROTOCOL.md)
4. [Settings and native UI](SETTINGS_AND_UI.md)
5. [Publishing and compatibility](PUBLISHING.md)
6. [中文：模块制作与安装](MODULE_AUTHORING_CN.md)

The command-line tool under `Tools/StasisModuleCLI` implements `init`,
`validate`, `dev`, `test` and `package`.

Runnable examples are provided under `Examples`: `SystemClock` is a pure
declaration module, `MetricProvider` publishes a data service, and
`MockChargingPolicy` demonstrates bidirectional host requests, actions and
namespaced settings without controlling real hardware.

The built-in modules use the same registry that discovers external modules, so
menu ordering, enabled state and panel visibility do not require adding a new
case to the application shell.
