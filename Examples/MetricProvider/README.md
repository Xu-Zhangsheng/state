# Metric provider example

This runnable worker publishes `example.metrics` only after the host sends an
effective demand. Build it with `swift build -c release`, copy the resulting
`MetricProviderWorker` executable to `Worker`, then run
`stasis-module package .`.

It demonstrates a data role, host-bound worker connection, snapshot quality
and demand-driven publication. It does not access hardware.
