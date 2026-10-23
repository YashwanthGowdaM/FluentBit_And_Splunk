# Docker Deployment with Prometheus, Grafana, Fluent Bit & Splunk (AWS)

A beginner-friendly, copy-paste guide to deploy your application in Docker with:

| Tool | Purpose |
|------|---------|
| **Prometheus** | Collects and stores **metrics** (CPU, memory, requests, etc.) |
| **Grafana** | Shows metrics as dashboards |
| **Fluent Bit** | Collects **logs** from your containers and ships them to Splunk |
| **Splunk** (separate server) | Stores and searches **logs** |
| **Node Exporter** | Exposes host (EC2) metrics to Prometheus |
| **cAdvisor** | Exposes per-container metrics to Prometheus |

> **Important design choice (avoids Fluent Bit reading its own logs):**
> Your app containers send logs to Fluent Bit using Docker's `fluentd` logging driver.
> Fluent Bit's own container uses the normal `json-file` driver, so it is **never** collected.
> This prevents the classic infinite loop where Fluent Bit logs an error, reads that error, and logs again.
> A second safety filter in `fluent-bit.conf` also drops anything coming from a container named `fluent-bit`.

---

## 1. Architecture

![AWS VPC Monitoring and Logging Architecture](media/AWS%20VPC%20Monitoring%20and%20Logging%20Architecture.png)
- **Metrics flow:** App / host / containers → Prometheus → Grafana
- **Logs flow:** App → Fluent Bit → Splunk (over HTTPS, port 8088, using HEC = HTTP Event Collector)

---

## 2. AWS sizing (what you need)

These are sensible starting points for a small/medium workload (dev, test, small production). Always check the current Splunk system requirements and AWS pricing for your case.

### Server 1: Application + Monitoring (`app-server`)

| Item | Recommendation |
|------|----------------|
| OS | Ubuntu Server 22.04 or 24.04 LTS (64-bit x86) |
| Instance type | **t3.large** (2 vCPU, 8 GB RAM) for a small app. Use **t3.xlarge** (4 vCPU, 16 GB) if your app is heavy |
| Root volume | **50 GB gp3** |
| Why this size | OS + Docker images ≈ 10 GB, Prometheus 15 days of data ≈ 2–10 GB, Fluent Bit buffer 1 GB, Docker logs and room to grow |

### Server 2: Splunk (`splunk-server`)

| Item | Recommendation |
|------|----------------|
| OS | Ubuntu Server 22.04 or 24.04 LTS (64-bit x86) |
| Instance type | **m5.xlarge** or **t3.xlarge** (4 vCPU, 16 GB RAM). Minimum for testing: t3.large (2 vCPU, 8 GB) |
| Root volume | **30 GB gp3** |
| Data volume | **100 GB gp3** (extra EBS volume, mounted at `/data`). Splunk stores roughly 50% of raw log size, so 1 GB/day of logs for 30 days ≈ 15 GB. 100 GB leaves plenty of room |
| Licence note | Splunk Enterprise has a 60-day trial (500 MB/day indexing). After that you need a licence, or fall back to the Free tier. Check Splunk's licensing page |

### Network / Security Groups

Create **two security groups**.

**`sg-app-server`** (inbound):

| Port | Source | Purpose |
|------|--------|---------|
| 22 | **My IP** only | SSH |
| 80 (or your app port) | 0.0.0.0/0 | Your application |
| 3000 | **My IP** only | Grafana UI |

> Prometheus (9090) is deliberately **not** opened to the internet. You will reach it through an SSH tunnel (see Section 9).

**`sg-splunk-server`** (inbound):

| Port | Source | Purpose |
|------|--------|---------|
| 22 | **My IP** only | SSH |
| 8000 | **My IP** only | Splunk Web UI |
| 8088 | `sg-app-server` (select the security group) | HEC log ingestion from Fluent Bit |

> Never open 8088, 8089 or 8000 to `0.0.0.0/0`.

