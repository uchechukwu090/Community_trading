#!/bin/bash

# Load Render environment variables
export ACCOUNT_MODE=${ACCOUNT_MODE:-"demo"}
export ALLOWED_ORIGINS=${ALLOWED_ORIGINS}
export API_KEY=${API_SECRET_KEY:-"Mr.creative090"}  # Use API_SECRET_KEY
export API_URL=${TRADING_BACKEND_URL:-"https://ansorade-backend.onrender.com"}
export SIGNAL_GENERATOR_URL=${SIGNAL_GENERATOR_URL:-"https://anso-vision-backend.onrender.com"}
export VNC_PASSWORD=${VNC_PASSWORD:-""}
export PORT=${PORT:-5900}

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
    echo "   ACCOUNT_MODE: ${ACCOUNT_MODE}"
    echo "   FBS_ACCOUNT: ${FBS_ACCOUNT:+[SET]}"
    echo "   FBS_PASSWORD: ${FBS_PASSWORD:+[SET]}"
    echo ""
    echo "Set in Render Dashboard:"
    echo "  For demo: DEMO_ACCOUNT, DEMO_PASSWORD"
    echo "  For real: REAL_ACCOUNT, REAL_PASSWORD"
    exit 1
fi

echo "=== MT5 Trader Configuration ==="
echo "Account Mode: ${ACCOUNT_MODE}"
echo "Account: ${FBS_ACCOUNT}"
echo "Server: ${FBS_SERVER}"
echo "API URL: ${API_URL}"
echo "Signal Generator: ${SIGNAL_GENERATOR_URL}"
echo "VNC Port: ${PORT}"
echo "VNC Password: ${VNC_PASSWORD:+(SET - ${#VNC_PASSWORD} chars)}"
echo "================================"

# Create directories
mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/Logs"
mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/Config"
mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"

# Generate terminal.ini from environment variables
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

[Email]
Enable=0

[FTP]
Enable=0

[Notifications]
Enable=0

[Automation]
Enable=1
EOF

# Copy EA files if they exist
if [ -f "/app/CommunityTrader.mq5" ]; then
    cp "/app/CommunityTrader.mq5" "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
    echo "✅ Copied CommunityTrader EA"
fi

# Start Xvfb
echo "Starting Xvfb..."
Xvfb :99 -screen 0 1024x768x16 -ac -nolisten tcp &
XVFB_PID=$!
sleep 3

# Start VNC server
echo "Starting VNC server on port ${PORT}..."
VNC_ARGS="-display :99 -forever -shared -bg -rfbport ${PORT} -noxdamage"
if [ -n "${VNC_PASSWORD}" ]; then
    echo "Using VNC password (${#VNC_PASSWORD} chars)"
    VNC_ARGS="${VNC_ARGS} -passwd ${VNC_PASSWORD}"
else
    echo "No VNC password set"
fi

x11vnc ${VNC_ARGS} &
VNC_PID=$!
sleep 2

# Configure WebRequest permissions
echo "Configuring WebRequest permissions..."
wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v AllowWebRequest /t REG_DWORD /d 1 /f
wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v WebRequestURL /t REG_SZ /d "${API_URL}" /f
wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v WebRequestURL /t REG_SZ /d "${SIGNAL_GENERATOR_URL}" /f

echo "=== WebRequest Registry Settings ==="
wine reg query "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v AllowWebRequest
wine reg query "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v WebRequestURL

# Start MT5
echo "Starting MT5 Terminal (${FBS_SERVER})..."
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" \
    /config:"/root/.wine/drive_c/Program Files/MetaTrader 5/config/terminal.ini" \
    /portable &

MT5_PID=$!
echo "MT5 PID: $MT5_PID"

# Wait for MT5 initialization
echo "Waiting for MT5 to initialize (30 seconds)..."
sleep 30

# Check if MT5 is running
if ps -p $MT5_PID > /dev/null; then
    echo "✅ MT5 is running (PID: $MT5_PID)"
    # Check for common log file
    LOG_FILE="/root/.wine/drive_c/Program Files/MetaTrader 5/Logs/$(date +%Y%m%d).log"
    if [ -f "${LOG_FILE}" ]; then
        echo "Log file: ${LOG_FILE}"
        echo "Last 3 log entries:"
        tail -3 "${LOG_FILE}" 2>/dev/null || echo "No log entries yet"
    fi
else
    echo "❌ MT5 failed to start"
    # Try to find any error
    find "/root/.wine/drive_c/Program Files/MetaTrader 5/Logs/" -name "*.log" -exec tail -5 {} \; 2>/dev/null || true
    exit 1
fi

# Start Health Monitoring API
echo "Starting health monitoring API..."
python3 - << EOF
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
        "vnc_port": int(os.getenv("PORT", 5900)),
        "vnc_has_password": bool(os.getenv("VNC_PASSWORD", ""))
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "mt5-trader"}

@app.get("/test-backend")
async def test_backend():
    """Test connection to trading backend"""
    import requests
    api_url = os.getenv("API_URL", "")
    api_key = os.getenv("API_KEY", "")
    
    if not api_url or not api_key:
        return {"error": "API_URL or API_KEY not set"}
    
    try:
        response = requests.get(
            f"{api_url}/api/health",
            headers={"X-API-Key": api_key},
            timeout=5
        )
        return {
            "backend_status": response.status_code,
            "backend_response": response.text[:100] if response.text else "No response"
        }
    except Exception as e:
        return {"error": str(e)}

