# nginx-llm-proxy

A static site on AWS EC2 with NGINX Plus,
featuring a context-aware AI chat assistant proxied through a
secured Node.js backend to Azure OpenAI.

> The stack is intentionally minimal: one Ubuntu server, one HTML
> file, one Node.js process, one NGINX Plus config. No Kubernetes,
> no Lambda, no managed API gateway. Just the fundamentals,
> done properly.

---

## What this actually is

Most "AI chat on a website" tutorials use Vercel, Firebase, or
managed platforms that abstract everything away. This repo does it
the infrastructure way — every layer is explicit and owned:

- A single Ubuntu 22.04 EC2 instance running NGINX Plus
- NGINX Plus acts as SSL terminator, static file server,
  reverse proxy, rate limiter, and auth layer — all in one process
- A Node.js Express app runs on localhost:3001, invisible to the
  internet, proxying chat requests to Azure OpenAI
- The AI is given a rich system prompt so it answers as a
  domain-specific assistant, not a generic chatbot
- Basic auth protects the entire site at the NGINX layer
- Everything is reproducible from this repo in under 15 minutes

---

## Architecture
```
User Browser
     │
     │ HTTPS :443
     ▼
┌─────────────────────────────────────────┐
│             NGINX Plus                  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │  SSL Termination (Let's Encrypt)  │  │
│  └───────────────────────────────────┘  │
│  ┌───────────────────────────────────┐  │
│  │  Basic Auth (/etc/nginx/.htpasswd)│  │
│  └───────────────────────────────────┘  │
│  ┌────────────────┐ ┌────────────────┐  │
│  │  Static Site   │ │  /api/chat     │  │
│  │  /var/www/     │ │  rate limited  │  │
│  │  index.html    │ │  10 req/min    │  │
│  └────────────────┘ └───────┬────────┘  │
└───────────────────────────────│──────────┘
                                │ proxy_pass
                                │ 127.0.0.1:3001
                                ▼
               ┌──────────────────────────┐
               │   Node.js Express        │
               │   (127.0.0.1 only)       │
               │                          │
               │  1. Validates request    │
               │  2. Injects full system  │
               │     prompt context       │
               │  3. Calls Azure API      │
               │  4. Returns reply        │
               └────────────┬─────────────┘
                            │ HTTPS POST
                            │ api-key: header
                            ▼
               ┌──────────────────────────┐
               │   Azure OpenAI           │
               │   gpt-4o-mini            │
               │   East US 2              │
               └──────────────────────────┘
```

---

## AI concepts explained

### Is this RAG?

**No — but it achieves a similar goal through a simpler mechanism
called a stuffed system prompt (static context injection).**

Understanding the difference matters for knowing when to use each:

**RAG (Retrieval-Augmented Generation)** is an architecture where:
1. A knowledge base is chunked into small pieces
2. Each chunk is converted to a vector embedding (a list of numbers
   representing semantic meaning) and stored in a vector database
3. When a user asks a question, the query is also embedded
4. The vector database finds the most semantically similar chunks
   using cosine similarity
5. Those chunks are dynamically injected into the prompt
6. The model answers using retrieved context it was never trained on

RAG is the right pattern when your knowledge base is:
- Large (thousands of documents, books, manuals)
- Larger than the model's context window
- Frequently updated (daily news, live inventory, support tickets)
- Multi-source (PDFs, databases, websites combined)

Tools typically used for RAG: LangChain, LlamaIndex, Azure AI Search,
Pinecone, pgvector.

**What this project uses instead** is called **static context injection**:
- All domain knowledge is written directly into the system prompt
  in `server.js` as a structured plain-text string
- Every API call sends this full context to the model
- The model reads the entire context fresh each time
- No vector database, no embedding model, no retrieval pipeline