Both servers should be in the **same VPC** so Fluent Bit can talk to Splunk using its **private IP**.

---

## 3. Prerequisites checklist

- [ ] An AWS account with permission to create EC2, EBS and security groups
- [ ] An EC2 **key pair** (`.pem` file) downloaded to your laptop
- [ ] Your **public IP** (search "what is my ip") for the security groups
- [ ] Your application as a **Docker image** (public or in a registry such as ECR / Docker Hub). If you don't have one yet, this guide uses `nginx` as a stand-in
- [ ] A terminal (macOS/Linux Terminal, or Windows PowerShell / PuTTY)

### Launch the two EC2 instances

1. AWS Console → **EC2 → Launch instance**.
2. Name: `app-server`. AMI: **Ubuntu Server 22.04/24.04 LTS**. Instance type and storage from Section 2. Key pair: select yours. Security group: `sg-app-server`.
3. Repeat for `splunk-server`. Add a second EBS volume of **100 GB gp3** under *Configure storage → Add new volume*.
4. (Recommended) Allocate an **Elastic IP** and associate it with `app-server` so its address doesn't change on restart.
5. Note the **private IP** of `splunk-server` (e.g. `10.0.1.25`). You'll need it later.

### Connect over SSH

```bash
chmod 400 mykey.pem
ssh -i mykey.pem ubuntu@<PUBLIC_IP_OF_SERVER>
```

---

## 4. Install prerequisites (run on BOTH servers)

### 4.1 Update the OS

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### 4.2 Install Docker Engine + Docker Compose plugin

```bash
# Remove old/conflicting packages (safe to ignore "not installed" messages)
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null
done

# Add Docker's official repository
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 4.3 Run Docker without `sudo`

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### 4.4 Verify

```bash
docker --version
docker compose version
docker run --rm hello-world
```

You should see "Hello from Docker!".

### 4.5 Limit Docker's own log size (prevents disks filling up)

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
```

---

## 5. Set up the Splunk server (do this FIRST)

SSH into **`splunk-server`**.

### 5.1 Mount the extra 100 GB data disk

```bash
lsblk                       # find the new disk, usually nvme1n1 (100G, no mountpoint)
sudo mkfs -t ext4 /dev/nvme1n1
sudo mkdir -p /data
sudo mount /dev/nvme1n1 /data

# Make it mount automatically after reboot
UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1)
echo "UUID=$UUID /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
df -h /data
```

> Check the device name in `lsblk` first. Only format the **empty** disk. Formatting the wrong one destroys data.

### 5.2 Create the project folder

```bash
mkdir -p ~/splunk && cd ~/splunk
sudo mkdir -p /data/splunk-var /data/splunk-etc
sudo chown -R 41812:41812 /data/splunk-var /data/splunk-etc
```

> `41812` is the user ID of the `splunk` user inside the official Splunk image.

### 5.3 Create `.env`

Pick **your own** strong values. Do not use these examples.

```bash
cat > .env <<'EOF'
SPLUNK_PASSWORD=ChangeMe_Str0ng!Pass
SPLUNK_HEC_TOKEN=11111111-2222-3333-4444-555555555555
EOF
chmod 600 .env
```

- `SPLUNK_PASSWORD`: admin password for the Splunk web login (min 8 characters).
- `SPLUNK_HEC_TOKEN`: a GUID-style token that Fluent Bit uses to send logs. Generate a real one with `uuidgen`.

### 5.4 Create `docker-compose.yml`

```bash
cat > docker-compose.yml <<'EOF'
services:
  splunk:
    image: splunk/splunk:9.3
    container_name: splunk
    restart: unless-stopped
    environment:
      SPLUNK_START_ARGS: "--accept-license"
      SPLUNK_GENERAL_TERMS: "--accept-sgt-current-at-splunk-com"
      SPLUNK_PASSWORD: ${SPLUNK_PASSWORD}
      SPLUNK_HEC_TOKEN: ${SPLUNK_HEC_TOKEN}
    ports:
      - "8000:8000"   # Web UI
      - "8088:8088"   # HTTP Event Collector (log ingestion)
    volumes:
      - /data/splunk-var:/opt/splunk/var
      - /data/splunk-etc:/opt/splunk/etc
EOF
```

