
#!/bin/bash
# =============================================================
# nginx-ai-gateway — Full deployment script
# For: Ubuntu 22.04 LTS on AWS EC2 with NGINX Plus
# Usage: cd ~/nginx-ai-gateway && chmod +x scripts/setup.sh
#        sudo ./scripts/setup.sh
# =============================================================

set -e  # Exit immediately on any error
echo ""
echo "=============================================="
echo "  nginx-ai-gateway deployment"
echo "  Ubuntu 22.04 + NGINX Plus + Azure OpenAI"
echo "=============================================="
echo ""

# =============================================================
# STEP 1 — Disable broken NGINX Plus apt repos
# These repos return 400 errors when subscription token expires
# blocking all apt operations. Safe to disable temporarily.
# =============================================================
echo "[1/9] Disabling NGINX Plus apt repos (avoid 400 errors)..."
sudo find /etc/apt/sources.list.d/ -name "*nginx*" ! -name "*.bak" \
    -exec mv {} {}.bak \; 2>/dev/null || true
echo "      Done. NGINX Plus itself continues running fine."

# =============================================================
# STEP 2 — Update apt
# =============================================================
echo ""
echo "[2/9] Running apt update..."
sudo apt-get update -y
echo "      Done."

# =============================================================
# STEP 3 — Install Node.js 20 via NodeSource
# =============================================================
echo ""
echo "[3/9] Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
echo "      Node: $(node --version)"
echo "      NPM:  $(npm --version)"

# =============================================================
# STEP 4 — Install supporting tools
# =============================================================
echo ""
echo "[4/9] Installing apache2-utils (htpasswd) and certbot..."
sudo apt-get install -y apache2-utils certbot python3-certbot-nginx
echo "      Done."

# =============================================================
# STEP 5 — Setup chatbot backend
# =============================================================
echo ""
echo "[5/9] Setting up chatbot backend at /opt/routine-chatbot..."
sudo mkdir -p /opt/routine-chatbot
sudo chown ubuntu:ubuntu /opt/routine-chatbot
cp chatbot/package.json /opt/routine-chatbot/
cp chatbot/server.js /opt/routine-chatbot/
cd /opt/routine-chatbot
npm install
cd - > /dev/null
echo "      Dependencies installed."
echo "      Files: $(ls /opt/routine-chatbot)"

# =============================================================
# STEP 6 — Deploy website files
# =============================================================
echo ""
echo "[6/9] Deploying website to /var/www/routine-kushikimi..."
sudo mkdir -p /var/www/routine-kushikimi
sudo cp website/index-with-chat.html /var/www/routine-kushikimi/index.html
sudo chown -R www-data:www-data /var/www/routine-kushikimi
sudo chmod -R 755 /var/www/routine-kushikimi
echo "      Website deployed."

# =============================================================
# STEP 7 — Set up basic authentication
# =============================================================
echo ""
echo "[7/9] Setting up basic authentication..."
echo ""
echo "      Enter a username for site access:"
read -r AUTH_USER
sudo htpasswd -c /etc/nginx/.htpasswd "$AUTH_USER"
sudo chmod 640 /etc/nginx/.htpasswd
sudo chown root:www-data /etc/nginx/.htpasswd
echo "      Password file created at /etc/nginx/.htpasswd"

# =============================================================
# STEP 8 — Install and configure systemd service
# =============================================================
echo ""
echo "[8/9] Installing systemd service..."
sudo cp systemd/routine-chatbot.service /etc/systemd/system/
echo ""
echo "      *** ACTION REQUIRED ***"
echo "      You must add your Azure API key to the service file."
echo "      Opening editor now — update REPLACE_WITH_YOUR_ACTUAL_KEY"
echo "      and the AZURE_ENDPOINT with your real values."
echo ""
read -p "      Press Enter to open the editor..."
sudo nano /etc/systemd/system/routine-chatbot.service
sudo systemctl daemon-reload
sudo systemctl enable routine-chatbot
sudo systemctl start routine-chatbot
sleep 3
echo ""
echo "      Service status:"
sudo systemctl status routine-chatbot --no-pager -l
echo ""

# =============================================================
# STEP 9 — Install NGINX config
# =============================================================
echo ""
echo "[9/9] Installing NGINX Plus config..."

# Add rate limiting zone to nginx.conf if not already there
if ! sudo grep -q "chat_limit" /etc/nginx/nginx.conf; then
    echo "      Adding rate limit zone to nginx.conf..."
    sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=chat_limit:10m rate=10r/m;' \
        /etc/nginx/nginx.conf
    echo "      Rate limit zone added."
else
    echo "      Rate limit zone already exists in nginx.conf."
fi

sudo cp nginx/routine-kushikimi.conf /etc/nginx/conf.d/routine-kushikimi.conf
echo "      Testing NGINX config..."
sudo nginx -t
sudo nginx -s reload
echo "      NGINX reloaded."

# =============================================================
# Re-enable NGINX Plus repos
# =============================================================
echo ""
echo "Re-enabling NGINX Plus apt repos..."
sudo find /etc/apt/sources.list.d/ -name "*nginx*.bak" \
    -exec bash -c 'mv "$1" "${1%.bak}"' _ {} \; 2>/dev/null || true

# =============================================================
# DONE — print verification commands
# =============================================================
echo ""
echo "=============================================="
echo "  Deployment complete!"
echo "=============================================="
echo ""
echo "Now get your SSL certificate:"
echo "  sudo certbot --nginx -d routine.kushikimi.xyz"
echo ""
echo "Then verify everything works:"
echo ""
echo "  1. Health check:"
echo "     curl http://127.0.0.1:3001/health"
echo ""
echo "  2. Test chat locally:"
echo "     curl -X POST http://127.0.0.1:3001/chat \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"messages\":[{\"role\":\"user\",\"content\":\"What should I eat for lunch?\"}]}'"
echo ""
echo "  3. Test auth is working (should return 401):"
echo "     curl -I https://routine.kushikimi.xyz"
echo ""
echo "  4. Test full stack with auth:"
echo "     curl -X POST https://routine.kushikimi.xyz/api/chat \\"
echo "       -u yourusername:yourpassword \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"messages\":[{\"role\":\"user\",\"content\":\"What is my skincare tonight?\"}]}'"
echo ""