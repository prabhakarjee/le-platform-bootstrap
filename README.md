# LE-Platform: Bootstrap (V2.1)

This repository is the entry point for the "Zero-Touch" platform installation. It prepares the VPS, installs dependencies, and clones the core infrastructure.

## 🚀 Usage

To start a fresh bootstrap:
```bash
curl -sSL https://raw.githubusercontent.com/prabhakarjee/le-platform-bootstrap/master/bootstrap.sh | sudo bash
```

## 🔐 Bitwarden Secrets (Required)

Before running the bootstrap, ensure your Bitwarden vault contains these items. The script will prompt for the Master Password and API credentials to fetch the rest.

| Bitwarden Item Name | Key/Field | Description |
| :--- | :--- | :--- |
| **`Infra GitHub PAT`** | Password | Personal Access Token with repo scope for cloning private repos. |
| **`Infra Tailscale Auth Key`** | Password | Auth key from Tailscale dashboard for mesh networking. |
| **`Infra Backup Key`** | Password | Master passphrase used for GPG encryption and Postgres. |
| **`Infra Bootstrap Env`** | Notes | Must contain `PRIMARY_DOMAIN=yourdomain.com`. |

## ⚙️ What it does
1.  **System Prep**: Updates OS, installs Docker, rclone, and Bitwarden CLI.
2.  **Networking**: Joins the VPS to your Tailscale tailnet.
3.  **Core Clone**: Clones `le-platform-core` into `/opt/platform`.
4.  **Handover**: Triggers `bootstrap/platform-init.sh` from the core repository.