### 5.5 Start Splunk

```bash
docker compose up -d
docker compose logs -f splunk
```

First start takes **2–5 minutes**. Wait until you see `Ansible playbook complete` (press `Ctrl+C` to leave the logs; Splunk keeps running). Check health:

```bash
docker ps    # STATUS should become "healthy"
```

### 5.6 Log in and verify

1. Open `http://<SPLUNK_PUBLIC_IP>:8000` in your browser.
2. Username `admin`, password = your `SPLUNK_PASSWORD`.
3. Check HEC from the Splunk server itself:

```bash
curl -k https://localhost:8088/services/collector/health
# Expected: {"text":"HEC is healthy","code":17}

curl -k https://localhost:8088/services/collector/event \
  -H "Authorization: Splunk <YOUR_HEC_TOKEN>" \
  -d '{"event":"hello from curl","sourcetype":"manual"}'
# Expected: {"text":"Success","code":0}
```

4. In Splunk Web → **Search & Reporting**, search `index=main "hello from curl"`. You should see your test event.

> `-k` skips certificate checking because Splunk uses a self-signed certificate by default.

Splunk is ready.
![Step 5.6.4](media/Step%205.6.4.png)

---

## 6. Set up the application + monitoring server

SSH into **`app-server`**.

### 6.1 Folder layout

```bash
mkdir -p ~/observability/{prometheus,fluent-bit,grafana/provisioning/datasources}
cd ~/observability
```

Final structure:

```
observability/
├── docker-compose.yml
├── .env
├── prometheus/
│   └── prometheus.yml
├── fluent-bit/
│   └── fluent-bit.conf
└── grafana/
    └── provisioning/
        └── datasources/
            └── datasource.yml
```

### 6.2 Create `.env`

Replace the Splunk IP and token with **your** values from Section 5.

```bash
cat > .env <<'EOF'
# --- Splunk (the separate server) ---
SPLUNK_HOST=10.0.1.25                          # PRIVATE IP of splunk-server
SPLUNK_HEC_TOKEN=11111111-2222-3333-4444-555555555555   # same token as on Splunk

# --- Grafana ---
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=ChangeMe_Grafana_Pass

# --- Labels added to every log line ---
ENVIRONMENT=production
EOF
chmod 600 .env
```

### 6.3 Prometheus config: `prometheus/prometheus.yml`

```bash
cat > prometheus/prometheus.yml <<'EOF'
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
EOF
```

### 6.4 Grafana auto-connect to Prometheus: `grafana/provisioning/datasources/datasource.yml`

```bash
cat > grafana/provisioning/datasources/datasource.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
```

### 6.5 Fluent Bit config: `fluent-bit/fluent-bit.conf`

This is the most important file. Read the comments.

