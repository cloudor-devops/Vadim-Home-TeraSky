"""node-info service: exposes /health and /nodes.

Runs with a dedicated ServiceAccount whose ClusterRole only allows
get/list on nodes. The pod's own node is injected as NODE_NAME via the
Downward API (spec.nodeName).
"""

import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

logger = logging.getLogger("node-info")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))

APP_VERSION = os.getenv("APP_VERSION", "0.1.0")


def load_kube_config() -> None:
    """Prefer in-cluster config; fall back to local kubeconfig for dev."""
    try:
        config.load_incluster_config()
        logger.info("Loaded in-cluster Kubernetes config")
    except config.ConfigException:
        config.load_kube_config()
        logger.info("Loaded local kubeconfig (dev mode)")


@asynccontextmanager
async def lifespan(_: FastAPI):
    load_kube_config()
    yield


app = FastAPI(title="node-info", version=APP_VERSION, lifespan=lifespan)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "version": APP_VERSION}


@app.get("/nodes")
def nodes() -> dict:
    current_node = os.getenv("NODE_NAME", "")
    v1 = client.CoreV1Api()
    try:
        node_list = v1.list_node()
    except ApiException as exc:
        logger.error("Failed to list nodes: %s", exc.reason)
        raise HTTPException(status_code=502, detail=f"Kubernetes API error: {exc.reason}")

    items = []
    for node in node_list.items:
        conditions = {c.type: c.status for c in (node.status.conditions or [])}
        roles = [
            label.removeprefix("node-role.kubernetes.io/")
            for label in (node.metadata.labels or {})
            if label.startswith("node-role.kubernetes.io/")
        ] or ["worker"]
        addresses = {a.type: a.address for a in (node.status.addresses or [])}
        items.append(
            {
                "name": node.metadata.name,
                "ready": conditions.get("Ready") == "True",
                "roles": roles,
                "kubelet_version": node.status.node_info.kubelet_version,
                "internal_ip": addresses.get("InternalIP"),
                "os_image": node.status.node_info.os_image,
                "capacity": {
                    "cpu": node.status.capacity.get("cpu"),
                    "memory": node.status.capacity.get("memory"),
                },
                "current": node.metadata.name == current_node,
            }
        )

    return {"current_node": current_node or None, "count": len(items), "nodes": items}
