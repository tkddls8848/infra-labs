# Runtime-vendored manifests

`master_node/ceph.sh` checks out the Rook tag and immutable commit declared in
`../inventory.ini`, then copies only the required upstream example manifests into
`rook-<version>/upstream/`. It renders the inventory-declared storage nodes and
devices into `rook-<version>/rendered/cluster.yaml` before applying any Ceph
resources. Both generated directories are ignored; edit the inventory or renderer,
not their output.

This runtime-vendoring approach keeps every `kubectl apply` repo-local while avoiding
a dependency on `~/rook/deploy/examples` and avoiding fabricated copies of upstream
manifest bodies.