@app.get("/test-signal-generator")
async def test_signal_generator():
    """Test connection to signal generator"""
    signal_url = os.getenv("SIGNAL_GENERATOR_URL", "")
    if not signal_url:
        return {"error": "SIGNAL_GENERATOR_URL not set"}
    
    try:
        response = requests.get(f"{signal_url}/health", timeout=5)
        return {
            "signal_generator_status": response.status_code,
            "signal_generator_response": response.text[:100] if response.text else "No response"
        }
    except Exception as e:
        return {"error": str(e)}

@app.get("/env-check")
async def env_check():
    """Check environment variables (safe view)"""
    return {
        "account_mode": os.getenv("ACCOUNT_MODE"),
        "account_set": bool(os.getenv("FBS_ACCOUNT")),
        "server": os.getenv("FBS_SERVER"),
        "api_url": os.getenv("API_URL"),
        "signal_generator_url": os.getenv("SIGNAL_GENERATOR_URL"),
        "environment": os.getenv("ENVIRONMENT"),
        "supabase_configured": bool(os.getenv("SUPABASE_URL")),
        "vnc_configured": bool(os.getenv("VNC_PASSWORD")),
        "allowed_origins": os.getenv("ALLOWED_ORIGINS", "").split(",") if os.getenv("ALLOWED_ORIGINS") else []
    }

if __name__ == "__main__":
    port = 8000
    print(f"Starting health monitor on port {port}")
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning", access_log=False)
EOF &
HEALTH_PID=$!
echo "Health monitor PID: $HEALTH_PID (port 8000)"

# Create a WebRequest test EA
cat > "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/TestWebRequest.mq5" << EOF
//+------------------------------------------------------------------+
//| Test WebRequest Permissions                                      |
//+------------------------------------------------------------------+
#property copyright "Test"
#property version   "1.00"
#property strict

void OnStart()
{
    string apiUrl = "${API_URL}/api/health";
    string signalUrl = "${SIGNAL_GENERATOR_URL}/health";
    char data[], result[];
    string headers = "X-API-Key: ${API_KEY}\\r\\nContent-Type: application/json\\r\\n";
    
    Print("=== WebRequest Test ===");
    Print("Testing connection to: ", apiUrl);
    
    // Test trading backend
    int res1 = WebRequest("GET", apiUrl, headers, 5000, data, result, headers);
    if(res1 == -1)
    {
        Print("❌ Trading Backend FAILED. Error: ", GetLastError());
    }
    else
    {
        Print("✅ Trading Backend HTTP ", res1);
    }
    
    // Test signal generator
    Print("Testing connection to: ", signalUrl);
    int res2 = WebRequest("GET", signalUrl, "", 5000, data, result, "");
    if(res2 == -1)
    {
        Print("❌ Signal Generator FAILED. Error: ", GetLastError());
    }
    else
    {
        Print("✅ Signal Generator HTTP ", res2);
    }
    
    Print("=== WebRequest Test Complete ===");
}
//+------------------------------------------------------------------+
EOF

echo ""
echo "=========================================="
echo "✅ MT5 Trader Started Successfully!"
echo "=========================================="
echo ""
echo "📊 Configuration:"
echo "   Mode: ${ACCOUNT_MODE}"
echo "   Account: ${FBS_ACCOUNT}"
echo "   Server: ${FBS_SERVER}"
echo "   Trading: ${TRADING_MODE}"
echo ""
echo "🌐 API Endpoints:"
echo "   Trading Backend: ${API_URL}"
echo "   Signal Generator: ${SIGNAL_GENERATOR_URL}"
echo "   Health Monitor: http://localhost:8000"
echo ""
echo "🔧 VNC Access:"
echo "   Port: ${PORT}"
if [ -n "${VNC_PASSWORD}" ]; then
    echo "   Password: [SET in Render Dashboard]"
    echo "   Connect: vnc://<your-render-url>:${PORT} (with password)"
else
    echo "   Password: None (open access)"
    echo "   Connect: vnc://<your-render-url>:${PORT}"
fi
echo ""
echo "📁 Logs: /root/.wine/drive_c/Program Files/MetaTrader 5/Logs/"
echo "=========================================="

# Monitoring loop
while true; do
    # Check MT5
    if ! ps -p $MT5_PID > /dev/null; then
        echo "❌ MT5 process died at $(date). Exiting..."
        exit 1
    fi
    
    # Check health monitor
    if ! ps -p $HEALTH_PID > /dev/null 2>&1; then
        echo "⚠️ Health monitor died. Restarting..."
        python3 - << 'EOF'
from fastapi import FastAPI
import uvicorn
app = FastAPI()
@app.get("/health")
def health(): return {"status": "healthy"}
uvicorn.run(app, host="0.0.0.0", port=8000, log_level="warning")
EOF &
        HEALTH_PID=$!
    fi
    
    # Status update every 5 minutes
    if (( SECONDS % 300 == 0 )); then
        echo "[$(date)] System running - Uptime: $SECONDS seconds"
        # Show recent EA activity
        LOG_FILE="/root/.wine/drive_c/Program Files/MetaTrader 5/Logs/$(date +%Y%m%d).log"
        if [ -f "${LOG_FILE}" ]; then
            echo "Recent activity:"
            grep -i "signal\|trade\|error\|webrequest" "${LOG_FILE}" | tail -2 2>/dev/null || true
        fi
    fi
    
    sleep 10
done