# Module package format

A `.stasismodule` file is a ZIP archive with no install hooks:

```text
module.json
settings.schema.json
presentation.json
checksums.json
Resources/
Worker.app/                 optional
```

`Resources/localizations.json` is optional. It maps BCP-47 language tags to
stable text keys. `displayName`, `summary`, presentation titles/placeholder
values, setting titles/descriptions and choice titles use those keys; missing
entries fall back to English and then to the key itself. state resolves the
table after launch, so changing the application language does not rewrite or
duplicate module configuration.

`module.json` is decoded as `ModuleDescriptor`. IDs are stable reverse-DNS
identifiers. Versions use semantic versioning. `protocolVersion` describes the
JSON-RPC contract, not the module release. state 1.0 Beta and its official
modules target Apple Silicon (`arm64`) only.

`checksums.json` maps every packaged regular file to lowercase SHA-256 and does
not include itself. Missing and extra manifest entries are rejected. Absolute
paths, `..`, symbolic links, unknown or non-executable worker entrypoints and
files escaping the staging directory are rejected.

`stasis-module package` builds a clean staging payload. Source files, SwiftPM
build output and other development-only files are not copied into the archive.

Workers are activated only after the complete package is validated and copied
to:

```text
~/Library/Application Support/Stasis/Modules/<id>/<version>/
```

Configuration is stored outside this directory, so updating or removing files
does not silently discard user choices.

Required descriptor fields are `id`, `version`, `protocolVersion`,
`minHostVersion`, `minOSVersion`, `architectures`, `roles`, `provides`,
`requires`, `permissions`, `uiCapabilities`, `author`, `license`,
`settingsVersion`, `displayName`, `summary` and `systemImage`. `entrypoint` is
optional for declaration-only modules.

Each entry in `provides` contains a stable service `id` and contract `version`.
Catalog modules also declare `fields`, `minimumInterval` and
`maximumInterval`. The host rejects unknown requested fields and clamps demand
periods to that range. Omitting these three capability fields is supported only
for protocol-1.0 legacy providers, whose field set remains provider-defined.