This works well here because:
- The knowledge base is small (~800 tokens — fits easily in one prompt)
- Content is stable (a personal protocol doesn't change hourly)
- Zero infrastructure overhead — no vector DB to manage or cost
- Deterministic — model always has the full picture, nothing missed
  by imperfect retrieval

### Context window vs RAG — when to use which

| Scenario | Approach |
|---|---|
| Small stable knowledge base < 20k tokens | Stuffed system prompt (this project) |
| Medium knowledge, some retrieval needed | Hybrid: top context + RAG for details |
| Large knowledge base > 100k tokens | Full RAG with vector DB |
| Real-time or frequently updated data | RAG with live data connectors |
| Multiple documents or user uploads | RAG with per-session indexing |

### How the system prompt shapes model behaviour

The system prompt in `server.js` does four things:

**1. Persona definition** — tells the model who it is, what scope
it operates in, and its communication style. Without this, gpt-4o-mini
is a generic assistant. With it, every response is grounded in the
specific domain.

**2. Knowledge injection** — structured facts written in clear
labelled sections (schedule, food options, product names, doses).
The model references these when constructing answers, exactly like
a human reading a briefing document.

**3. Behavioural constraints** — instructions like "suggest actual
hawker options", "be concise unless detail requested", "never
contradict the protocol" steer output style and keep responses
on-topic and practically useful.

**4. Context window management** — the proxy keeps only the last
10 messages per session (`messages.slice(-10)`). This prevents the
context window growing unbounded across long conversations while
preserving enough conversational memory to be coherent.

### Token economics per request
```
System prompt:        ~800 tokens  (sent with every request)
Conversation history: ~200 tokens  (last 10 messages average)
User message:          ~20 tokens
Model response:       ~150 tokens  (max_tokens capped at 500)
─────────────────────────────────────────────────────────────
Total per request:   ~1170 tokens
```

At Azure OpenAI gpt-4o-mini pricing:
- Input:  ~$0.00015 per 1k tokens
- Output: ~$0.00060 per 1k tokens
- Per conversation: ~$0.0002 (effectively free for personal use)

### Why proxy through Node.js instead of calling Azure from the browser?

Calling AI APIs directly from frontend JavaScript exposes your API key
in the browser's DevTools → Network tab. Anyone who opens your site
can see the key and use your Azure quota.

The proxy pattern solves this:
```
Browser → /api/chat (your domain) → Node.js (holds key in env var)
       → Azure OpenAI (never sees browser, only your server)
```

The API key exists only in server memory as an environment variable.
It is never written to any file accessible from the web, never appears
in browser traffic, never in git history.

---

## Repository structure
```
nginx-ai-gateway/
├── README.md                      # This file
├── .gitignore                     # Excludes .env, node_modules, .htpasswd
├── .env.example                   # Template — copy to .env on server
├── nginx/
│   └── routine-kushikimi.conf     # NGINX Plus server block (full)
├── chatbot/
│   ├── package.json               # Node.js dependencies
│   └── server.js                  # Express proxy + system prompt
├── website/
│   ├── index.html                 # Static site without chatbox
│   └── index-with-chat.html       # Production site with chat widget
├── scripts/
│   ├── setup.sh                   # Automated full deployment script
│   └── toggle-nginx-repos.sh      # Fix NGINX Plus apt repo errors
└── systemd/
    └── routine-chatbot.service    # Systemd unit — auto-start Node.js
```

---

## Prerequisites

Before starting you need:

- Ubuntu 22.04 LTS EC2 instance on AWS (t2.micro works fine)
- NGINX Plus installed and running (`nginx -v` to verify)
- A domain with an A record pointing to your server's public IP
- An Azure OpenAI resource with a deployed model
- SSH access to the server

### AWS Security Group — required inbound rules

| Type | Protocol | Port | Source | Reason |
|------|----------|------|--------|--------|
| SSH | TCP | 22 | Your IP only | Server access |
| HTTP | TCP | 80 | 0.0.0.0/0 | Certbot + redirect |
| HTTPS | TCP | 443 | 0.0.0.0/0 | Site traffic |

**Port 3001 must NOT be open** — Node.js binds to 127.0.0.1 only
and is accessed by NGINX internally. Opening it publicly would
bypass all auth and rate limiting.

---

## Full deployment from scratch

### Step 1 — SSH into your server
```bash
ssh -i your-key.pem ubuntu@YOUR_EC2_PUBLIC_IP
```

### Step 2 — Clone this repository
```bash
cd ~
git clone https://github.com/YOURUSERNAME/nginx-ai-gateway.git
cd nginx-ai-gateway
```

### Step 3 — Fix NGINX Plus apt repo errors

NGINX Plus subscription repos return 400 Bad Request when the
subscription JWT token expires. This blocks ALL apt operations.
Disable them before installing anything.
```bash
# Check which nginx repo files exist
ls /etc/apt/sources.list.d/ | grep nginx

# Disable all of them by renaming to .bak
# The running NGINX Plus instance is completely unaffected
sudo find /etc/apt/sources.list.d/ -name "*nginx*" ! -name "*.bak" \
    -exec mv {} {}.bak \;

# Verify apt now runs cleanly — no more 400 errors
sudo apt update
```

Why this happens in detail: NGINX Plus repos at pkgs.nginx.com
require a valid JWT token embedded in the repo URL. The token is
tied to your NGINX Plus subscription. When it expires, every
`apt update` fails with 400. Your running NGINX Plus binary keeps
working — only the package update mechanism breaks. Fix the token
permanently by regenerating it in your F5/NGINX portal at
https://my.f5.com.

### Step 4 — Install Node.js 20
```bash
# Download NodeSource setup script and add the repo
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -

# Install Node.js (npm is included)
sudo apt-get install -y nodejs

# Verify versions
node --version   # expect v20.x.x
npm --version    # expect 10.x.x
```

If you previously ran this and hit Ctrl+C before it finished,
run it again — the script is idempotent.

### Step 5 — Install supporting tools
```bash
sudo apt-get install -y apache2-utils certbot python3-certbot-nginx
```

- `apache2-utils` — provides `htpasswd` for creating basic auth passwords
- `certbot` — free SSL certificates from Let's Encrypt
- `python3-certbot-nginx` — certbot plugin that auto-configures NGINX

### Step 6 — Set up the chatbot backend
```bash
# Create app directory owned by ubuntu user
sudo mkdir -p /opt/routine-chatbot
sudo chown ubuntu:ubuntu /opt/routine-chatbot

# Copy files from repo
cp chatbot/package.json /opt/routine-chatbot/
cp chatbot/server.js /opt/routine-chatbot/

# Install Node.js dependencies
cd /opt/routine-chatbot
npm install

# Verify node_modules created
ls node_modules | grep express     # should show: express
ls node_modules | grep node-fetch  # should show: node-fetch
ls node_modules | grep cors        # should show: cors

cd ~
```

### Step 7 — Test the backend manually

Test before making it a service — easier to debug.
```bash
cd /opt/routine-chatbot

# Set env vars and start
AZURE_API_KEY=your_key_here \
AZURE_ENDPOINT=your_endpoint_here \
node server.js

# Expected output:
# Chatbot proxy running on port 3001
# Azure endpoint: configured
# API key: configured
```

Open a second SSH terminal and test:
```bash
curl -X POST http://127.0.0.1:3001/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello test"}]}'

# Expected: {"reply":"Hello! How can I help..."}
```

If you get a valid reply, Ctrl+C the server and continue to Step 8.

### Step 8 — Install as a systemd service
```bash
# Copy service file from repo
sudo cp systemd/routine-chatbot.service /etc/systemd/system/

# Edit it — add your real API key and endpoint
sudo nano /etc/systemd/system/routine-chatbot.service
```

Update these two lines with your real values:
```ini
Environment=AZURE_API_KEY=your_actual_azure_key_here
Environment=AZURE_ENDPOINT=https://your-resource.openai.azure.com/openai/deployments/your-deployment/chat/completions?api-version=2024-02-01
```
```bash
# Reload systemd to pick up new service file
sudo systemctl daemon-reload

# Enable — auto-starts on server reboot
sudo systemctl enable routine-chatbot

# Start it now
sudo systemctl start routine-chatbot

# Verify running
sudo systemctl status routine-chatbot
# Look for: Active: active (running)

# Confirm it's listening on the right port
sudo lsof -i :3001
# Look for: node  ...  127.0.0.1:3001 (LISTEN)
```

### Step 9 — Deploy the website
```bash
# Create web root
sudo mkdir -p /var/www/routine-kushikimi

# Deploy production HTML (with chat widget embedded)
sudo cp website/index-with-chat.html /var/www/routine-kushikimi/index.html

# Set ownership so NGINX can read the files
sudo chown -R www-data:www-data /var/www/routine-kushikimi
sudo chmod -R 755 /var/www/routine-kushikimi

# Verify
ls -la /var/www/routine-kushikimi/
```

### Step 10 — Set up basic authentication
```bash
# Create password file with your username
# -c flag creates the file (only use -c for the very first user)
sudo htpasswd -c /etc/nginx/.htpasswd yourusername
# Enter password at prompt
# Confirm password at prompt

# Verify file created — password is hashed, not readable
cat /etc/nginx/.htpasswd
# yourusername:$apr1$...hashedpassword...

# Secure the file — only root and www-data can read it
sudo chmod 640 /etc/nginx/.htpasswd
sudo chown root:www-data /etc/nginx/.htpasswd
```

Managing users after initial setup:
```bash
# Add a second user (no -c flag — would overwrite existing)
sudo htpasswd /etc/nginx/.htpasswd seconduser

# Change a password (same command as add, overwrites entry)
sudo htpasswd /etc/nginx/.htpasswd yourusername

# Remove a user
sudo htpasswd -D /etc/nginx/.htpasswd username

# List all users (passwords are bcrypt hashed, unreadable)
cat /etc/nginx/.htpasswd
```

### Step 11 — Configure NGINX Plus
```bash
# Add rate limiting zone to nginx.conf http block
# Check if already exists first
sudo grep -n "chat_limit" /etc/nginx/nginx.conf
```

If not found, add it:
```bash
sudo nano /etc/nginx/nginx.conf
```

Find the `http {` line and add immediately after it:
```nginx
http {
    limit_req_zone $binary_remote_addr zone=chat_limit:10m rate=10r/m;
    # ... rest of existing config unchanged
}
```
```bash
# Copy site config from repo
sudo cp nginx/routine-kushikimi.conf /etc/nginx/conf.d/routine-kushikimi.conf

# ALWAYS test syntax before reloading — catches errors before they break live site
sudo nginx -t
# Expected: nginx: configuration file ... syntax is ok
#           nginx: configuration file ... test is successful

# Reload gracefully — no dropped connections
sudo nginx -s reload
```

### Step 12 — Get SSL certificate

DNS must resolve to your server IP before certbot will work.
```bash
# Verify DNS propagated (run from server or local machine)
dig routine.yourdomain.xyz +short
# Must return your EC2 public IP before continuing

# Get certificate — certbot auto-edits your NGINX config
sudo certbot --nginx -d routine.kushikimi.xyz

# Follow the prompts:
# - Enter your email (for renewal reminders)
# - Agree to terms of service: A
# - Share email with EFF (optional): N or Y
# Certbot will add SSL config to your NGINX server block automatically

# Verify auto-renewal works
sudo certbot renew --dry-run
# Expected: Congratulations, all simulated renewals succeeded
```

### Step 13 — Re-enable NGINX Plus repos
```bash
sudo find /etc/apt/sources.list.d/ -name "*nginx*.bak" \
    -exec bash -c 'mv "$1" "${1%.bak}"' _ {} \;
```

### Step 14 — Full verification

Run all five checks — all must pass:
```bash
# 1. Node.js health check
curl http://127.0.0.1:3001/health
# {"status":"ok","configured":true,...}

# 2. Chat works directly to Node (bypasses NGINX)
curl -X POST http://127.0.0.1:3001/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What should I eat for lunch?"}]}'
# {"reply":"For lunch...chicken rice..."}

# 3. Site returns 401 without credentials (basic auth working)
curl -I https://routine.kushikimi.xyz
# HTTP/2 401

# 4. Site loads with correct credentials
curl -I -u yourusername:yourpassword https://routine.kushikimi.xyz
# HTTP/2 200

# 5. Full stack: browser → NGINX → Node → Azure
curl -X POST https://routine.kushikimi.xyz/api/chat \
  -u yourusername:yourpassword \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is my skincare tonight?"}]}'
# {"reply":"Tonight is..."}
```

All five passing = production ready.

---

## Updating the deployment

### Update website only
```bash
cd ~/nginx-ai-gateway
git pull
sudo cp website/index-with-chat.html /var/www/routine-kushikimi/index.html
# No restart needed — NGINX serves static files directly
```

### Update chatbot backend
```bash
cd ~/nginx-ai-gateway
git pull
cp chatbot/server.js /opt/routine-chatbot/
sudo systemctl restart routine-chatbot
sudo systemctl status routine-chatbot
```

### Update NGINX config
```bash
cd ~/nginx-ai-gateway
git pull
sudo cp nginx/routine-kushikimi.conf /etc/nginx/conf.d/
sudo nginx -t && sudo nginx -s reload
```

### Full redeploy (all components)
```bash
cd ~/nginx-ai-gateway
git pull
sudo cp website/index-with-chat.html /var/www/routine-kushikimi/index.html
cp chatbot/package.json /opt/routine-chatbot/
cp chatbot/server.js /opt/routine-chatbot/
cd /opt/routine-chatbot && npm install && cd ~/nginx-ai-gateway
sudo systemctl restart routine-chatbot
sudo cp nginx/routine-kushikimi.conf /etc/nginx/conf.d/
sudo nginx -t && sudo nginx -s reload
```

---

## Troubleshooting

### apt update fails with 400 errors from pkgs.nginx.com
```bash
# Symptom
E: Failed to fetch https://pkgs.nginx.com/plus/ubuntu/... 400 Bad Request

# Cause
# NGINX Plus subscription JWT token expired or invalid in repo URL

# Temporary fix (allows apt to work now)
sudo find /etc/apt/sources.list.d/ -name "*nginx*" ! -name "*.bak" \
    -exec mv {} {}.bak \;
sudo apt update
# install what you need, then re-enable:
sudo find /etc/apt/sources.list.d/ -name "*nginx*.bak" \
    -exec bash -c 'mv "$1" "${1%.bak}"' _ {} \;

# Permanent fix
# Regenerate your NGINX Plus licence token at https://my.f5.com
# Update the JWT token in /etc/apt/sources.list.d/nginx-plus.list
# The token appears in the repo URL after /jwt/
```

### npm: command not found after NodeSource setup
```bash
# Cause: NodeSource script was interrupted (Ctrl+C) before finishing

# Fix: run the full sequence again cleanly
sudo find /etc/apt/sources.list.d/ -name "*nginx*" ! -name "*.bak" \
    -exec mv {} {}.bak \;
sudo apt-get clean
sudo apt update
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
npm --version
```

### systemctl status shows service failed
```bash
# Get detailed error output
sudo journalctl -u routine-chatbot -n 50 --no-pager

# Common cause 1: wrong path to node binary
which node
# Update ExecStart in service file to match:
sudo nano /etc/systemd/system/routine-chatbot.service
# Change: ExecStart=/usr/bin/node server.js
# To wherever which node shows, e.g. /usr/local/bin/node
sudo systemctl daemon-reload && sudo systemctl restart routine-chatbot

# Common cause 2: placeholder key not replaced
sudo grep "AZURE_API_KEY" /etc/systemd/system/routine-chatbot.service
# If it shows REPLACE_WITH_YOUR_ACTUAL_KEY, update it:
sudo nano /etc/systemd/system/routine-chatbot.service
sudo systemctl daemon-reload && sudo systemctl restart routine-chatbot

# Common cause 3: node_modules missing
ls /opt/routine-chatbot/node_modules | head -5
# If empty: cd /opt/routine-chatbot && npm install
sudo systemctl restart routine-chatbot

# Common cause 4: port 3001 already in use
sudo lsof -i :3001
# Kill the conflicting process, then restart
```

### NGINX config test fails (nginx -t errors)
```bash
# Error: unknown directive "limit_req"
# Fix: add zone definition to nginx.conf http block
sudo grep -n "http {" /etc/nginx/nginx.conf
sudo nano /etc/nginx/nginx.conf
# Add inside http { }:
# limit_req_zone $binary_remote_addr zone=chat_limit:10m rate=10r/m;

# Error: cannot load certificate /etc/letsencrypt/live/...
# Fix: get cert first, or comment out SSL lines until cert exists
sudo certbot --nginx -d routine.kushikimi.xyz

# Error: open() "/etc/nginx/.htpasswd" failed
# Fix: create password file
sudo htpasswd -c /etc/nginx/.htpasswd yourusername

# Error: conflicting server name with another config
sudo grep -r "server_name" /etc/nginx/conf.d/
# Remove or rename the conflicting config file
```

### Chat widget returns 401 Unauthorized
```bash
# Symptom: chat shows "Connection error" after you've logged into the site

# Cause: fetch() in the HTML is missing credentials: 'include'
# The browser has basic auth cached but doesn't send it on fetch by default

# Fix: in website/index-with-chat.html find the fetch call and add:
# credentials: 'include'

const res = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',   // ADD THIS LINE
    body: JSON.stringify({ messages: history })
});

# Test the API directly with credentials to confirm it works:
curl -X POST https://routine.kushikimi.xyz/api/chat \
  -u yourusername:yourpassword \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"test"}]}'
```

### Chat returns 502 Bad Gateway
```bash
# Cause: Node.js backend not running or not on port 3001

# Check service
sudo systemctl status routine-chatbot

# Restart it
sudo systemctl restart routine-chatbot

# Verify it's listening
sudo lsof -i :3001
# Must show: node ... 127.0.0.1:3001 (LISTEN)

# Confirm NGINX can reach it
curl http://127.0.0.1:3001/health
# {"status":"ok",...}
```

### Chat returns 429 Too Many Requests
```bash
# Cause: rate limit hit — 10 requests/min per IP (intentional)
# This protects your Azure quota from abuse

# Adjust the rate if needed
sudo nano /etc/nginx/nginx.conf
# Change: rate=10r/m  to  rate=30r/m  or  rate=1r/s

sudo nginx -t && sudo nginx -s reload
```

### Azure OpenAI returns errors
```bash
# Test the Azure endpoint directly from your server
curl -X POST "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT/chat/completions?api-version=2024-02-01" \
  -H "Content-Type: application/json" \
  -H "api-key: YOUR_KEY" \
  -d '{
    "messages": [{"role":"user","content":"hello"}],
    "temperature": 0.7,
    "max_tokens": 100
  }'

# 401: API key wrong or revoked — regenerate in Azure portal
# 400: Request malformed — check deployment name in URL exactly matches Azure
# 404: Deployment name not found — check Azure OpenAI Studio deployments
# 429: Quota exceeded — check Azure OpenAI quota limits in portal
# 500: Azure-side error — retry, check Azure status page
```

### SSL certificate problems
```bash
# Check certificate status and expiry
sudo certbot certificates

# Force renewal now
sudo certbot renew --force-renewal

# Certbot auto-renewal runs via systemd timer
sudo systemctl status certbot.timer
# Should show: active (waiting)

# If NGINX doesn't reload automatically after cert renewal
# create a deploy hook:
sudo nano /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
```
```bash
#!/bin/bash
/usr/sbin/nginx -s reload
```
```bash
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
```

### Server rebooted and site is down
```bash
# Check both services
sudo systemctl status nginx
sudo systemctl status routine-chatbot

# Start if either is stopped
sudo systemctl start nginx
sudo systemctl start routine-chatbot

# Ensure both auto-start on reboot
sudo systemctl enable nginx
sudo systemctl enable routine-chatbot

# Confirm enabled status
sudo systemctl is-enabled nginx           # should print: enabled
sudo systemctl is-enabled routine-chatbot # should print: enabled
```

### NGINX Plus not serving the right site (another config conflicting)
```bash
# List all active NGINX configs
ls /etc/nginx/conf.d/
ls /etc/nginx/sites-enabled/

# Check for duplicate server_name entries
sudo grep -r "routine.kushikimi.xyz" /etc/nginx/

# Check which config NGINX loaded
sudo nginx -T | grep -A 20 "routine.kushikimi.xyz"

# Check NGINX error log for clues
sudo tail -50 /var/log/nginx/error.log
```

---

## Daily operational commands
```bash
# =============================================
# SERVICE STATUS
# =============================================

# Check both services at once
sudo systemctl status nginx routine-chatbot

# Watch chatbot logs live
sudo journalctl -u routine-chatbot -f

# View last 100 chatbot log lines
sudo journalctl -u routine-chatbot -n 100 --no-pager

# Watch NGINX access log live
sudo tail -f /var/log/nginx/access.log

# Watch NGINX error log live
sudo tail -f /var/log/nginx/error.log

# =============================================
# NGINX PLUS
# =============================================

# Test config syntax (always before reloading)
sudo nginx -t

# Reload config gracefully (no dropped connections)
sudo nginx -s reload

# Full restart (drops active connections — avoid in production)
sudo systemctl restart nginx

# Check NGINX Plus version
nginx -v

# Check compiled modules
nginx -V

# Show full running config (all includes merged)
sudo nginx -T

# =============================================
# NODE.JS SERVICE
# =============================================

# Restart chatbot
sudo systemctl restart routine-chatbot

# Check if Node is listening on port 3001
sudo lsof -i :3001

# Test health check
curl http://127.0.0.1:3001/health

# Test chat locally
curl -X POST http://127.0.0.1:3001/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What do I eat for lunch?"}]}'

# =============================================
# BASIC AUTH MANAGEMENT
# =============================================

# Add user
sudo htpasswd /etc/nginx/.htpasswd newuser

# Remove user
sudo htpasswd -D /etc/nginx/.htpasswd username

# Change password
sudo htpasswd /etc/nginx/.htpasswd username

# List all users
cat /etc/nginx/.htpasswd

# =============================================
# DEPLOYMENT
# =============================================

# Deploy website update only
sudo cp website/index-with-chat.html /var/www/routine-kushikimi/index.html

# Deploy backend update
cp chatbot/server.js /opt/routine-chatbot/
sudo systemctl restart routine-chatbot

# Deploy NGINX config update
sudo cp nginx/routine-kushikimi.conf /etc/nginx/conf.d/
sudo nginx -t && sudo nginx -s reload

# =============================================
# SERVER HEALTH
# =============================================

# Disk usage
df -h

# Memory usage
free -h

# CPU and processes
top

# Better process viewer (install if needed)
sudo apt install htop && htop

# =============================================
# CERTBOT / SSL
# =============================================

# Check cert expiry
sudo certbot certificates

# Test renewal without renewing
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal

# Check auto-renewal timer
sudo systemctl status certbot.timer

# =============================================
# NGINX PLUS REPO FIX
# =============================================

# Disable repos (before apt operations)
./scripts/toggle-nginx-repos.sh disable

# Re-enable repos (after apt operations)
./scripts/toggle-nginx-repos.sh enable

# Check current state
./scripts/toggle-nginx-repos.sh status
```

---

## Security checklist

- [x] API key stored only in systemd service Environment — never
      in code files, never in git, never in logs
- [x] Node.js bound to 127.0.0.1:3001 — completely invisible
      to the internet, only accessible by NGINX internally
- [x] NGINX rate limiting on /api/chat — 10 req/min per IP,
      prevents API quota abuse
- [x] Basic auth on entire site — 401 returned before any
      HTML, CSS, or JS is served
- [x] CORS in server.js restricted to your domain only
- [x] AWS Security Group: only ports 22, 80, 443 open inbound
- [x] .htpasswd excluded from git via .gitignore
- [x] .env excluded from git via .gitignore
- [x] SSL/TLS via Let's Encrypt with automatic renewal
- [x] Security headers: X-Frame-Options, X-Content-Type-Options,
      Referrer-Policy, X-XSS-Protection

---

## Tech stack

| Component | Version |
|-----------|---------|
| Ubuntu | 22.04 LTS (Jammy Jellyfish) |
| NGINX Plus | R30+ |
| Node.js | 20.x LTS |
| Express | 4.18.x |
| node-fetch | 2.7.x |
| Azure OpenAI | gpt-4o-mini, api-version 2024-02-01 |
| Let's Encrypt | certbot 2.x |

---

## Licence

MIT
