# Splunk Enterprise on Docker

A minimal, single-node **Splunk Enterprise 9.3** deployment using Docker Compose. It gives you a Splunk web UI for searching and dashboards, plus an HTTP Event Collector (HEC) endpoint so applications and scripts can send logs over HTTP.

---

## Table of Contents

1. [What This Project Does](#what-this-project-does)
2. [Project Structure](#project-structure)
3. [How It Works](#how-it-works)
4. [Configuration Reference](#configuration-reference)
5. [Prerequisites](#prerequisites)
6. [Quick Start](#quick-start)
7. [Verifying the Deployment](#verifying-the-deployment)
8. [Sending Logs to Splunk (HEC)](#sending-logs-to-splunk-hec)
9. [Data Persistence](#data-persistence)
10. [Security Recommendations](#security-recommendations)
11. [Common Operations](#common-operations)
12. [Troubleshooting](#troubleshooting)

---

## What This Project Does

This setup runs Splunk inside a container and exposes two services:

| Capability | Port | Purpose |
|---|---|---|
| Splunk Web UI | `8000` | Search, dashboards, alerts, administration |
| HTTP Event Collector (HEC) | `8088` | Ingest logs/events from apps via HTTP(S) |

Typical use cases: a local or lab SIEM/log-analysis environment, learning Splunk (SPL queries, dashboards), and testing log pipelines from applications, CI/CD or Kubernetes.

---

## Project Structure

```
.
├── docker-compose.yml   # Defines the Splunk service, ports, env vars and volumes
├── env.txt              # Secrets/variables consumed by docker-compose.yml
└── README.md            # This document
```

### `docker-compose.yml`
Declares one service, `splunk`, built from the official `splunk/splunk:9.3` image. It accepts the licence terms, sets the admin password and HEC token from environment variables, publishes the two ports, and mounts host directories so data survives container restarts.

### `env.txt`
A key/value file holding the sensitive values referenced in the Compose file as `${SPLUNK_PASSWORD}` and `${SPLUNK_HEC_TOKEN}`.

| Variable | Description |
|---|---|
| `SPLUNK_PASSWORD` | Password for the Splunk `admin` user |
| `SPLUNK_HEC_TOKEN` | Token that clients present to send data to HEC (must be a GUID) |

> **Note:** Docker Compose automatically loads a file named `.env`, not `env.txt`. See [Quick Start](#quick-start) for how to handle this.

---

## How It Works

```
 ┌──────────────┐    HTTP(S) :8088     ┌─────────────────────────┐
 │ Apps/Scripts │ ───────────────────▶ │  Splunk container       │
 └──────────────┘   (HEC token)        │  (splunk/splunk:9.3)    │
                                       │                         │
 ┌──────────────┐    HTTP :8000        │  Indexing + Search Head │
 │   Browser    │ ───────────────────▶ │                         │
 └──────────────┘   (admin login)      └───────────┬─────────────┘
                                                   │
                                  bind mounts      ▼
                                       /data/splunk-var  → /opt/splunk/var
                                       /data/splunk-etc  → /opt/splunk/etc
```

1. Compose reads the variables and starts the container.
2. On first boot, the Splunk entrypoint accepts the licence, creates the `admin` user with `SPLUNK_PASSWORD`, and enables HEC with `SPLUNK_HEC_TOKEN`.
3. Indexed data (`var`) and configuration (`etc`) are written to the host, so they persist.

---

## Configuration Reference

### Environment variables (container)

| Variable | Value in this repo | Meaning |
|---|---|---|
| `SPLUNK_START_ARGS` | `--accept-license` | Accepts the Splunk software licence (required for non-interactive start) |
| `SPLUNK_GENERAL_TERMS` | `--accept-sgt-current-at-splunk-com` | Accepts Splunk General Terms (required by recent images) |
| `SPLUNK_PASSWORD` | `${SPLUNK_PASSWORD}` | Admin password, injected from your env file |
| `SPLUNK_HEC_TOKEN` | `${SPLUNK_HEC_TOKEN}` | Default HEC token, injected from your env file |

### Other settings

| Setting | Value | Meaning |
|---|---|---|
| `image` | `splunk/splunk:9.3` | Official Splunk Enterprise image, pinned to 9.3 |
| `container_name` | `splunk` | Fixed name for easy `docker exec` / `docker logs` |
| `restart` | `unless-stopped` | Auto-restarts after crashes or host reboot unless manually stopped |

### Ports

| Host:Container | Service |
|---|---|
| `8000:8000` | Web UI |
| `8088:8088` | HTTP Event Collector |

### Volumes

| Host path | Container path | Contents |
|---|---|---|
| `/data/splunk-var` | `/opt/splunk/var` | Indexes, logs, runtime data |
| `/data/splunk-etc` | `/opt/splunk/etc` | Configuration, apps, users |

---

## Prerequisites

- Linux host (or any host with Docker support)
- [Docker Engine](https://docs.docker.com/engine/install/) and the Docker Compose plugin (`docker compose`)
- At least **4 GB RAM** and **2 vCPUs** recommended; Splunk is resource hungry
- Enough free disk space under `/data` for your expected log volume
- Ports `8000` and `8088` free on the host

---

## Quick Start

**1. Prepare the host directories**

```bash
sudo mkdir -p /data/splunk-var /data/splunk-etc
# The Splunk container runs as UID 41812; give it write access
sudo chown -R 41812:41812 /data/splunk-var /data/splunk-etc
```

**2. Provide the environment file**

Either rename it so Compose loads it automatically:

```bash
mv env.txt .env
```

or keep the name and pass it explicitly in every command:

```bash
docker compose --env-file env.txt up -d
```

**3. Set your own secrets** (edit the file you chose above)

```env
SPLUNK_PASSWORD=<strong-admin-password>
SPLUNK_HEC_TOKEN=<generate-a-guid>
```

Generate a GUID with: `uuidgen`

**4. Start Splunk**

```bash
docker compose up -d        # or: docker compose --env-file env.txt up -d
```

**5. Wait for initialization**

First start takes a few minutes. Watch progress:

```bash
docker logs -f splunk
# Ready when you see: "Ansible playbook complete" / container reports healthy
```

---

## Verifying the Deployment

**Web UI:** open `http://<host-ip>:8000` and sign in with:

- Username: `admin`
- Password: the value of `SPLUNK_PASSWORD`

**Container health:**

```bash
docker ps --filter name=splunk
```

**HEC health check:**

```bash
curl -k https://localhost:8088/services/collector/health
# Expected: {"text":"HEC is healthy","code":17}
```

---

## Sending Logs to Splunk (HEC)

Send a test event:

```bash
curl -k https://localhost:8088/services/collector/event \
  -H "Authorization: Splunk <SPLUNK_HEC_TOKEN>" \
  -d '{"event": "Hello from HEC", "sourcetype": "manual", "index": "main"}'
```

Expected response: `{"text":"Success","code":0}`

Then in the Splunk UI, run this search:

```
index=main sourcetype=manual
```

> `-k` skips certificate verification because Splunk uses a self-signed certificate by default. If your setup serves HEC over plain HTTP, use `http://` instead. Use proper certificates in production.

---

## Data Persistence

Because `/opt/splunk/var` and `/opt/splunk/etc` are bind-mounted from the host:

- `docker compose down` and container recreation **do not** delete your data or configuration.
- Back up `/data/splunk-var` and `/data/splunk-etc` regularly.
- To fully reset Splunk, stop the container and delete both host directories.

---

## Security Recommendations

- **Never commit secrets.** Add the env file to `.gitignore`:
  ```
  .env
  env.txt
  ```
- **Replace the sample values.** The password and token shipped in `env.txt` are placeholders; use a strong password and a freshly generated GUID.
- **Restrict network exposure.** Limit ports `8000` and `8088` with a firewall or security group, or put a reverse proxy with TLS in front.
- **Use TLS.** Replace the default self-signed certificate for any non-lab use.
- **Rotate credentials** periodically and after any suspected exposure.
- **Pin versions deliberately.** The image is pinned to `9.3`; review release notes before upgrading.

---

## Common Operations

| Task | Command |
|---|---|
| Start | `docker compose up -d` |
| Stop (keep data) | `docker compose down` |
| View logs | `docker logs -f splunk` |
| Open a shell | `docker exec -it splunk bash` |
| Restart | `docker compose restart splunk` |
| Pull a newer image | `docker compose pull && docker compose up -d` |
| Check status | `docker ps --filter name=splunk` |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Container exits immediately | Licence/terms variables missing or password too weak | Ensure `SPLUNK_START_ARGS` and `SPLUNK_GENERAL_TERMS` are set; use a password of 8+ characters |
| Warning that `SPLUNK_PASSWORD` is not set | Env file is not being loaded | Rename `env.txt` to `.env`, or use `--env-file env.txt` |
| `Permission denied` on `/opt/splunk/var` | Host directory ownership | `sudo chown -R 41812:41812 /data/splunk-var /data/splunk-etc` |
| Web UI not reachable | Splunk still initializing, or port blocked | Wait a few minutes, check `docker logs splunk`, check firewall |
| HEC returns `Invalid token` | Wrong or missing token in the `Authorization` header | Use `Authorization: Splunk <token>` with the exact configured token |
| HEC connection or SSL error | HTTPS with self-signed certificate | Use `curl -k`, or check whether HEC is served over HTTP |
| Very slow or killed container | Insufficient memory | Allocate at least 4 GB RAM |

---

## References

- [Splunk Docker image documentation](https://splunk.github.io/docker-splunk/)
- [Splunk HTTP Event Collector docs](https://docs.splunk.com/Documentation/Splunk/latest/Data/UsetheHTTPEventCollector)
- [Docker Compose documentation](https://docs.docker.com/compose/)