```bash
cat > fluent-bit/fluent-bit.conf <<'EOF'
[SERVICE]
    # Flush logs to Splunk every 5 seconds
    Flush               5
    # Only show warnings/errors from Fluent Bit itself (keeps its own logs small)
    Log_Level           warn
    # Built-in metrics endpoint (Prometheus scrapes this)
    HTTP_Server         On
    HTTP_Listen         0.0.0.0
    HTTP_Port           2020
    # Disk buffer: if Splunk is down, logs wait on disk instead of being lost
    storage.path        /fluent-bit/buffer
    storage.sync        normal
    storage.max_chunks_up 128

# ---------- INPUT ----------
# Receives logs from Docker's "fluentd" logging driver.
# Only containers that opt in send logs here. Fluent Bit's own logs are NEVER sent.
[INPUT]
    Name                forward
    Listen              0.0.0.0
    Port                24224
    storage.type        filesystem

# ---------- FILTERS ----------
# Safety net: drop anything that comes from the fluent-bit container (prevents loops)
[FILTER]
    Name                grep
    Match               *
    Exclude             container_name ^/?fluent-bit

# Add useful labels to every log line
[FILTER]
    Name                record_modifier
    Match               app.*
    Record              environment ${ENVIRONMENT}

# ---------- OUTPUT ----------
# Sends logs to the separate Splunk server via HTTP Event Collector (HEC)
[OUTPUT]
    Name                splunk
    Match               app.*
    Host                ${SPLUNK_HOST}
    Port                8088
    Splunk_Token        ${SPLUNK_HEC_TOKEN}
    Splunk_Send_Raw     Off
    event_sourcetype    docker:logs
    event_index         main
    TLS                 On
    # Splunk uses a self-signed cert by default, so verification is Off.
    # For production, install a real certificate and set this to On.
    TLS.Verify          Off
    Retry_Limit         10
    storage.total_limit_size 1G
EOF
```

### 6.6 Main `docker-compose.yml`

> **Replace the `app` service with your own application image.** `nginx:alpine` is just a stand-in so you can test the pipeline.

```bash
cat > docker-compose.yml <<'EOF'
services:

  # ------------------ YOUR APPLICATION ------------------
  app:
    image: nginx:alpine            # <-- REPLACE with your image, e.g. myrepo/myapp:1.0
    container_name: app
    restart: unless-stopped
    ports:
      - "80:80"                    # <-- host:container, change to your app's port
    depends_on:
      - fluent-bit
    logging:                       # sends this container's logs to Fluent Bit
      driver: fluentd
      options:
        fluentd-address: "127.0.0.1:24224"
        fluentd-async: "true"      # app still starts/runs even if Fluent Bit is down
        tag: "app.{{.Name}}"       # must start with "app." to match Fluent Bit config

  # ------------------ FLUENT BIT (log shipper) ------------------
  fluent-bit:
    image: fluent/fluent-bit:3.2
    container_name: fluent-bit
    restart: unless-stopped
    environment:
      - SPLUNK_HOST=${SPLUNK_HOST}
      - SPLUNK_HEC_TOKEN=${SPLUNK_HEC_TOKEN}
      - ENVIRONMENT=${ENVIRONMENT}
    volumes:
      - ./fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro
      - fluentbit-buffer:/fluent-bit/buffer
    ports:
      - "127.0.0.1:24224:24224"    # only reachable from this server (Docker log driver)
    logging:                       # Fluent Bit's OWN logs stay local and are size-limited
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  # ------------------ PROMETHEUS (metrics storage) ------------------
  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"     # keep 15 days of metrics
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"      # local only, use SSH tunnel to view

  # ------------------ GRAFANA (dashboards) ------------------
  grafana:
    image: grafana/grafana:11.2.0
    container_name: grafana
    restart: unless-stopped
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "3000:3000"
    depends_on:
      - prometheus

  # ------------------ NODE EXPORTER (EC2 host metrics) ------------------
  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    restart: unless-stopped
    command:
      - "--path.rootfs=/host"
    pid: host
    volumes:
      - /:/host:ro,rslave

  # ------------------ cADVISOR (container metrics) ------------------
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

volumes:
  prometheus-data:
  grafana-data:
  fluentbit-buffer:
EOF
```

### 6.7 Validate the file before starting

```bash
docker compose config > /dev/null && echo "Compose file is valid"
```

### 6.8 Start everything

Start Fluent Bit first so it's ready to receive logs, then the rest:

```bash
docker compose up -d fluent-bit
sleep 5
docker compose up -d
docker compose ps
```

All services should show `running` / `Up`.

---

## 7. Verify everything works (in this order)

### 7.1 Generate some app logs

