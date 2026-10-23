# Environment Variables Configuration (`.env`)

This repository uses an environment variables file (`.env`) to configure credentials, network endpoints, and global tags across monitoring and logging infrastructure services (such as **Fluent Bit**, **Grafana**, and **Splunk**).

Using a centralized `.env` file simplifies configuration management across development, staging, and production environments without hardcoding sensitive details inside application or container configuration files.

---

## ⚙️ Variables Overview

```env
# --- Splunk (the separate server) ---
SPLUNK_HOST=172.31.17.141                           # PRIVATE IP of splunk-server
SPLUNK_HEC_TOKEN=11111111-2222-3333-4444-555555555555   # same token as on Splunk

# --- Grafana ---
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=ChangeMe_Grafana_Pass

# --- Labels added to every log line ---
ENVIRONMENT=production
```

### Breakdown of Parameters

| Group | Parameter | Example Value | Description |
| :--- | :--- | :--- | :--- |
| **Splunk Integration** | `SPLUNK_HOST` | `172.31.17.141` | Private IP or hostname of the remote Splunk server hosting the HTTP Event Collector (HEC). |
| | `SPLUNK_HEC_TOKEN` | `11111111-2222...` | Authentication token matching the configured HEC input in Splunk Enterprise/Cloud. |
| **Grafana Auth** | `GRAFANA_ADMIN_USER` | `admin` | Initial administrator username for Grafana Web UI authentication. |
| | `GRAFANA_ADMIN_PASSWORD` | `ChangeMe_Grafana_Pass` | Default administrator password for initial login. |
| **Global Metadata** | `ENVIRONMENT` | `production` | Tag applied to log entries or container labels to identify deployment environment. |

---

## 🚀 Usage & Service Integration

This `.env` file is automatically read by `docker-compose` or loaded directly into system environment contexts.

### 1. Docker Compose Integration

When running services via Docker Compose, referencing variables in your `docker-compose.yml` automatically pulls values from this `.env` file in the same directory:

```yaml
version: '3.8'

services:
  fluent-bit:
    image: fluent/fluent-bit:latest
    environment:
      - SPLUNK_HOST=${SPLUNK_HOST}
      - SPLUNK_HEC_TOKEN=${SPLUNK_HEC_TOKEN}
      - ENVIRONMENT=${ENVIRONMENT}
    restart: always

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    ports:
      - "3000:3000"
    restart: always
```

### 2. Fluent Bit Configuration Reference

Variables set in `.env` are expanded dynamically within your `fluent-bit.conf` file using standard `${VAR}` syntax:

```ini
[FILTER]
    Name        record_modifier
    Match       app.*
    Record      environment ${ENVIRONMENT}

[OUTPUT]
    Name        splunk
    Host        ${SPLUNK_HOST}
    Splunk_Token ${SPLUNK_HEC_TOKEN}
```

---

## 🔐 Security Best Practices

1. **Never Commit Secrets to Version Control:**
   Add `.env` to your `.gitignore` file to avoid accidentally pushing passwords and sensitive API tokens to remote repositories.

   ```bash
   echo ".env" >> .gitignore
   ```

2. **Template File Creation:**
   Maintain a `.env.example` template with sanitized placeholder values for team members and CI/CD pipelines:

   ```env
   SPLUNK_HOST=your-splunk-ip
   SPLUNK_HEC_TOKEN=your-hec-token-uuid
   GRAFANA_ADMIN_USER=admin
   GRAFANA_ADMIN_PASSWORD=your-secure-password
   ENVIRONMENT=development
   ```

3. **Change Default Passwords:**
   Always replace default passwords like `ChangeMe_Grafana_Pass` with secure, randomly generated strings prior to launching in a production environment.
