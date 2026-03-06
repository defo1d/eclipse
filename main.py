"""
Eclips VPN — FastAPI Backend
Xray-core config manager, DPI monitor, key rotation, VLESS link generator
"""

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import random
import re
import secrets
import string
import subprocess
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Optional

import httpx
import psutil
import qrcode
import qrcode.image.svg
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from io import BytesIO
from pydantic import BaseModel

# ──────────────────────────────────────────────────────────────────────────────
# Config / Env
# ──────────────────────────────────────────────────────────────────────────────

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("eclips")

ECLIPS_PASSWORD  = os.getenv("ECLIPS_PASSWORD", "changeme_strong_password")
XRAY_CONFIG_PATH = Path(os.getenv("XRAY_CONFIG_PATH", "/etc/xray/config.json"))
XRAY_LOG_PATH    = Path(os.getenv("XRAY_LOG_PATH", "/var/log/xray"))
SERVER_IP        = os.getenv("SERVER_IP", "0.0.0.0")
PRIVATE_KEY      = os.getenv("PRIVATE_KEY", "")
PUBLIC_KEY       = os.getenv("PUBLIC_KEY", "")
DATA_PATH        = Path(os.getenv("DATA_PATH", "/app/data"))
DATA_PATH.mkdir(parents=True, exist_ok=True)

STATE_FILE = DATA_PATH / "state.json"

# ──────────────────────────────────────────────────────────────────────────────
# SNI pool — rotated every 24h
# ──────────────────────────────────────────────────────────────────────────────

SNI_POOL = [
    "icloud.com",
    "gateway.icloud.com",
    "cdn.apple-cloudkit.com",
    "www.apple.com",
    "appleid.apple.com",
    "api.sberbank.ru",
    "online.sberbank.ru",
    "gosuslugi.ru",
    "lk.gosuslugi.ru",
    "esia.gosuslugi.ru",
]

DEST_SITES = {
    "icloud.com":443,
    "gateway.icloud.com":443,
    "www.apple.com":443,
    "gosuslugi.ru":443,
}

BLOCKED_SITES_CHECK = [
    "https://www.youtube.com",
    "https://twitter.com",
    "https://facebook.com",
]
DIRECT_SITES_CHECK = [
    "https://www.google.com",
    "https://cloudflare.com",
    "https://1.1.1.1",
]

# ──────────────────────────────────────────────────────────────────────────────
# State helpers
# ──────────────────────────────────────────────────────────────────────────────

def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {}


def save_state(data: dict):
    STATE_FILE.write_text(json.dumps(data, indent=2))


def gen_short_id(length: int = 8) -> str:
    """Hex short-id required by Reality."""
    return secrets.token_hex(length // 2)


def gen_uuid() -> str:
    return str(uuid.uuid4())


# ──────────────────────────────────────────────────────────────────────────────
# Xray config generator
# ──────────────────────────────────────────────────────────────────────────────

def build_xray_config(state: dict) -> dict:
    """Generate full Xray config.json with VLESS+Reality (TCP) and VLESS+Reality (gRPC)."""

    sni       = state.get("sni", random.choice(SNI_POOL))
    short_id  = state.get("short_id", gen_short_id())
    user_id   = state.get("user_id", gen_uuid())
    priv_key  = PRIVATE_KEY or state.get("private_key", "")
    pub_key   = PUBLIC_KEY  or state.get("public_key", "")

    dest_host, dest_port = sni, DEST_SITES.get(sni, 443)

    config = {
        "log": {
            "loglevel": "warning",
            "access": str(XRAY_LOG_PATH / "access.log"),
            "error":  str(XRAY_LOG_PATH / "error.log"),
        },
        "inbounds": [
            # ── VLESS + Reality — TCP port 443 ──────────────────────────────
            {
                "listen": "0.0.0.0",
                "port": 443,
                "protocol": "vless",
                "settings": {
                    "clients": [
                        {"id": user_id, "flow": "xtls-rprx-vision"}
                    ],
                    "decryption": "none",
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "dest": f"{dest_host}:{dest_port}",
                        "xver": 0,
                        "serverNames": [sni, f"www.{sni}" if not sni.startswith("www.") else sni],
                        "privateKey": priv_key,
                        "shortIds": [short_id],
                    },
                    "tcpSettings": {
                        "header": {"type": "none"},
                    },
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"],
                },
            },
            # ── VLESS + Reality — gRPC port 8443 ────────────────────────────
            {
                "listen": "0.0.0.0",
                "port": 8443,
                "protocol": "vless",
                "settings": {
                    "clients": [
                        {"id": user_id, "flow": ""}
                    ],
                    "decryption": "none",
                },
                "streamSettings": {
                    "network": "grpc",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "dest": f"{dest_host}:{dest_port}",
                        "xver": 0,
                        "serverNames": [sni],
                        "privateKey": priv_key,
                        "shortIds": [short_id],
                    },
                    "grpcSettings": {
                        "serviceName": "eclips-grpc",
                        "multiMode": True,
                    },
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                },
            },
        ],
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
        ],
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {
                    "type": "field",
                    "ip": ["geoip:private"],
                    "outboundTag": "block",
                },
            ],
        },
        "policy": {
            "levels": {
                "0": {
                    "handshake": 4,
                    "connIdle": 300,
                    "uplinkOnly": 5,
                    "downlinkOnly": 30,
                    "bufferSize": 4,
                }
            },
            "system": {
                "statsInboundUplink": True,
                "statsInboundDownlink": True,
            },
        },
        "stats": {},
    }
    return config