```bash
curl -s http://localhost > /dev/null   # hit the demo app a few times
curl -s http://localhost > /dev/null
curl -s http://localhost/does-not-exist > /dev/null   # makes a 404 log line
```

### 7.2 Check Fluent Bit is healthy

```bash
docker logs fluent-bit --tail 20
```

You should see **no errors** (with `Log_Level warn` it is normally empty). Errors like `connection refused` or `no upstream connections` mean Fluent Bit can't reach Splunk. See Troubleshooting.

### 7.3 Check logs arrived in Splunk

In Splunk Web → **Search & Reporting**:

```
index=main sourcetype="docker:logs"
```

Set the time range to **Last 15 minutes**. You should see your nginx/app logs. Useful fields: `log`, `container_name`, `source` (stdout/stderr), `environment`.

Useful searches:

```
index=main sourcetype="docker:logs" source=stderr
index=main sourcetype="docker:logs" container_name="/app" "error"
```

![Step 7.3](media/Step%207.3.png)

### 7.4 Check Prometheus targets

From your laptop, open an SSH tunnel:

```bash
ssh -i mykey.pem -L 9090:localhost:9090 ubuntu@<APP_SERVER_PUBLIC_IP>
```

Then browse to `http://localhost:9090/targets`. All targets (`prometheus`, `node-exporter`, `cadvisor`, `fluent-bit`) should be **UP**.

### 7.5 Open Grafana

1. Browse to `http://<APP_SERVER_PUBLIC_IP>:3000`.
2. Log in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from your `.env`.
3. Go to **Connections → Data sources**. **Prometheus** should already be listed. Click it, then **Save & test** (should show green "Successfully queried").
4. Import ready-made dashboards: **Dashboards → New → Import**, enter an ID, click **Load**, choose the **Prometheus** data source, click **Import**.
   - **1860**: Node Exporter Full (EC2 CPU, RAM, disk, network)
   - **14282**: cAdvisor / Docker container metrics

   (Dashboard IDs come from grafana.com/grafana/dashboards. If one is ever removed, search that site for "Node Exporter Full" or "cAdvisor".)

---

## 8. Deploying your own application

1. Replace the `app` service in `docker-compose.yml` with your image and ports.
2. **Keep the `logging:` block** exactly as it is. It's what sends your logs to Fluent Bit.
3. For any other containers whose logs you want in Splunk, copy the same `logging:` block and keep `tag: "app.{{.Name}}"`.
4. If your app exposes Prometheus metrics at `/metrics`, uncomment the `my-app` job in `prometheus/prometheus.yml`, set the correct service name and port, then reload:

```bash
docker compose up -d app
docker compose restart prometheus
```

5. Private image registry (e.g. AWS ECR)? Log in first:

```bash
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin <account_id>.dkr.ecr.<region>.amazonaws.com
```

> After changing the `logging:` block of a container, you must **recreate** it: `docker compose up -d --force-recreate app`. A plain restart is not enough.
>
> `docker logs app` still works with the fluentd driver on Docker 20.10 and newer.

---

## 9. Daily operations cheat sheet

| Task | Command |
|------|---------|
| See running containers | `docker compose ps` |
| Follow logs of one service | `docker compose logs -f fluent-bit` |
| Restart one service | `docker compose restart prometheus` |
| Apply config changes (Fluent Bit) | `docker compose restart fluent-bit` |
| Apply compose file changes | `docker compose up -d` |
| Stop everything (keeps data) | `docker compose down` |
| Stop and DELETE all data | `docker compose down -v`  (**destructive**) |
| Update images | `docker compose pull && docker compose up -d` |
| Disk usage | `df -h` and `docker system df` |
| Clean unused images | `docker image prune -a` |

