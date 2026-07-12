from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import main


def fake_node(name: str, ready: str = "True", role_label: str | None = None):
    labels = {role_label: ""} if role_label else {}
    return SimpleNamespace(
        metadata=SimpleNamespace(name=name, labels=labels),
        status=SimpleNamespace(
            conditions=[SimpleNamespace(type="Ready", status=ready)],
            addresses=[SimpleNamespace(type="InternalIP", address="10.0.0.1")],
            node_info=SimpleNamespace(kubelet_version="v1.35.0", os_image="Debian"),
            capacity={"cpu": "4", "memory": "8Gi"},
        ),
    )


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "load_kube_config", lambda: None)
    with TestClient(main.app) as test_client:
        yield test_client


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_metrics_exposes_request_counter(client):
    client.get("/health")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "http_requests_total" in response.text


def test_nodes_marks_current_node(client, monkeypatch):
    nodes = [
        fake_node("worker-1", role_label="node-role.kubernetes.io/control-plane"),
        fake_node("worker-2"),
    ]
    monkeypatch.setenv("NODE_NAME", "worker-2")
    monkeypatch.setattr(
        main.client,
        "CoreV1Api",
        lambda: SimpleNamespace(list_node=lambda: SimpleNamespace(items=nodes)),
    )

    response = client.get("/nodes")
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 2
    assert body["current_node"] == "worker-2"
    flags = {n["name"]: n["current"] for n in body["nodes"]}
    assert flags == {"worker-1": False, "worker-2": True}
    roles = {n["name"]: n["roles"] for n in body["nodes"]}
    assert roles["worker-1"] == ["control-plane"]
    assert roles["worker-2"] == ["worker"]


def test_nodes_api_error_returns_502(client, monkeypatch):
    from kubernetes.client.exceptions import ApiException

    def boom():
        raise ApiException(status=403, reason="Forbidden")

    monkeypatch.setattr(
        main.client, "CoreV1Api", lambda: SimpleNamespace(list_node=boom)
    )

    response = client.get("/nodes")
    assert response.status_code == 502
    assert "Forbidden" in response.json()["detail"]
