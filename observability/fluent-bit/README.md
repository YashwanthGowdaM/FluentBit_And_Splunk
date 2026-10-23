# Fluent Bit Log Forwarder Configuration

This repository contains the production-ready configuration for **Fluent Bit**, configured to collect Docker logs via the Forward protocol and reliably ship them to an external **Splunk** cluster via the HTTP Event Collector (HEC).

---

## 📌 Architecture Overview

```
+------------------+         +------------------+         +------------------+
|  Docker Containers|         |    Fluent Bit    |         |   Splunk HEC     |
| (fluentd driver) |  --->   | (Forward Plugin) |  --->   |  (Port 8088)     |
+------------------+  24224  +------------------+  TLS    +------------------+
                                      |
                               (Disk Buffering)
```

1. **Ingestion**: Listens for container logs using the `forward` plugin on port `24224`.
2. **Filtering**: 
   - Excludes self-generated logs from the `fluent-bit` container to prevent infinite logging loops.
   - Enriches matching log records (`app.*`) with environmental metadata (`environment`).
3. **Storage & Resilience**: Buffers incoming logs to local disk (`/fluent-bit/buffer`) to prevent log loss in the event of network disruption or Splunk downtime.
4. **Output**: Transmits enriched logs to Splunk HEC on port `8088` using TLS.

---

## ⚙️ Configuration Breakdown

### 1. Global Settings (`[SERVICE]`)
- **`Flush 5`**: Flushes log records to output plugins every 5 seconds.
- **`Log_Level warn`**: Suppresses internal debug/info messages, keeping self-logs lightweight.
- **`HTTP_Server On`**: Exposes built-in monitoring endpoints on `0.0.0.0:2020` for Prometheus scraping.
- **`storage.path /fluent-bit/buffer`**: Root directory for filesystem disk buffering.
- **`storage.sync normal`**: Uses OS standard buffer sync operations.
- **`storage.max_chunks_up 128`**: Controls memory limits by limiting active chunks in RAM.

### 2. Log Ingestion (`[INPUT]`)
- **`Name forward`**: Accepts data from Docker containers configured with the `fluentd` log driver.
- **`Port 24224`**: Standard port for Fluentd/Fluent Bit forward protocol.
- **`storage.type filesystem`**: Enables disk-backed storage mechanism for incoming streams on this input.

### 3. Log Processing & Enrichment (`[FILTER]`)
- **Loop Protection (`grep`)**: Drops records matching container name `^/?fluent-bit` to avoid cyclic forwarding.
- **Metadata Enrichment (`record_modifier`)**: Inject environmental context into tag streams matching `app.*`:
  - `environment`: `${ENVIRONMENT}`

### 4. Log Delivery (`[OUTPUT]`)
- **`Name splunk`**: Sends logs to Splunk HTTP Event Collector (HEC).
- **`Splunk_Send_Raw Off`**: Encapsulates payload in standard Splunk HEC JSON format.
- **`event_sourcetype docker:logs`**: Sets the default source type in Splunk.
- **`event_index main`**: Target index in Splunk for stored log events.
- **`Retry_Limit 10`**: Retries failed transmissions up to 10 times before dropping.
- **`storage.total_limit_size 1G`**: Caps disk buffer storage at 1GB for this output plugin.

---

## 🔐 Environment Variables

The configuration relies on environment variables for sensitive or environment-specific values:

| Variable | Description | Example |
| :--- | :--- | :--- |
| `ENVIRONMENT` | Deployment environment label injected into log records | `production`, `staging` |
| `SPLUNK_HOST` | Hostname or IP address of the Splunk instance | `splunk.example.com` |
| `SPLUNK_HEC_TOKEN` | Authentication token for Splunk HEC | `12345678-1234-1234-1234-123456789abc` |

---

