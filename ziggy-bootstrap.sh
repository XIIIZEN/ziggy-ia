#!/bin/bash
set -e
echo "============================================"
echo " ZIGGY AI - BOOTSTRAP v3.1 (venv isolés)"
echo "============================================"

# ---- 0. Dépendances système ----
echo "📦 Dépendances système..."
apt-get update -qq
apt-get install -y -qq lshw zstd curl wget pciutils python3-venv

# Cache pip et tmp sur Network Volume (évite disk full container)
export PIP_CACHE_DIR=/workspace/pip-cache
export TMPDIR=/workspace/tmp
mkdir -p /workspace/pip-cache /workspace/tmp

# ---- 1. Ollama ----
echo "📦 Installation Ollama..."
if ! command -v ollama &> /dev/null; then
    curl -fsSL https://ollama.ai/install.sh | sh
fi
mkdir -p /workspace/ollama-models /workspace/openwebui-data
export OLLAMA_MODELS=/workspace/ollama-models
pkill -f "ollama serve" 2>/dev/null || true
sleep 2
nohup ollama serve > /tmp/ollama.log 2>&1 &
echo "⏳ Démarrage Ollama..." && sleep 8

# ---- 2. Modèles selon VRAM ----
echo "🧠 Détection VRAM..."
VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
echo "   VRAM détectée : ${VRAM} MB"

INTERPRETER_MODEL="qwen2.5:7b"

if [ "$VRAM" -ge 70000 ]; then
  echo "→ GPU XXL : pull qwen2.5:72b + llama3.3:70b"
  ollama pull qwen2.5:72b
  ollama pull llama3.3:70b
  INTERPRETER_MODEL="qwen2.5:72b"
elif [ "$VRAM" -ge 40000 ]; then
  echo "→ GPU XL : pull qwen2.5:32b + qwen2.5-coder:32b"
  ollama pull qwen2.5:32b
  ollama pull qwen2.5-coder:32b
  INTERPRETER_MODEL="qwen2.5:32b"
elif [ "$VRAM" -ge 20000 ]; then
  echo "→ GPU L : pull qwen2.5:14b + mistral"
  ollama pull qwen2.5:14b
  ollama pull mistral
  INTERPRETER_MODEL="qwen2.5:14b"
else
  echo "→ GPU M : pull qwen2.5:7b"
  ollama pull qwen2.5:7b
fi

# ---- 3. Open WebUI dans son venv isolé ----
echo "📦 Installation Open WebUI (venv isolé)..."
if [ ! -d "/workspace/venv-openwebui" ]; then
  python3 -m venv /workspace/venv-openwebui
  /workspace/venv-openwebui/bin/pip install --upgrade pip --quiet
  /workspace/venv-openwebui/bin/pip install --quiet open-webui
else
  echo "  → venv-openwebui déjà existant, skip install"
fi

# Lancer Open WebUI
pkill -f "open-webui" 2>/dev/null || true
sleep 2
DATA_DIR=/workspace/openwebui-data \
OLLAMA_BASE_URL=http://localhost:11434 \
ENABLE_RAG_WEB_SEARCH=True \
RAG_WEB_SEARCH_ENGINE=duckduckgo \
nohup /workspace/venv-openwebui/bin/open-webui serve --host 0.0.0.0 --port 8080 \
  > /workspace/openwebui.log 2>&1 &
echo "✅ Open WebUI → port 8080 (démarrage en cours, 60-90 sec)"

# ---- 4. Open Interpreter dans son venv isolé ----
echo "📦 Installation Open Interpreter (venv isolé)..."
if [ ! -d "/workspace/venv-interpreter" ]; then
  python3 -m venv /workspace/venv-interpreter
  /workspace/venv-interpreter/bin/pip install --upgrade pip --quiet
  # FIX: setuptools manque dans Python 3.12 venv mais open-interpreter en a besoin (pkg_resources)
  /workspace/venv-interpreter/bin/pip install --quiet setuptools
  /workspace/venv-interpreter/bin/pip install --quiet open-interpreter
