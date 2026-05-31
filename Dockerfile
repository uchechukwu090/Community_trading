FROM ubuntu:22.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:99
ENV WINEARCH=win64
ENV WINEPREFIX=/root/.wine

# Install Wine and dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends dpkg && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    wine64 \
    wine32 \
    xvfb \
    x11vnc \
    supervisor \
    curl \
    python3 \
    python3-pip \
    xdotool \
    winetricks \
    cabextract && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Only set Wine prefix Windows version as win7, skip corefonts to avoid build fail
RUN winetricks -q win7 || echo "win7 prefix skipped"

# Create MT5 directory
RUN mkdir -p /root/.wine/drive_c/Program\ Files/MetaTrader\ 5

# Initialize Wine prefix properly before installing anything
RUN xvfb-run -a wineboot --init

# Start Xvfb, run Linux shell installer with env, ensure success
WORKDIR /tmp
RUN Xvfb :99 -screen 0 1024x768x16 -ac +extension GLX +render -noreset & \
    sleep 3 && \
    export DISPLAY=:99 && \
    export WINEPREFIX=/root/.wine && \
    wget https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5linux.sh \
    && chmod +x mt5linux.sh \
    && DISPLAY=:99 WINEPREFIX=/root/.wine ./mt5linux.sh \
    && sleep 10 \
    && rm mt5linux.sh

# Debug check for MT5 executable (Fails build if not found)
RUN ls -l "/root/.wine/drive_c/Program Files/MetaTrader 5/" || ls -l "/root/.wine/drive_c/Program Files (x86)/MetaTrader 5/"
RUN test -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" || \
    test -f "/root/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe" || \
    (echo "❌ MT5 installation failed!" && exit 1)

# Wait/set registry permissions for MT5 to make web requests
RUN sleep 15 && \
    wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v AllowWebRequest /t REG_DWORD /d 1 /f && \
    wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v WebRequestURL /t REG_SZ /d "https://ansorade-backend.onrender.com" /f && \
    wine reg add "HKEY_CURRENT_USER\Software\MetaQuotes\Terminal\Common" /v WebRequestURL /t REG_SZ /d "https://*.render.com" /f

# Copy MT5 configuration (Using bracket syntax for spaces)
COPY ["config/terminal.ini", "/root/.wine/drive_c/Program Files/MetaTrader 5/config/"]

# Copy Expert Advisor (Using bracket syntax for spaces)
COPY ["experts/", "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"]

# Create log directory
RUN mkdir -p /root/.wine/drive_c/Program\ Files/MetaTrader\ 5/Logs

# Install Python dependencies for monitoring
RUN pip3 install fastapi uvicorn requests

# Copy startup script
COPY scripts/start.sh /start.sh
RUN chmod +x /start.sh

# Copy supervisor config
COPY supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Expose VNC and API ports
EXPOSE 5900 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["/start.sh"]
