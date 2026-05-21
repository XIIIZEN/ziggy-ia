#!/bin/bash
# ============================================
# ZIGGY AI - INSTALLATION v5.1
# Vast.ai + Open WebUI + Interpreter + Cloudflare
# ============================================
set -e

wait_for_http() {
  local url=$1; local name=$2; local timeout=${3:-180}; local elapsed=0
  echo -n "Attente ${name}..."
  while [ $elapsed -lt $timeout ]; do
    local code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [ "$code" = "200" ] || [ "$code" = "307" ] || [ "$code" = "404" ]; then
      echo " OK (HTTP $code, ${elapsed}s)"; return 0
    fi
    sleep 3; elapsed=$((elapsed + 3)); echo -n "."
  done
  echo " TIMEOUT"; return 1
}

echo "============================================"
echo " ZIGGY AI v5.1 - Bootstrap"
echo "============================================"

apt-get update -qq
apt-get install -y -qq curl wget git python3-venv pciutils lsof

# Cloudflared
if [ ! -f /usr/local/bin/cloudflared ]; then
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

# Ollama
command -v ollama &>/dev/null || curl -fsSL https://ollama.com/install.sh | sh
mkdir -p /workspace/ollama-models /workspace/openwebui-data
export OLLAMA_MODELS=/workspace/ollama-models
export OLLAMA_HOST=0.0.0.0
pkill -f "ollama serve" 2>/dev/null || true
sleep 2
nohup ollama serve > /workspace/ollama.log 2>&1 &
wait_for_http "http://localhost:11434/api/tags" "Ollama" 30

# Modele selon VRAM
VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
if [ "$VRAM" -ge 70000 ]; then
  MODEL="qwen2.5:72b"
elif [ "$VRAM" -ge 40000 ]; then
  MODEL="qwen2.5:32b"
elif [ "$VRAM" -ge 20000 ]; then
  MODEL="qwen2.5:14b"
else
  MODEL="qwen2.5:7b"
fi
echo "VRAM ${VRAM} MB -> pull ${MODEL}..."
ollama pull "${MODEL}" || true

# Open WebUI
if [ ! -d /workspace/venv-openwebui ]; then
  python3 -m venv /workspace/venv-openwebui
  /workspace/venv-openwebui/bin/pip install --upgrade pip setuptools --quiet
  /workspace/venv-openwebui/bin/pip install --quiet open-webui
fi
pkill -f "open-webui serve" 2>/dev/null || true
sleep 2
DATA_DIR=/workspace/openwebui-data \
OLLAMA_BASE_URL=http://localhost:11434 \
nohup /workspace/venv-openwebui/bin/open-webui serve --host 0.0.0.0 --port 7860 \
  > /workspace/openwebui.log 2>&1 &
wait_for_http "http://localhost:7860" "Open WebUI" 300

# Open Interpreter (avec fix setuptools)
if [ ! -d /workspace/venv-interpreter ]; then
  python3 -m venv /workspace/venv-interpreter
  /workspace/venv-interpreter/bin/pip install --upgrade pip setuptools --quiet
  /workspace/venv-interpreter/bin/pip install --quiet open-interpreter
fi
/workspace/venv-interpreter/bin/pip install --upgrade --quiet setuptools

mkdir -p /root/.config/open-interpreter
cat > /root/.config/open-interpreter/config.yaml << EOF
model: ollama/${MODEL}
api_base: http://localhost:11434
context_window: 8000
max_tokens: 4096
offline: true
safe_mode: off
auto_run: true
EOF

pkill -f "interpreter --server" 2>/dev/null || true
sleep 2
nohup /workspace/venv-interpreter/bin/interpreter --server --host 0.0.0.0 --port 8000 \
  > /workspace/interpreter.log 2>&1 &
wait_for_http "http://localhost:8000/v1/models" "Interpreter" 60 || \
  echo "Interpreter KO - check /workspace/interpreter.log"

