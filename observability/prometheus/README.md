# Prometheus Configuration Guide

This repository contains the central configuration file (`prometheus.yml`) used to configure **Prometheus** for scraping metrics across infrastructure, container workloads, log forwarders, and applications.

---

## 📌 Architectural Overview

```
                          +-----------------------------------+
                          |         Prometheus Server         |
                          | (Scrapes targets every 15s interval)|
                          +-----------------+-----------------+
                                            |
        +-------------------+---------------+---------------+-------------------+
        |                   |                               |                   |
        v                   v                               v                   v
+---------------+   +---------------+               +---------------+   +---------------+
|  Prometheus   |   | Node Exporter |               |   cAdvisor    |   |  Fluent Bit   |
| (Self Metrics)|   | (Host Metrics)|               | (Containers)  |   | (Log Pipeline)|
|    Port 9090  |   |   Port 9100   |               |   Port 8080   |   |   Port 2020   |
+---------------+   +---------------+               +---------------+   +---------------+
```

---

## ⚙️ Configuration Breakdown

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Prometheus monitors itself
  - job_name: prometheus
    static_configs:
      - targets: ["prometheus:9090"]

  # EC2 host metrics (CPU, RAM, disk, network)
  - job_name: node-exporter
    static_configs:
      - targets: ["node-exporter:9100"]

  # Per-container metrics
  - job_name: cadvisor
    static_configs:
      - targets: ["cadvisor:8080"]

  # Fluent Bit health (records processed, retries, errors)
  - job_name: fluent-bit
    metrics_path: /api/v1/metrics/prometheus
    static_configs:
      - targets: ["fluent-bit:2020"]

  # Your application (ONLY enable if your app exposes /metrics)
  # - job_name: my-app
  #   metrics_path: /metrics
  #   static_configs:
  #     - targets: ["app:8080"]
```

### 1. Global Settings

| Parameter | Value | Description |
| :--- | :--- | :--- |
| `scrape_interval` | `15s` | How frequently Prometheus pulls/scrapes metrics from configured targets. |
| `evaluation_interval` | `15s` | How frequently Prometheus evaluates alerting and recording rules. |

---

### 2. Scrape Jobs Summary

| Job Name | Target Endpoint | Metrics Path | Description |
| :--- | :--- | :--- | :--- |
| **`prometheus`** | `prometheus:9090` | `/metrics` *(default)* | Scrapes Prometheus internal engine performance, storage, and query latency metrics. |
| **`node-exporter`**| `node-exporter:9100` | `/metrics` *(default)* | Collects host-level OS metrics (CPU usage, RAM consumption, disk I/O, network traffic). |
| **`cadvisor`** | `cadvisor:8080` | `/metrics` *(default)* | Gathers resource usage and performance metrics for individual running containers. |
| **`fluent-bit`** | `fluent-bit:2020` | `/api/v1/metrics/prometheus` | Tracks log forwarder throughput, buffer usage, input/output record rates, and retry counts. |
| **`my-app`** *(Disabled)*| `app:8080` | `/metrics` | Template configuration for application-level custom metrics. |

---

## 🚀 Deployment Examples

### Docker Compose Integration

Mount the `prometheus.yml` file into your Prometheus container definition:

```yaml
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:v2.45.0
    container_name: prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
    ports:
      - "9090:9090"
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    ports:
      - "9100:9100"
    restart: unless-stopped

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    ports:
      - "8080:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    restart: unless-stopped

volumes:
  prometheus-data:
```

---

## 🔍 Validation & Useful PromQL Queries

### 1. Verify Active Targets
After starting Prometheus, navigate to **Status > Targets** (`http://localhost:9090/targets`) in the web UI. All jobs should show an `UP` status.

### 2. Common Monitoring Queries

* **Host CPU Usage % (Node Exporter):**
  ```promql
  100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
  ```

* **Container Memory Usage (cAdvisor):**
  ```promql
  container_memory_usage_bytes{name!=""}
  ```

* **Fluent Bit Output Success Rate:**
  ```promql
  rate(fluentbit_output_proc_records_total[5m])
  ```

---

## 🛡️ Best Practices & Production Tips

* **Config Validation:** Validate syntax locally before deploying using `promtool`:
  ```bash
  promtool check config prometheus.yml
  ```
* **Hot Reload:** Reload configuration changes dynamically without stopping the container by sending an HTTP POST request:
  ```bash
  curl -X POST http://localhost:9090/-/reload
  ```
  *(Requires `--web.enable-lifecycle` flag enabled on Prometheus)*
