# Telegram Integration Guide for OCI Hermes

This document provides complete instructions for integrating your **OCI Hermes Agent** instance with **Telegram**. Once configured, you can interact with Hermes directly via Telegram chats and groups, allowing you to trigger commands, run skills, and converse with your agent from any device.

---

## Overview & Architecture

- **Service Unit**: Hermes includes a dedicated systemd service, [`hermes-gateway.service`](../systemd/hermes-gateway.service), which runs `hermes gateway run` under the `hermes` user.
- **Connection Model**: The gateway uses Telegram's long-polling HTTP API. It initiates outbound requests to Telegram servers; **no inbound open ports, webhooks, or public IP endpoints are required**.
- **Security**: Access can (and should) be restricted to specific Telegram User IDs so that unauthorized users cannot execute tasks on your OCI VM.

---

## Step 1: Create a Telegram Bot

1. Open Telegram and search for the official **[@BotFather](https://t.me/BotFather)** account.
2. Start a chat with BotFather and send the `/newbot` command.
3. Enter a display name for your bot (e.g. `My OCI Hermes`).
4. Enter a unique username ending in `bot` (e.g. `my_oci_hermes_agent_bot`).
5. BotFather will return an **HTTP API Token** formatted like:
   ```text
   7123456789:AAFgH-xXyZ1234567890abcdefghijklmnopqrst
   ```
   > [!IMPORTANT]
   > Keep this token secret. Anyone with access to this token can control your bot.

---

## Step 2: Retrieve Your Telegram User ID

To prevent unauthorized users from interacting with your Hermes agent, restrict access to your Telegram user account (and any co-operators).

1. Search Telegram for **[@userinfobot](https://t.me/userinfobot)** or **[@RawDataBot](https://t.me/RawDataBot)**.
2. Send `/start`.
3. The bot will reply with your numerical Telegram User ID (e.g. `123456789`). Note this down.

---

## Step 3: Configure Hermes Gateway Credentials

Connect to your OCI VM over Tailscale SSH:

```sh
ssh hermes@hermes-oci.<your-tailnet>.ts.net
```

### Option A: Standard Configuration via Environment / CLI (Recommended)

1. Open the Hermes environment file `/home/hermes/.hermes/.env`:
   ```sh
   nano /home/hermes/.hermes/.env
   ```
2. Add your Telegram Bot Token and Allowed User IDs:
   ```env
   # Telegram Gateway Configuration
   TELEGRAM_BOT_TOKEN="7123456789:AAFgH-xXyZ1234567890abcdefghijklmnopqrst"
   TELEGRAM_ALLOWED_USERS="123456789"
   ```
   *(If multiple users need access, separate IDs with commas, e.g., `"123456789,987654321"`).*

3. Update `/home/hermes/.hermes/config.yaml` via the `hermes` CLI:
   ```sh
   hermes config set telegram.enabled true
   ```
   *(Or edit `~/.hermes/config.yaml` directly to ensure `telegram.enabled: true` is present).*

---

### Option B: Storing Tokens in OCI Vault (For Automated Provisioning)

If you prefer managing all credentials centrally in OCI Vault:

1. Create a secret in OCI Vault via OCI CLI on your local workstation:
   ```sh
   oci vault secret create-base64 \
     --compartment-id "<compartment-ocid>" \
     --vault-id "<vault-ocid>" \
     --key-id "<vault-key-ocid>" \
     --secret-name "hermes-telegram-bot-token" \
     --secret-content-content "$(printf '%s' 'YOUR_TELEGRAM_BOT_TOKEN' | base64 | tr -d '\n')"
   ```
2. Retrieve the secret in your cloud-init or post-deploy script and append `TELEGRAM_BOT_TOKEN` into `/home/hermes/.hermes/.env`.

---

## Step 4: Enable and Start the Gateway Service

`hermes-gateway.service` is provisioned by default on the VM but remains stopped until credentials are set.

1. Enable and start `hermes-gateway.service`:
   ```sh
   sudo systemctl enable hermes-gateway.service
   sudo systemctl start hermes-gateway.service
   ```

2. Check the service status:
   ```sh
   sudo systemctl status hermes-gateway.service
   ```
   You should see `active (running)`.

3. Monitor the live logs:
   ```sh
   journalctl -u hermes-gateway.service -f
   ```

---

## Step 5: Test & Verify Telegram Integration

1. Open Telegram and search for your bot's username (e.g. `@my_oci_hermes_agent_bot`).
2. Send a message to the bot:
   ```text
   /start
   ```
   or:
   ```text
   Hello Hermes! Can you check disk usage on OCI?
   ```
3. Hermes should respond directly in Telegram.
4. Verify from an unauthorized Telegram account: the bot should ignore or decline requests from user IDs not listed in `TELEGRAM_ALLOWED_USERS`.

---

## Operational Details & Maintenance

- **LLM Provider Rotation**: The 4-hourly model rotation script ([`scripts/rotate-provider.sh`](../scripts/rotate-provider.sh)) automatically restarts `hermes-gateway.service` so active Telegram sessions seamless update to the active LLM provider.
- **Service Management Commands**:
  - **Restart Gateway**: `sudo systemctl restart hermes-gateway.service`
  - **Stop Gateway**: `sudo systemctl stop hermes-gateway.service`
  - **Check Logs**: `journalctl -u hermes-gateway.service -n 100 --no-pager`
- **Backups**: Telegram configurations inside `/home/hermes/.hermes/.env` and `config.yaml` are included in the automated encrypted backups created by `hermes-backup.sh`.

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| `hermes-gateway.service` exits immediately | Missing `TELEGRAM_BOT_TOKEN` | Check `/home/hermes/.hermes/.env` and verify `TELEGRAM_BOT_TOKEN` is present and valid. |
| Bot ignores messages | Sender ID not allowed | Verify your numerical ID via `@userinfobot` and add it to `TELEGRAM_ALLOWED_USERS`. Restart gateway. |
| `401 Unauthorized` in `journalctl` | Invalid Bot Token | Re-copy token from BotFather, update `.env`, and restart `hermes-gateway.service`. |
| Network timeout errors | Outbound egress blocked | Verify OCI Internet Gateway connectivity and DNS resolution on the VM (`ping api.telegram.org`). |

---

## See Also

- [Runbook](RUNBOOK.md) — Main operational runbook for backups, provider rotation, and troubleshooting.
- [Systemd Gateway Unit](../systemd/hermes-gateway.service) — Service unit definition for the messaging gateway.
- [PLAN.md](../PLAN.md) — Architecture and design documentation.
