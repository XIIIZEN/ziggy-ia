#!/bin/bash
# ============================================
# ZIGGY AI - v5.3 (LEAN)
# 2 modeles : Qwen2.5-Coder (Interpreter) + Qwen3-VL (vision)
# Install rapide ~20 min
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
echo " ZIGGY AI v5.3 LEAN - Bootstrap"
echo "============================================"

apt-get update -qq
apt-get install -y -qq curl wget git python3-venv pciutils lsof

if [ ! -f /usr/local/bin/cloudflared ]; then
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

command -v ollama &>/dev/null || curl -fsSL https://ollama.com/install.sh | sh
mkdir -p /workspace/ollama-models /workspace/openwebui-data
export OLLAMA_MODELS=/workspace/ollama-models
export OLLAMA_HOST=0.0.0.0
pkill -f "ollama serve" 2>/dev/null || true
sleep 2
nohup ollama serve > /workspace/ollama.log 2>&1 &
wait_for_http "http://localhost:11434/api/tags" "Ollama" 30

VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
echo "VRAM detectee : ${VRAM} MB"

# Selection des 2 modeles selon VRAM
if [ "$VRAM" -ge 48000 ]; then
  CODER_MODEL="qwen2.5-coder:32b"
  VISION_MODEL="qwen3-vl:32b"
  echo "Profil HAUT : qwen2.5-coder:32b + qwen3-vl:32b"
elif [ "$VRAM" -ge 24000 ]; then
  CODER_MODEL="qwen2.5-coder:14b"
  VISION_MODEL="qwen3-vl:7b"
  echo "Profil MOYEN : qwen2.5-coder:14b + qwen3-vl:7b"
else
  CODER_MODEL="qwen2.5-coder:7b"
  VISION_MODEL="qwen3-vl:7b"
  echo "Profil BAS : qwen2.5-coder:7b + qwen3-vl:7b"
fi

echo ""
echo ">>> Pull ${CODER_MODEL} (Open Interpreter)..."
ollama pull "${CODER_MODEL}" || echo "Echec pull ${CODER_MODEL}"

echo ""
echo ">>> Pull ${VISION_MODEL} (vision)..."
ollama pull "${VISION_MODEL}" || echo "Echec pull ${VISION_MODEL}"

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

# Open Interpreter
if [ ! -d /workspace/venv-interpreter ]; then
  python3 -m venv /workspace/venv-interpreter
  /workspace/venv-interpreter/bin/pip install --upgrade pip setuptools --quiet
  /workspace/venv-interpreter/bin/pip install --quiet open-interpreter
fi
/workspace/venv-interpreter/bin/pip install --upgrade --quiet setuptools

mkdir -p /root/.config/open-interpreter
cat > /root/.config/open-interpreter/config.yaml << EOF2
model: ollama/${CODER_MODEL}
api_base: http://localhost:11434
context_window: 16000
max_tokens: 8192
offline: true
safe_mode: off
auto_run: true
EOF2

pkill -f "interpreter --server" 2>/dev/null || true
sleep 2
nohup /workspace/venv-interpreter/bin/interpreter --server --host 0.0.0.0 --port 8000 \
  > /workspace/interpreter.log 2>&1 &
wait_for_http "http://localhost:8000/v1/models" "Interpreter" 60 || echo "Interpreter KO - check /workspace/interpreter.log"

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
[ -z "$URL" ] && echo "Pas d'URL" || echo "URL: ${URL}"
URLEOF
chmod +x /workspace/ziggy-url.sh

cat > /workspace/ziggy-status.sh << 'STATEOF'
#!/bin/bash
echo "============================================"
echo " STATUT ZIGGY"
echo "============================================"
ps aux | grep -E "ollama serve|open-webui|interpreter --server|cloudflared tunnel" | grep -v grep | awk '{print "  OK ", $11, $12, $13}'
echo ""
echo " Modeles disponibles :"
curl -s http://localhost:11434/api/tags 2>/dev/null | python3 -c "import json,sys; [print('  -', m['name']) for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null || echo "  (Ollama non joignable)"
echo ""
curl -s -o /dev/null -w "  WebUI       : HTTP %{http_code}\n" http://localhost:7860 || echo "  WebUI : OFF"
curl -s -o /dev/null -w "  Interpreter : HTTP %{http_code}\n" http://localhost:8000/v1/models || echo "  Interpreter : OFF"
curl -s -o /dev/null -w "  Ollama      : HTTP %{http_code}\n" http://localhost:11434/api/tags || echo "  Ollama : OFF"
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /workspace/tunnel.log 2>/dev/null | head -1)
[ -n "$URL" ] && echo "  URL publique: $URL"
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
echo "  VRAM          : ${VRAM} MB"
echo "  Coder/Interpr : ${CODER_MODEL}"
echo "  Vision        : ${VISION_MODEL}"
echo "============================================"
echo " ETAPES SUIVANTES (Safari) :"
echo "============================================"
echo " 1. Ouvre URL publique ci-dessus"
echo " 2. Cree compte admin"
echo " 3. Brancher Open Interpreter :"
echo "    Avatar -> Settings -> Admin Settings"
echo "    -> Connections -> OpenAI API -> +"
echo "    URL : http://localhost:8000/v1"
echo "    Key : sk-anything"
echo "    -> Save"
echo "============================================"
bash /workspace/ziggy-status.sh
