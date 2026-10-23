# Grafana Datasource Configuration

This repository contains the provisioning configuration for automatically configuring **Prometheus** as a default datasource in **Grafana**.

Using Grafana's file-based provisioning system allows datasources to be defined as code, ensuring repeatable and automated deployments without requiring manual web UI configuration.

## 📌 Overview

```
+-------------------+             +-------------------+             +-------------------+
|    Grafana        |  Provision  | Grafana Datasource|   Proxy     | Prometheus Server |
|  (Monitoring UI)  | <---------  |   (YAML Config)   | ----------> | (http://prometheus:9090)
+-------------------+             +-------------------+             +-------------------+

```

When Grafana initializes, it reads the YAML configuration file from the provisioning directory and automatically registers Prometheus as the primary data source for querying metrics.

## ⚙️ Configuration Details

Below is the detailed explanation of the parameters used in the `datasources.yaml` configuration file:

```
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true

```

| **Parameter** | **Type** | **Value** | **Description** | 
| `apiVersion` | Integer | `1` | Defines the schema version used by Grafana provisioning. | 
| `name` | String | `Prometheus` | The display name for the datasource within Grafana UI and dashboards. | 
| `type` | String | `prometheus` | Specifies the underlying data source driver used by Grafana. | 
| `access` | String | `proxy` | Dictates that queries are routed through Grafana's server backend (hides internal network address from client browser). | 
| `url` | String | `http://prometheus:9090` | Internal network endpoint where the Prometheus instance is reachable. | 
| `isDefault` | Boolean | `true` | Sets this datasource as the default selection for new panels and dashboards. | 

## 🚀 Deployment Instructions

### Directory Structure

Place this configuration file inside Grafana's provisioning directory (typically `/etc/grafana/provisioning/datasources/`):

```
.
├── docker-compose.yml
└── grafana/
    └── provisioning/
        └── datasources/
            └── prometheus-datasource.yaml

```

### 1. Running with Docker Compose

Here is an example `docker-compose.yml` mounting the provisioning file into the Grafana container:

```
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    restart: always

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources
    depends_on:
      - prometheus
    restart: always

```

### 2. Kubernetes Deployment (ConfigMap)

To deploy this configuration within Kubernetes, load the YAML configuration into a `ConfigMap` and mount it into your Grafana pod:

```
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-service:9090
        isDefault: true

```

## 🔍 Validation & Troubleshooting

1. **Verify UI Registration**:

   * Open Grafana (`http://localhost:3000`).

   * Navigate to **Configuration > Data sources**.

   * You should see **Prometheus** listed with a `default` badge.

2. **Test Connectivity**:

   * Click on the **Prometheus** datasource.

   * Click **Save & test**. A green banner indicating *"Data source is working"* should appear.

3. **Common Issues**:

   * **`HTTP Error Bad Gateway`**: Grafana cannot resolve or reach `http://prometheus:9090`. Ensure both containers share the same Docker network.

   * **`Access mode direct vs proxy`**: Always use `access: proxy` when Prometheus is hosted inside an internal container network that isn't exposed directly to client browsers.
