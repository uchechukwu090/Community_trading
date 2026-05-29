#!/bin/bash

# Load Render environment variables
export ACCOUNT_MODE=${ACCOUNT_MODE:-"demo"}
export ALLOWED_ORIGINS=${ALLOWED_ORIGINS}
export API_KEY=${API_SECRET_KEY:-"Mr.creative090"}
export API_URL=${TRADING_BACKEND_URL:-"https://ansorade-backend.onrender.com"}
export SIGNAL_GENERATOR_URL=${SIGNAL_GENERATOR_URL:-"https://anso-vision-backend.onrender.com"}
export VNC_PASSWORD=${VNC_PASSWORD:-""}

# CRITICAL FIX: Use Render's injected PORT for the API, and 5900 for VNC
export API_PORT=${PORT:-8000}
export VNC_PORT=5900

# Set FBS credentials based on ACCOUNT_MODE
if [ "${ACCOUNT_MODE}" = "demo" ]; then
    echo "⚠️  Using DEMO account mode"
    export FBS_ACCOUNT=${DEMO_ACCOUNT:-""}
    export FBS_PASSWORD=${DEMO_PASSWORD:-""}
    export FBS_SERVER=${DEMO_SERVER:-"FBS-Demo"}
    export TRADING_MODE="demo"
else
    echo "💰 Using REAL account mode"
    export FBS_ACCOUNT=${REAL_ACCOUNT:-""}
    export FBS_PASSWORD=${REAL_PASSWORD:-""}
    export FBS_SERVER=${REAL_SERVER:-"FBS-Real"}
    export TRADING_MODE="real"
fi

# Validate credentials
if [ -z "${FBS_ACCOUNT}" ] || [ -z "${FBS_PASSWORD}" ]; then
    echo "❌ ERROR: Missing FBS credentials!"
    exit 1
fi

echo "=== MT5 Trader Configuration ==="
echo "API Port: ${API_PORT} (Render scans this)"
echo "VNC Port: ${VNC_PORT}"
echo "================================"

# ---------------------------------------------------------
# 1. START API IMMEDIATELY (Satisfies Render's Port Scanner)
# ---------------------------------------------------------
echo "Starting health monitoring API on port ${API_PORT}..."

cat > /tmp/api.py << 'EOF'
from fastapi import FastAPI
import uvicorn
import os
import requests
from datetime import datetime

app = FastAPI(title="MT5 Trader Monitor")

@app.get("/")
async def root():
    return {
        "service": "mt5-community-trader",
        "status": "running",
        "timestamp": datetime.utcnow().isoformat(),
        "account_mode": os.getenv("ACCOUNT_MODE", "demo"),
        "server": os.getenv("FBS_SERVER", ""),
        "api_url": os.getenv("API_URL", ""),
        "vnc_port": int(os.getenv("VNC_PORT", 5900)),
        "vnc_has_password": bool(os.getenv("VNC_PASSWORD", ""))
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "mt5-trader"}

@app.get("/mt5-logs")
def mt5_logs():
    import glob
    # Find the latest log file
    log_files = glob.glob("/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/Community_Trader_*.log")
    if not log_files:
        return {"error": "No log files found yet"}
    
    latest_log = max(log_files, key=os.path.getctime)
    
    with open(latest_log, "r") as f:
        # Return the last 50 lines
        lines = f.readlines()
        return {"file": os.path.basename(latest_log), "logs": lines[-50:]}

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    print(f"✅ API successfully listening on port {port}")
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")
EOF

python3 /tmp/api.py > /tmp/api.log 2>&1 &
HEALTH_PID=$!
echo "✅ Health monitor PID: $HEALTH_PID"

# ---------------------------------------------------------
# 2. SETUP MT5 DIRECTORIES & CONFIG
# ---------------------------------------------------------
mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/Logs"
mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/Config"
mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"

cat > "/root/.wine/drive_c/Program Files/MetaTrader 5/config/terminal.ini" << EOF
[Common]
Login=${FBS_ACCOUNT}
Password=${FBS_PASSWORD}
Server=${FBS_SERVER}
CertPassword=
ProxyType=0
KeepPrivate=0
NewsEnable=1
EnableAutoUpdate=1
Language=en
Country=US
TradingMode=${TRADING_MODE}