# ──────────────────────────────────────────────────────────────────────────────
# Rotation logic
# ──────────────────────────────────────────────────────────────────────────────

def rotate_keys_and_sni(state: dict) -> dict:
    """Pick new SNI + ShortID. Keys stay unless explicitly requested."""
    state["sni"]        = random.choice(SNI_POOL)
    state["short_id"]   = gen_short_id()
    state["rotated_at"] = datetime.utcnow().isoformat()
    return state


def write_xray_config(cfg: dict):
    XRAY_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = XRAY_CONFIG_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2))
    tmp.rename(XRAY_CONFIG_PATH)
    log.info("Xray config written → %s", XRAY_CONFIG_PATH)


def reload_xray():
    """Send SIGUSR1 to xray process for hot reload (no downtime)."""
    try:
        result = subprocess.run(
            ["pkill", "-SIGUSR1", "xray"],
            capture_output=True, timeout=5
        )
        log.info("Xray reload signal sent (rc=%d)", result.returncode)
    except Exception as e:
        log.warning("Could not send reload signal: %s", e)


# ──────────────────────────────────────────────────────────────────────────────
# VLESS link builder
# ──────────────────────────────────────────────────────────────────────────────

def build_vless_link(state: dict, transport: str = "tcp") -> str:
    uid      = state.get("user_id", "")
    sni      = state.get("sni", "icloud.com")
    pub_key  = PUBLIC_KEY or state.get("public_key", "")
    short_id = state.get("short_id", "")
    server   = SERVER_IP
    fp       = "safari"  # uTLS fingerprint

    if transport == "tcp":
        port   = 443
        flow   = "xtls-rprx-vision"
        params = (
            f"type=tcp&security=reality"
            f"&pbk={pub_key}&fp={fp}&sni={sni}"
            f"&sid={short_id}&flow={flow}"
        )
    else:  # grpc
        port   = 8443
        params = (
            f"type=grpc&security=reality"
            f"&pbk={pub_key}&fp={fp}&sni={sni}"
            f"&sid={short_id}&serviceName=eclips-grpc&mode=multi"
        )

    tag  = f"eclips-{transport}"
    link = f"vless://{uid}@{server}:{port}?{params}#{tag}"
    return link


# ──────────────────────────────────────────────────────────────────────────────
# DPI Monitor
# ──────────────────────────────────────────────────────────────────────────────

dpi_score_cache: dict = {"score": 0, "updated_at": None, "details": {}}


async def measure_latency(url: str, timeout: float = 5.0) -> Optional[float]:
    try:
        start = time.monotonic()
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            resp = await client.get(url)
        return round((time.monotonic() - start) * 1000, 1)  # ms
    except Exception:
        return None


async def run_dpi_monitor():
    """
    Measures latency ratio between 'blocked' and 'direct' sites.
    Score 0-100: 0 = clean, 100 = heavy interference.
    """
    blocked_latencies, direct_latencies = [], []

    for url in BLOCKED_SITES_CHECK:
        lat = await measure_latency(url)
        if lat:
            blocked_latencies.append(lat)

    for url in DIRECT_SITES_CHECK:
        lat = await measure_latency(url)
        if lat:
            direct_latencies.append(lat)

    avg_blocked = sum(blocked_latencies) / len(blocked_latencies) if blocked_latencies else 9999
    avg_direct  = sum(direct_latencies)  / len(direct_latencies)  if direct_latencies  else 1

    # Timeout / no response counts as heavy blocking
    blocked_timeouts = len(BLOCKED_SITES_CHECK) - len(blocked_latencies)

    ratio = avg_blocked / max(avg_direct, 1)
    score = min(100, int((ratio - 1) * 20) + blocked_timeouts * 20)
    score = max(0, score)

    dpi_score_cache.update({
        "score":      score,
        "updated_at": datetime.utcnow().isoformat(),
        "details": {
            "avg_blocked_ms": avg_blocked,
            "avg_direct_ms":  avg_direct,
            "blocked_timeouts": blocked_timeouts,
            "blocked_samples": blocked_latencies,
            "direct_samples":  direct_latencies,
        }
    })
    log.info("DPI score: %d  (blocked_avg=%.0fms  direct_avg=%.0fms)", score, avg_blocked, avg_direct)


# ──────────────────────────────────────────────────────────────────────────────
# Scheduler
# ──────────────────────────────────────────────────────────────────────────────

scheduler = AsyncIOScheduler()