# Tunnel Cloudflare
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 2
nohup cloudflared tunnel --url http://localhost:7860 > /workspace/tunnel.log 2>&1 &
echo -n "Attente URL Cloudflare..."
PUBLIC_URL=""
for i in {1..30}; do
  PUBLIC_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /workspace/tunnel.log 2>/dev/null | head -1)
  [ -n "$PUBLIC_URL" ] && break
  sleep 2
  echo -n "."
done
echo ""

# Scripts utilitaires
cat > /workspace/ziggy-url.sh << 'URLEOF'
#!/bin/bash
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /workspace/tunnel.log 2>/dev/null | head -1)
if [ -z "$URL" ]; then
  echo "Pas d'URL trouvee"
else
  echo "URL: ${URL}"
fi
URLEOF
chmod +x /workspace/ziggy-url.sh

cat > /workspace/ziggy-status.sh << 'STATEOF'
#!/bin/bash
echo "============================================"
ps aux | grep -E "ollama serve|open-webui|interpreter --server|cloudflared tunnel" | grep -v grep | awk '{print "  OK ", $11, $12, $13}'
echo ""
curl -s -o /dev/null -w "  WebUI       : HTTP %{http_code}\n" http://localhost:7860 || echo "  WebUI : OFF"
curl -s -o /dev/null -w "  Interpreter : HTTP %{http_code}\n" http://localhost:8000/v1/models || echo "  Interpreter : OFF"
curl -s -o /dev/null -w "  Ollama      : HTTP %{http_code}\n" http://localhost:11434/api/tags || echo "  Ollama : OFF"
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /workspace/tunnel.log 2>/dev/null | head -1)
[ -n "$URL" ] && echo "  URL : $URL"
echo "============================================"
STATEOF
chmod +x /workspace/ziggy-status.sh

cat > /workspace/ziggy-start.sh << 'STARTEOF'
#!/bin/bash
export OLLAMA_MODELS=/workspace/ollama-models
export OLLAMA_HOST=0.0.0.0
pkill -f "cloudflared tunnel" 2>/dev/null
pkill -f "interpreter --server" 2>/dev/null
pkill -f "open-webui serve" 2>/dev/null
pkill -f "ollama serve" 2>/dev/null
sleep 3
nohup ollama serve > /workspace/ollama.log 2>&1 &
sleep 8
DATA_DIR=/workspace/openwebui-data OLLAMA_BASE_URL=http://localhost:11434 \
  nohup /workspace/venv-openwebui/bin/open-webui serve --host 0.0.0.0 --port 7860 > /workspace/openwebui.log 2>&1 &
nohup /workspace/venv-interpreter/bin/interpreter --server --host 0.0.0.0 --port 8000 > /workspace/interpreter.log 2>&1 &
nohup cloudflared tunnel --url http://localhost:7860 > /workspace/tunnel.log 2>&1 &
sleep 90
bash /workspace/ziggy-status.sh
STARTEOF
chmod +x /workspace/ziggy-start.sh

cat > /workspace/ziggy-stop.sh << 'STOPEOF'
#!/bin/bash
pkill -f "cloudflared tunnel" 2>/dev/null
pkill -f "interpreter --server" 2>/dev/null
pkill -f "open-webui serve" 2>/dev/null
pkill -f "ollama serve" 2>/dev/null
echo "Tous services arretes"
STOPEOF
chmod +x /workspace/ziggy-stop.sh

echo ""
echo "============================================"
echo " INSTALLATION TERMINEE"
echo "============================================"
echo "  URL PUBLIQUE  : ${PUBLIC_URL}"
echo "  Modele        : ${MODEL}"
echo "============================================"
echo " Dans Open WebUI (Safari) : "
echo "  Avatar -> Settings -> Admin Settings"
echo "  -> Connections -> OpenAI API -> + "
echo "  URL : http://localhost:8000/v1"
echo "  Key : sk-anything"
echo "============================================"
bash /workspace/ziggy-status.sh
