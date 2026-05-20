#!/bin/bash
echo "🔄 Démarrage Ziggy AI..."
export OLLAMA_MODELS=/workspace/ollama-models
pkill -f ollama 2>/dev/null; pkill -f open-webui 2>/dev/null; pkill -f interpreter 2>/dev/null
sleep 2

ollama serve > /tmp/ollama.log 2>&1 &
sleep 6

DATA_DIR=/workspace/openwebui-data \
OLLAMA_BASE_URL=http://localhost:11434 \
ENABLE_RAG_WEB_SEARCH=True \
RAG_WEB_SEARCH_ENGINE="duckduckgo" \
open-webui serve --host 0.0.0.0 --port 8080 \
  > /workspace/openwebui.log 2>&1 &

interpreter --server --port 8889 --host 0.0.0.0 \
  > /tmp/interpreter.log 2>&1 &

echo "============================================"
echo " ✅ ZIGGY AI PRÊT (WEB + OS + CREWAI)"
echo "  🌐 Open WebUI    → port 8080"
echo "  🧠 Interpreter   → port 8889"
echo "  📓 JupyterLab    → port 8888"
echo "============================================"