else
  echo "  → venv-interpreter déjà existant, skip install"
fi

# Config Open Interpreter
mkdir -p /root/.config/open-interpreter
cat > /root/.config/open-interpreter/config.yaml << EOF
model: ollama/${INTERPRETER_MODEL}
api_base: http://localhost:11434
context_window: 8000
max_tokens: 4096
offline: true
safe_mode: off
EOF

# Lancer Open Interpreter API
pkill -f "interpreter --server" 2>/dev/null || true
sleep 2
nohup /workspace/venv-interpreter/bin/interpreter \
  --server --host 0.0.0.0 --port 8889 \
  > /workspace/interpreter.log 2>&1 &
echo "✅ Open Interpreter → port 8889 (modèle: ${INTERPRETER_MODEL})"

# ---- 5. Génère ziggy-start.sh pour relance rapide ----
cat > /workspace/ziggy-start.sh << 'STARTEOF'
#!/bin/bash
echo "🔄 Démarrage Ziggy AI..."
export OLLAMA_MODELS=/workspace/ollama-models
export PIP_CACHE_DIR=/workspace/pip-cache
export TMPDIR=/workspace/tmp

# Stop tout
pkill -f ollama 2>/dev/null
pkill -f open-webui 2>/dev/null
pkill -f "interpreter --server" 2>/dev/null
sleep 3

# Ollama
nohup ollama serve > /tmp/ollama.log 2>&1 &
sleep 8

# Open WebUI
DATA_DIR=/workspace/openwebui-data \
OLLAMA_BASE_URL=http://localhost:11434 \
ENABLE_RAG_WEB_SEARCH=True \
RAG_WEB_SEARCH_ENGINE=duckduckgo \
nohup /workspace/venv-openwebui/bin/open-webui serve --host 0.0.0.0 --port 8080 \
  > /workspace/openwebui.log 2>&1 &

# Open Interpreter
nohup /workspace/venv-interpreter/bin/interpreter --server --host 0.0.0.0 --port 8889 \
  > /workspace/interpreter.log 2>&1 &

echo "⏳ Démarrage en cours (60 sec)..."
sleep 60

echo ""
echo "============================================"
echo " ✅ ZIGGY AI PRÊT"
echo "  🌐 Open WebUI    → port 8080"
echo "  🧠 Interpreter   → port 8889"
echo "  📓 JupyterLab    → port 8888"
echo "============================================"
echo ""
echo "=== Statut services ==="
curl -s -o /dev/null -w "Open WebUI : HTTP %{http_code}\n" http://localhost:8080
curl -s -o /dev/null -w "Interpreter: HTTP %{http_code}\n" http://localhost:8889
curl -s -o /dev/null -w "Ollama API : HTTP %{http_code}\n" http://localhost:11434/api/tags
STARTEOF
chmod +x /workspace/ziggy-start.sh
echo "✅ ziggy-start.sh créé pour relance rapide"

# ---- 6. Récap final ----
echo ""
echo "⏳ Attente démarrage complet des services (60 sec)..."
sleep 60

echo ""
echo "============================================"
echo " ✅ BOOTSTRAP TERMINÉ !"
echo "============================================"
echo "  🌐 Open WebUI    → port 8080"
echo "  🧠 Interpreter   → port 8889"
echo "  📓 JupyterLab    → port 8888"
echo ""
echo "  ⚠️  Vérifie que les ports 8080 et 8889 sont exposés dans RunPod"
echo "  🔄 Prochain pod  → bash /workspace/ziggy-start.sh"
echo ""
echo "=== Statut services ==="
curl -s -o /dev/null -w "Open WebUI : HTTP %{http_code}\n" http://localhost:8080
curl -s -o /dev/null -w "Interpreter: HTTP %{http_code}\n" http://localhost:8889
curl -s -o /dev/null -w "Ollama API : HTTP %{http_code}\n" http://localhost:11434/api/tags
echo ""
echo "  ✅ HTTP 200 = OK, va sur RunPod → Connect → Port 8080"
echo "============================================"
