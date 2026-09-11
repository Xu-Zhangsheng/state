# Publishing and compatibility

Run `stasis-module validate`, `test` and `package` before publishing. Catalog
releases require Developer ID signing and notarization. Local development
packages may use ad-hoc signing, but state does not bypass Gatekeeper.

An update is staged and validated before the active version changes. The host
backs up configuration and recovery state, stops affected consumers, switches
the version, migrates configuration, initializes the worker and runs its health
check. Failure restores the previous files and configuration. An update
involving an active calibration is refused without changing files or
configuration. Retry after the workflow finishes, or cancel calibration first.

Compatibility is checked across host version, OS version, architecture,
protocol range, UI capability and every required service version. Cycles and
missing providers are errors. Multiple compatible providers may be installed;
the user chooses the active one in Module Management. A provider with active
dependents cannot be removed without showing those dependents.
