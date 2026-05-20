#!/bin/bash
set -e
echo "============================================"
echo " ZIGGY AI - BOOTSTRAP COMPLET NOUVEAU POD"
echo "============================================"

# ---- 1. Ollama ----
echo "📦 Installation Ollama..."
curl -fsSL https://ollama.ai/install.sh | sh
mkdir -p /workspace/ollama-models /workspace/openwebui-data /workspace/agency
export OLLAMA_MODELS=/workspace/ollama-models
ollama serve > /tmp/ollama.log 2>&1 &
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
  echo "→ GPU XL : pull qwen2.5:32b + mistral"
  ollama pull qwen2.5:32b
  ollama pull mistral
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

# ---- 3. Open WebUI ----
echo "📦 Installation Open WebUI..."
pip install open-webui --quiet --break-system-packages
DATA_DIR=/workspace/openwebui-data \
OLLAMA_BASE_URL=http://localhost:11434 \
open-webui serve --host 0.0.0.0 --port 8080 \
  > /workspace/openwebui.log 2>&1 &
echo "✅ Open WebUI → port 8080"

# ---- 4. Open Interpreter ----
echo "📦 Installation Open Interpreter..."
pip install open-interpreter --quiet --break-system-packages

echo "⚙️  Configuration d'Open Interpreter avec le modèle : ${INTERPRETER_MODEL}"
mkdir -p /root/.config/open-interpreter
cat > /root/.config/open-interpreter/config.yaml << EOF
model: ollama/${INTERPRETER_MODEL}
api_base: http://localhost:11434
context_window: 8000
max_tokens: 4096
offline: true
safe_mode: off
EOF

interpreter --server --port 8889 --host 0.0.0.0 \
  > /tmp/interpreter.log 2>&1 &
echo "✅ Open Interpreter → port 8889"

# ---- 5. Script ziggy-start.sh pour prochains redémarrages ----
cat > /workspace/ziggy-start.sh << 'EOF'
#!/bin/bash
echo "🔄 Démarrage Ziggy AI..."
export OLLAMA_MODELS=/workspace/ollama-models
pkill -f ollama 2>/dev/null; pkill -f open-webui 2>/dev/null; pkill -f interpreter 2>/dev/null
sleep 2

ollama serve > /tmp/ollama.log 2>&1 &
sleep 6

DATA_DIR=/workspace/openwebui-data \
OLLAMA_BASE_URL=http://localhost:11434 \
open-webui serve --host 0.0.0.0 --port 8080 \
  > /workspace/openwebui.log 2>&1 &

interpreter --server --port 8889 --host 0.0.0.0 \
  > /tmp/interpreter.log 2>&1 &

echo "============================================"
echo " ✅ ZIGGY AI PRÊT"
echo "  🌐 Open WebUI    → port 8080"
echo "  🧠 Interpreter   → port 8889"
echo "  📓 JupyterLab    → port 8888"
echo "============================================"
EOF
chmod +x /workspace/ziggy-start.sh

echo ""
echo "============================================"
echo " ✅ BOOTSTRAP TERMINÉ !"
echo "  🌐 Open WebUI    → port 8080"
echo "  🧠 Interpreter   → port 8889"
echo "  📓 JupyterLab    → port 8888"
echo ""
echo "  ⚠️  Expose ports 8080 et 8889 dans RunPod"
echo "  🔄 Prochain pod  → bash /workspace/ziggy-start.sh"
echo "============================================"
