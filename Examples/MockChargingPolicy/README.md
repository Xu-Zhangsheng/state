# Mock charging-policy example

This runnable worker reads its namespaced settings, publishes presentation
state and handles a user action. It intentionally requests no hardware-control
permission and never calls the charging helper.

Its `menuBar` descriptor also demonstrates a selectable menu-bar provider. The
host owns the SF Symbol, font, spacing and highlight behavior; the worker only
publishes the bound status text.

Build it with `swift build -c release`, copy `MockChargingPolicyWorker` to
`Worker`, and package the directory with `stasis-module package .`.
