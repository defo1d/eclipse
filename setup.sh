#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  ECLIPS VPN — One-Line Installer
#  Поддерживаемые ОС: Ubuntu 22.04 / 24.04
#  Использование:   bash setup.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $*"; }

echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ███████╗ ██████╗██╗     ██╗██████╗ ███████╗
  ██╔════╝██╔════╝██║     ██║██╔══██╗██╔════╝
  █████╗  ██║     ██║     ██║██████╔╝███████╗
  ██╔══╝  ██║     ██║     ██║██╔═══╝ ╚════██║
  ███████╗╚██████╗███████╗██║██║     ███████║
  ╚══════╝ ╚═════╝╚══════╝╚═╝╚═╝     ╚══════╝
          VPN INSTALLER v1.0
EOF
echo -e "${NC}"

# ── Root check ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запустите скрипт от root: sudo bash setup.sh"

# ── OS check ────────────────────────────────────────────────────────────────
. /etc/os-release 2>/dev/null || true
if [[ "${ID:-}" != "ubuntu" ]]; then
  warn "Обнаружена не Ubuntu. Продолжение на свой риск."
fi

# ── Interactive config ───────────────────────────────────────────────────────
info "Определяем внешний IP сервера…"
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || echo "0.0.0.0")
log "Внешний IP: ${SERVER_IP}"

read -rp "$(echo -e "${CYAN}[?]${NC} Укажите IP/домен сервера [${SERVER_IP}]: ")" input_ip
SERVER_IP="${input_ip:-$SERVER_IP}"

read -rsp "$(echo -e "${CYAN}[?]${NC} Пароль для веб-интерфейса (min 12 символов): ")" UI_PASSWORD
echo
[[ ${#UI_PASSWORD} -lt 12 ]] && err "Пароль слишком короткий"

read -rsp "$(echo -e "${CYAN}[?]${NC} Повторите пароль: ")" UI_PASSWORD2
echo
[[ "$UI_PASSWORD" != "$UI_PASSWORD2" ]] && err "Пароли не совпадают"

INSTALL_DIR="${INSTALL_DIR:-/opt/eclips}"

# ── Install dependencies ─────────────────────────────────────────────────────
info "Обновление пакетов и установка зависимостей…"
apt-get update -qq
apt-get install -y -qq \
  curl wget git ufw ca-certificates \
  gnupg lsb-release software-properties-common

# ── Install Docker ───────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "Установка Docker…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  log "Docker установлен"
else
  log "Docker уже установлен: $(docker --version)"
fi

# docker compose (v2)
if ! docker compose version &>/dev/null; then
  info "Установка docker-compose-plugin…"
  apt-get install -y -qq docker-compose-plugin
fi

# ── Install xray binary (for key generation) ─────────────────────────────────
info "Генерация X25519 ключей Xray…"
if ! command -v xray &>/dev/null; then
  XRAY_VERSION="v24.3.18"
  ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]] && XARCH="64" || XARCH="arm64-v8a"
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XARCH}.zip"
  wget -q "$XRAY_URL" -O /tmp/xray.zip
  unzip -qo /tmp/xray.zip xray -d /usr/local/bin/
  chmod +x /usr/local/bin/xray
  rm /tmp/xray.zip
fi

KEY_OUTPUT=$(xray x25519 2>/dev/null || /usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo  "$KEY_OUTPUT" | grep "Public key:"  | awk '{print $3}')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  err "Не удалось сгенерировать ключи. Проверьте xray binary."
fi

log "Private key: ${PRIVATE_KEY:0:8}…"
log "Public key:  ${PUBLIC_KEY:0:8}…"

# ── Configure UFW ────────────────────────────────────────────────────────────
info "Настройка UFW firewall…"
ufw --force reset > /dev/null
ufw default deny incoming  > /dev/null
ufw default allow outgoing > /dev/null
ufw allow ssh              > /dev/null
ufw allow 443/tcp          > /dev/null   # VLESS+Reality TCP
ufw allow 8443/tcp         > /dev/null   # VLESS+Reality gRPC
ufw allow 80/tcp           > /dev/null   # Web dashboard
ufw allow 8080/tcp         > /dev/null   # API (если нужен прямой доступ)
ufw --force enable         > /dev/null
log "UFW настроен: порты 443, 8443, 80, 8080"

# ── Create install directory ─────────────────────────────────────────────────
info "Создание директории ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}"/{backend,frontend,nginx,data}

# Copy project files if running from source dir, otherwise download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
  cp -r "${SCRIPT_DIR}"/* "${INSTALL_DIR}/"
  log "Файлы проекта скопированы из ${SCRIPT_DIR}"
else
  warn "Файлы проекта не найдены рядом. Клонируем репозиторий…"
  # Replace with your actual repo URL
  git clone https://github.com/your-org/eclips "${INSTALL_DIR}/src" 2>/dev/null || true
fi

# ── Generate .env ────────────────────────────────────────────────────────────
info "Генерация .env файла…"
cat > "${INSTALL_DIR}/.env" << ENVEOF
ECLIPS_PASSWORD=${UI_PASSWORD}
SERVER_IP=${SERVER_IP}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
ENVEOF
chmod 600 "${INSTALL_DIR}/.env"
log ".env создан с правами 600"

# ── Create initial xray config dir ───────────────────────────────────────────
mkdir -p "${INSTALL_DIR}/xray_config"
mkdir -p "${INSTALL_DIR}/xray_logs"

# ── Start stack ──────────────────────────────────────────────────────────────
info "Запуск Docker Compose стека…"
cd "${INSTALL_DIR}"
docker compose --env-file .env pull --quiet 2>/dev/null || true
docker compose --env-file .env up -d --build

# ── Wait for health check ────────────────────────────────────────────────────
info "Ожидание запуска сервисов (30 сек)…"
sleep 15

for i in $(seq 1 5); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    log "Backend API работает (HTTP 200)"
    break
  fi
  info "Попытка ${i}/5… HTTP ${STATUS}"
  sleep 5
done

# ── Print summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ECLIPS VPN УСПЕШНО УСТАНОВЛЕН!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Веб-интерфейс:${NC}  http://${SERVER_IP}/"
echo -e "  ${CYAN}API:${NC}            http://${SERVER_IP}:8080/api/"
echo -e "  ${CYAN}Логин:${NC}          eclips"
echo -e "  ${CYAN}Пароль:${NC}         [указанный вами]"
echo ""
echo -e "  ${YELLOW}VLESS порты:${NC}"
echo -e "  • TCP  port 443  (VLESS + Reality)"
echo -e "  • gRPC port 8443 (VLESS + Reality multiPath)"
echo ""
echo -e "  ${YELLOW}Public Key:${NC} ${PUBLIC_KEY}"
echo ""
echo -e "  ${RED}ВАЖНО:${NC} Сохраните .env файл: ${INSTALL_DIR}/.env"
echo -e "  ${RED}ВАЖНО:${NC} Никому не передавайте Private Key!"
echo ""
echo -e "  Управление: cd ${INSTALL_DIR} && docker compose logs -f"
echo -e "  Остановка:  cd ${INSTALL_DIR} && docker compose down"
echo ""
