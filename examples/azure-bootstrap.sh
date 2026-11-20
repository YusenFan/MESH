#!/usr/bin/env bash
# Run with sudo after extracting the source to /home/azureuser/MESH.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip
cd /home/azureuser/MESH
sudo -u azureuser python3 -m venv .venv
sudo -u azureuser .venv/bin/pip install -r requirements.txt
sudo -u azureuser .venv/bin/python build_test_hundred.py --prepare-only
if [[ ! -f /home/azureuser/.config/mesh.env ]]; then
    install -d -m 700 -o azureuser -g azureuser /home/azureuser/.config
    install -m 600 -o azureuser -g azureuser /dev/null /home/azureuser/.config/mesh.env
    cat > /home/azureuser/.config/mesh.env <<'ENV'
OPENAI_API_KEY=
OPENAI_BASE_URL=https://api.openai.com/v1
LLM_PREMIUM_MODEL=gpt-4o
LLM_FAST_MODEL=gpt-4o-mini
ENV
fi
cat > /etc/systemd/system/mesh-hotpotqa.service <<'UNIT'
[Unit]
Description=MESH build from first 100 HotpotQA questions
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=azureuser
WorkingDirectory=/home/azureuser/MESH
EnvironmentFile=/home/azureuser/.config/mesh.env
Environment=PYTHONUNBUFFERED=1
ExecStart=/home/azureuser/MESH/.venv/bin/python /home/azureuser/MESH/build_test_hundred.py
TimeoutStartSec=infinity
RemainAfterExit=yes
UMask=0077
StandardOutput=journal
StandardError=journal
UNIT
systemctl daemon-reload
echo 'Ready: add your key to ~/.config/mesh.env, then sudo systemctl start --no-block mesh-hotpotqa'