async def scheduled_rotation():
    log.info("⏰ Scheduled rotation triggered")
    state = load_state()
    state = rotate_keys_and_sni(state)
    cfg   = build_xray_config(state)
    write_xray_config(cfg)
    reload_xray()
    save_state(state)
    log.info("✅ Rotation complete. New SNI: %s  ShortID: %s", state["sni"], state["short_id"])


# ──────────────────────────────────────────────────────────────────────────────
# App lifespan
# ──────────────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialise state on first boot
    state = load_state()
    if not state.get("user_id"):
        state["user_id"]    = gen_uuid()
        state["sni"]        = random.choice(SNI_POOL)
        state["short_id"]   = gen_short_id()
        state["private_key"] = PRIVATE_KEY
        state["public_key"]  = PUBLIC_KEY
        state["rotated_at"]  = datetime.utcnow().isoformat()
        save_state(state)

    # Write initial xray config
    cfg = build_xray_config(state)
    write_xray_config(cfg)
    reload_xray()

    # Schedule rotation every 24 hours
    scheduler.add_job(scheduled_rotation, "interval", hours=24, id="rotation")
    # DPI check every 10 minutes
    scheduler.add_job(run_dpi_monitor, "interval", minutes=10, id="dpi_monitor")
    scheduler.start()

    # Initial DPI probe
    asyncio.create_task(run_dpi_monitor())

    yield

    scheduler.shutdown()


# ──────────────────────────────────────────────────────────────────────────────
# FastAPI app
# ──────────────────────────────────────────────────────────────────────────────

app = FastAPI(title="Eclips VPN API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBasic()


def verify_password(credentials: HTTPBasicCredentials = Depends(security)):
    correct = hmac.compare_digest(
        credentials.password.encode(), ECLIPS_PASSWORD.encode()
    )
    if not (credentials.username == "eclips" and correct):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username


# ──────────────────────────────────────────────────────────────────────────────
# Routes
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "ts": datetime.utcnow().isoformat()}


@app.get("/api/status", dependencies=[Depends(verify_password)])
async def get_status():
    state = load_state()
    uptime = None
    try:
        boot = psutil.boot_time()
        uptime = int(time.time() - boot)
    except Exception:
        pass

    return {
        "sni":        state.get("sni"),
        "short_id":   state.get("short_id"),
        "rotated_at": state.get("rotated_at"),
        "server_ip":  SERVER_IP,
        "uptime_sec": uptime,
        "dpi":        dpi_score_cache,
        "ports": {"tcp": 443, "grpc": 8443},
    }


@app.get("/api/links", dependencies=[Depends(verify_password)])
async def get_links():
    state = load_state()
    return {
        "tcp":  build_vless_link(state, "tcp"),
        "grpc": build_vless_link(state, "grpc"),
    }


@app.get("/api/qr/{transport}", dependencies=[Depends(verify_password)])
async def get_qr(transport: str = "tcp"):
    if transport not in ("tcp", "grpc"):
        raise HTTPException(400, "transport must be tcp or grpc")
    state = load_state()
    link  = build_vless_link(state, transport)

    img   = qrcode.make(link)
    buf   = BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return StreamingResponse(buf, media_type="image/png")


@app.post("/api/rotate", dependencies=[Depends(verify_password)])
async def emergency_rotate():
    """Emergency Orbit — rotate all keys and SNI immediately."""
    state = load_state()
    state = rotate_keys_and_sni(state)
    cfg   = build_xray_config(state)
    write_xray_config(cfg)
    reload_xray()
    save_state(state)
    log.info("🚨 Emergency rotation triggered by API")
    return {
        "success":  True,
        "new_sni":      state["sni"],
        "new_short_id": state["short_id"],
        "rotated_at":   state["rotated_at"],
        "tcp_link":  build_vless_link(state, "tcp"),
        "grpc_link": build_vless_link(state, "grpc"),
    }


@app.get("/api/dpi", dependencies=[Depends(verify_password)])
async def get_dpi():
    return dpi_score_cache


@app.post("/api/dpi/refresh", dependencies=[Depends(verify_password)])
async def refresh_dpi():
    asyncio.create_task(run_dpi_monitor())
    return {"message": "DPI probe started"}


@app.get("/api/logs", dependencies=[Depends(verify_password)])
async def get_logs(lines: int = 100):
    log_file = XRAY_LOG_PATH / "access.log"
    err_file = XRAY_LOG_PATH / "error.log"
    result   = {}
    for name, f in [("access", log_file), ("error", err_file)]:
        if f.exists():
            content = f.read_text(errors="replace").splitlines()
            result[name] = content[-lines:]
        else:
            result[name] = []
    return result


@app.get("/api/config", dependencies=[Depends(verify_password)])
async def get_config():
    state = load_state()
    cfg   = build_xray_config(state)
    # Redact private key
    if "inbounds" in cfg:
        for inb in cfg["inbounds"]:
            rs = inb.get("streamSettings", {}).get("realitySettings", {})
            if "privateKey" in rs:
                rs["privateKey"] = "***REDACTED***"
    return cfg
