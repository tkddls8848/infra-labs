#!/usr/bin/env python3
"""Render the pinned upstream CephCluster with inventory-owned lab storage facts."""

import argparse
import json
from pathlib import Path

from ruamel.yaml import YAML


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory-json", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--nodes-output", required=True, type=Path)
    return parser.parse_args()


def main():
    args = parse_args()
    inventory = json.loads(args.inventory_json.read_text(encoding="utf-8"))
    storage_hosts = inventory.get("storage", {}).get("hosts", [])
    hostvars = inventory.get("_meta", {}).get("hostvars", {})

    if not storage_hosts:
        raise SystemExit("Inventory group 'storage' must contain at least one host")

    first_vars = hostvars[storage_hosts[0]]
    ceph_image = first_vars.get("ceph_image")
    mon_count = int(first_vars.get("rook_mon_count", 0))
    mgr_count = int(first_vars.get("rook_mgr_count", 0))
    if not ceph_image or mon_count < 1 or mgr_count < 1:
        raise SystemExit("ceph_image, rook_mon_count, and rook_mgr_count must be set in inventory")
    if mon_count > len(storage_hosts):
        raise SystemExit(
            f"rook_mon_count={mon_count} exceeds the {len(storage_hosts)} inventory storage hosts"
        )

    nodes = []
    kubernetes_node_names = []
    for host in storage_hosts:
        variables = hostvars[host]
        device = variables.get("rook_device")
        node_name = variables.get("vagrant_hostname", host)
        if not device:
            raise SystemExit(f"Storage host {host} has no rook_device inventory variable")
        nodes.append({"name": node_name, "devices": [{"name": device}]})
        kubernetes_node_names.append(node_name)

    yaml = YAML()
    yaml.preserve_quotes = True
    documents = list(yaml.load_all(args.source.read_text(encoding="utf-8")))
    clusters = [document for document in documents if document and document.get("kind") == "CephCluster"]
    if len(clusters) != 1:
        raise SystemExit(f"Expected one CephCluster in {args.source}, found {len(clusters)}")

    spec = clusters[0]["spec"]
    spec["cephVersion"]["image"] = ceph_image
    spec["mon"]["count"] = mon_count
    spec["mon"]["allowMultiplePerNode"] = False
    spec["mgr"]["count"] = mgr_count
    spec["mgr"]["allowMultiplePerNode"] = False
    spec["placement"] = {
        "all": {
            "nodeAffinity": {
                "requiredDuringSchedulingIgnoredDuringExecution": {
                    "nodeSelectorTerms": [
                        {
                            "matchExpressions": [
                                {
                                    "key": "role",
                                    "operator": "In",
                                    "values": ["storage-node"],
                                }
                            ]
                        }
                    ]
                }
            }
        }
    }
    spec["storage"]["useAllNodes"] = False
    spec["storage"]["useAllDevices"] = False
    spec["storage"]["nodes"] = nodes

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as output:
        yaml.dump_all(documents, output)
    args.nodes_output.write_text("\n".join(kubernetes_node_names) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