Access to Prometheus from your laptop: `ssh -i mykey.pem -L 9090:localhost:9090 ubuntu@<APP_SERVER_IP>` then open `http://localhost:9090`.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No logs in Splunk | Wrong time range or index | Search `index=* earliest=-15m`; widen the time picker |
| Fluent Bit: `connection refused` / `no upstream connections` to Splunk | Security group, wrong IP, or Splunk not ready | Confirm `SPLUNK_HOST` is the **private IP**; `sg-splunk-server` allows 8088 from `sg-app-server`; test with `curl -k https://<SPLUNK_IP>:8088/services/collector/health` from app-server |
| Fluent Bit: `HTTP status=403` | Wrong HEC token | Make sure `SPLUNK_HEC_TOKEN` matches on both servers; `docker compose up -d --force-recreate fluent-bit` |
| Fluent Bit: `HTTP status=400` | Index doesn't exist or token not allowed to use it | Use `event_index main`, or create the index in Splunk and allow it on the HEC token |
| Fluent Bit: TLS / certificate errors | Self-signed cert with verify on | Keep `TLS.Verify Off` (testing), or install a trusted cert |
| `docker compose up` fails with "Failed to initialize logging driver" for `app` | Fluent Bit not running yet | Start Fluent Bit first (`docker compose up -d fluent-bit`), then the app |
| Logs missing after changing `logging:` | Container not recreated | `docker compose up -d --force-recreate app` |
| Prometheus target DOWN | Wrong name/port in `prometheus.yml` | Check `http://localhost:9090/targets` error text; names must match compose service names |
| Grafana shows "No data" | Dashboard picked wrong data source, or Prometheus has no data yet | Wait 1–2 minutes; check Prometheus targets are UP |
| Splunk container restarts or is unhealthy | Not enough RAM or bad volume permissions | Use at least 8 GB RAM; `sudo chown -R 41812:41812 /data/splunk-var /data/splunk-etc` |
| Splunk won't start: license/terms error | Terms variables missing | Keep both `SPLUNK_START_ARGS` and `SPLUNK_GENERAL_TERMS` in compose (check the Splunk image docs if the variable name changed for your version) |
| Disk full | Docker logs or Prometheus data growing | Check `docker system df`; lower Prometheus retention; keep `max-size` log limits |

---

## 11. Security hardening checklist (before going to production)

- [ ] Change all example passwords and the HEC token to strong unique values
- [ ] Keep `.env` private (`chmod 600 .env`) and **never commit it to Git**
- [ ] Restrict SSH (22), Grafana (3000) and Splunk Web (8000) to known IPs, or use a VPN
- [ ] Put Grafana behind an HTTPS load balancer (ALB + ACM certificate) or Nginx with TLS
- [ ] Install a real TLS certificate on Splunk HEC and set `TLS.Verify On` in Fluent Bit
- [ ] Use AWS Secrets Manager or SSM Parameter Store instead of plain `.env` files
- [ ] Turn on EBS encryption for all volumes
- [ ] Take regular EBS snapshots (AWS Data Lifecycle Manager) of both servers
- [ ] Keep Docker images updated and pinned to specific versions

---

## 12. Quick reference: ports

| Port | Service | Server | Exposed to |
|------|---------|--------|-----------|
| 80 | Your app | app-server | Public (or your users) |
| 3000 | Grafana | app-server | Your IP only |
| 9090 | Prometheus | app-server | localhost (SSH tunnel) |
| 24224 | Fluent Bit input | app-server | localhost only |
| 2020 | Fluent Bit metrics | app-server | Docker network only |
| 8000 | Splunk Web | splunk-server | Your IP only |
| 8088 | Splunk HEC | splunk-server | app-server security group only |

---

## 13. Rollout order summary

1. Create security groups, launch both EC2 servers
2. Install Docker on both (Section 4)
3. Set up and verify **Splunk** (Section 5)
4. Create the config files on **app-server** (Section 6)
5. Start Fluent Bit, then the rest (6.8)
6. Verify logs in Splunk, targets in Prometheus, dashboards in Grafana (Section 7)
7. Replace the demo `app` with your own image (Section 8)
8. Work through the security checklist (Section 11)