[Experts]
Enabled=1
AllowLiveTrading=1
AllowDllImports=1
AllowWebRequest=1
ConfirmDlls=0
ConfirmImport=0
ConfirmWebRequest=0
WebRequestURL=${API_URL}
WebRequestURL=${SIGNAL_GENERATOR_URL}
WebRequestURL=https://*.render.com
WebRequestURL=https://*.supabase.co
WebRequestURL=https://*.vercel.app

[Charts]
ProfileLast=Default
MaxBars=500000

[Automation]
Enable=1
EOF

if [ -f "/app/CommunityTrader.mq5" ]; then
    cp "/app/CommunityTrader.mq5" "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
fi

# ---------------------------------------------------------
# 3. START XVFB & VNC (FIXED)
# ---------------------------------------------------------
echo "Starting Xvfb..."
# CRITICAL FIX: Clear stale X11 lock files from previous crashed runs
rm -f /tmp/.X99-lock
rm -f /tmp/.X11-unix/X99

Xvfb :99 -screen 0 1024x768x16 -ac -nolisten tcp &
XVFB_PID=$!
sleep 5 # Give Xvfb enough time to fully initialize

# CRITICAL: Explicitly export DISPLAY for all subsequent commands
export DISPLAY=:99

echo "Starting VNC server on port ${VNC_PORT}..."
VNC_ARGS="-display :99 -forever -shared -bg -rfbport ${VNC_PORT} -noxdamage"
if [ -n "${VNC_PASSWORD}" ]; then
    VNC_ARGS="${VNC_ARGS} -passwd ${VNC_PASSWORD}"
fi
x11vnc ${VNC_ARGS} &
VNC_PID=$!
sleep 2

# ---------------------------------------------------------
# 4. START MT5 (FIXED PATH & CONFIG)
# ---------------------------------------------------------
echo "Configuring WebRequest permissions..."
wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v AllowWebRequest /t REG_DWORD /d 1 /f
wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v WebRequestURL /t REG_SZ /d "${API_URL}" /f

# DYNAMIC FIX: Find the MT5 executable wherever the installer put it
echo "Searching for MT5 executable..."
MT5_EXE=$(find /root/.wine/drive_c -name "terminal*.exe" -type f | head -n 1)

if [ -z "$MT5_EXE" ]; then
    echo "❌ ERROR: Could not find MT5 executable!"
    echo "Installation might have failed. Listing Program Files:"
    ls -R "/root/.wine/drive_c/Program Files/" 2>/dev/null || echo "Program Files not found."
    exit 1
fi

echo "✅ Found MT5 executable at: $MT5_EXE"

# Use Windows-style path for the config file to prevent Wine path errors
WIN_CONFIG_PATH="C:\\Program Files\\MetaTrader 5\\config\\terminal.ini"

echo "Starting MT5 Terminal (${FBS_SERVER})..."
wine "$MT5_EXE" /config:"$WIN_CONFIG_PATH" /portable &
MT5_PID=$!

echo "Waiting for MT5 to initialize (30 seconds)..."
sleep 30

if ps -p $MT5_PID > /dev/null; then
    echo "✅ MT5 is running (PID: $MT5_PID)"
else
    echo "❌ MT5 failed to start"
    exit 1
fi

# ---------------------------------------------------------
# 5. MONITORING LOOP
# ---------------------------------------------------------
echo "✅ All systems started successfully!"

while true; do
    if ! ps -p $MT5_PID > /dev/null; then
        echo "❌ MT5 process died at $(date). Exiting..."
        exit 1
    fi
    
    if ! ps -p $HEALTH_PID > /dev/null 2>&1; then
        echo "⚠️ Health monitor died. Restarting..."
        python3 /tmp/api.py > /tmp/api.log 2>&1 &
        HEALTH_PID=$!
    fi
    
    sleep 15
done

# ---------------------------------------------------------
# 6. AUTO-ENABLE ALGO TRADING (CRITICAL FOR EXECUTION)
# ---------------------------------------------------------
echo "Auto-enabling Algo Trading..."
export DISPLAY=:99

# Find the MT5 window and bring it to focus
xdotool search --onlyvisible --name "MetaTrader" windowactivate --sync
sleep 2

# Click the "Algo Trading" button on the top toolbar
# (Coordinates x=280, y=45 are approximate for the standard 1024x768 layout)
xdotool mousemove 280 45 click 1
sleep 1
xdotool mousemove 280 45 click 1 # Click twice to ensure it toggles ON (Green)
echo "✅ Algo Trading button clicked."
