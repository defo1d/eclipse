#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  ECLIPSE VPN — Установщик v1.1
#  Ubuntu 22.04 / 24.04
#  Запуск: sudo bash setup.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m'; DIM='\033[2m'; NC='\033[0m'

STEP=0
ERRORS=()
INSTALL_DIR="/opt/eclipse"

# ── Утилиты вывода ────────────────────────────────────────────────────────────
step() {
  STEP=$((STEP+1))
  echo ""
  echo -e "${B}${C}╔═══════════════════════════════════════════════════╗${NC}"
  printf "${B}${C}║  ШАГ %d: %-43s║${NC}\n" "$STEP" "$*"
  echo -e "${B}${C}╚═══════════════════════════════════════════════════╝${NC}"
}
ok()   { echo -e "  ${G}✔${NC}  $*"; }
info() { echo -e "  ${C}→${NC}  $*"; }
warn() { echo -e "  ${Y}⚠${NC}  $*"; ERRORS+=("$*"); }
fail() {
  echo ""
  echo -e "${R}${B}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${R}${B}║  ОШИБКА УСТАНОВКИ                                 ║${NC}"
  echo -e "${R}${B}╚═══════════════════════════════════════════════════╝${NC}"
  echo -e "  ${R}$*${NC}"
  echo ""
  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "${Y}Предупреждения во время установки:${NC}"
    for e in "${ERRORS[@]}"; do echo -e "  ${Y}•${NC} $e"; done
    echo ""
  fi
  echo -e "  ${DIM}Лог последней команды: /tmp/eclipse_install.log${NC}"
  exit 1
}

# ── Спиннер ───────────────────────────────────────────────────────────────────
spinner() {
  local pid=$1 msg=$2
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C}${spin:$((i % ${#spin})):1}${NC}  ${DIM}%-55s${NC}" "$msg…"
    i=$((i+1)); sleep 0.1
  done
  tput cnorm 2>/dev/null || true
  printf "\r  ${G}✔${NC}  %-55s\n" "$msg"
}

run_silent() {
  local msg="$1"; shift
  "$@" >>/tmp/eclipse_install.log 2>&1 &
  local pid=$!
  spinner $pid "$msg"
  if ! wait $pid; then
    echo ""
    echo -e "  ${R}✗  Не удалось: $msg${NC}"
    echo -e "  ${DIM}Последние строки лога:${NC}"
    tail -20 /tmp/eclipse_install.log | sed 's/^/      /'
    fail "Остановка из-за ошибки"
  fi
}

# ── Баннер ────────────────────────────────────────────────────────────────────
echo -e "${C}${B}"
cat << 'BANNER'

  ███████╗ ██████╗██╗     ██╗██████╗ ███████╗███████╗
  ██╔════╝██╔════╝██║     ██║██╔══██╗██╔════╝██╔════╝
  █████╗  ██║     ██║     ██║██████╔╝███████╗█████╗
  ██╔══╝  ██║     ██║     ██║██╔═══╝ ╚════██║██╔══╝
  ███████╗╚██████╗███████╗██║██║     ███████║███████╗
  ╚══════╝ ╚═════╝╚══════╝╚═╝╚═╝     ╚══════╝╚══════╝

           VPN INSTALLER v1.1

BANNER
echo -e "${NC}"

> /tmp/eclipse_install.log  # очищаем лог

# ════════════════════════════════════════════════════════════════════════════
step "ПРОВЕРКА СИСТЕМЫ"

[[ $EUID -ne 0 ]] && fail "Запустите скрипт от root:  sudo bash setup.sh"

. /etc/os-release 2>/dev/null || true
ok "ОС: ${PRETTY_NAME:-Unknown}"
ok "Архитектура: $(uname -m)"
ok "Директория установки: ${INSTALL_DIR}"

# ════════════════════════════════════════════════════════════════════════════
step "ВВОД ПАРАМЕТРОВ"

# Определяем IP
SERVER_IP=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null \
         || curl -s --max-time 6 https://ifconfig.me 2>/dev/null \
         || hostname -I 2>/dev/null | awk '{print $1}' \
         || echo "")

if [[ -n "$SERVER_IP" ]]; then
  ok "Внешний IP определён: ${B}${SERVER_IP}${NC}"
else
  warn "Не удалось определить внешний IP"
  SERVER_IP="YOUR_SERVER_IP"
fi

echo ""
read -rp "$(echo -e "  ${C}?${NC} IP или домен сервера [${B}${SERVER_IP}${NC}]: ")" _input
SERVER_IP="${_input:-$SERVER_IP}"
ok "Сервер: ${B}${SERVER_IP}${NC}"

echo ""
while true; do
  read -rsp "$(echo -e "  ${C}?${NC} Придумайте пароль для веб-интерфейса (мин. 8 символов): ")" UI_PASSWORD
  echo ""
  if [[ ${#UI_PASSWORD} -lt 8 ]]; then
    echo -e "  ${R}✗  Слишком короткий — минимум 8 символов${NC}"; continue
  fi
  read -rsp "$(echo -e "  ${C}?${NC} Повторите пароль: ")" UI_PASSWORD2
  echo ""
  [[ "$UI_PASSWORD" == "$UI_PASSWORD2" ]] && { ok "Пароль принят"; break; }
  echo -e "  ${R}✗  Пароли не совпадают${NC}"
done

# ════════════════════════════════════════════════════════════════════════════
step "УСТАНОВКА ПАКЕТОВ"

run_silent "Обновление apt" apt-get update -qq
run_silent "Установка базовых пакетов" \
  apt-get install -y -qq curl wget git unzip ufw ca-certificates \
    gnupg lsb-release software-properties-common

# ════════════════════════════════════════════════════════════════════════════
step "УСТАНОВКА DOCKER"

if command -v docker &>/dev/null; then
  ok "Docker уже установлен: $(docker --version | awk '{print $3}' | tr -d ',')"
else
  run_silent "Добавление GPG-ключа Docker" bash -c '
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg'

  run_silent "Добавление репозитория Docker" bash -c '
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq'

  run_silent "Установка Docker CE" \
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker >>/tmp/eclipse_install.log 2>&1
  systemctl start  docker >>/tmp/eclipse_install.log 2>&1
  ok "Docker установлен: $(docker --version | awk '{print $3}' | tr -d ',')"
fi

if docker compose version &>/dev/null; then
  ok "Docker Compose: $(docker compose version 2>/dev/null | awk '{print $4}' || echo 'v2')"
else
  run_silent "Установка docker-compose-plugin" apt-get install -y -qq docker-compose-plugin
  ok "Docker Compose установлен"
fi

# ════════════════════════════════════════════════════════════════════════════
step "ГЕНЕРАЦИЯ X25519 КЛЮЧЕЙ (Xray)"

XRAY_BIN=""
for candidate in xray /usr/local/bin/xray; do
  command -v "$candidate" &>/dev/null && { XRAY_BIN="$candidate"; break; }
done

if [[ -z "$XRAY_BIN" ]]; then
  ARCH=$(uname -m)
  [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && XARCH="arm64-v8a" || XARCH="64"

  XRAY_VER=$(curl -s --max-time 10 \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4 2>/dev/null || echo "v24.9.30")
  info "Xray версия: ${XRAY_VER}"

  run_silent "Скачивание Xray-core ${XRAY_VER}" \
    wget -q "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XARCH}.zip" \
      -O /tmp/xray.zip

  run_silent "Распаковка Xray" bash -c '
    unzip -qo /tmp/xray.zip xray -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -f /tmp/xray.zip'

  XRAY_BIN="/usr/local/bin/xray"
fi

ok "Xray binary: ${XRAY_BIN}"

KEY_OUTPUT=$($XRAY_BIN x25519 2>/dev/null) \
  || fail "Не удалось сгенерировать X25519 ключи"

PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i "private" | awk '{print $NF}')
PUBLIC_KEY=$(echo  "$KEY_OUTPUT" | grep -i "public"  | awk '{print $NF}')

[[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] \
  && fail "Ошибка парсинга ключей. Вывод:\n$KEY_OUTPUT"

ok "Private Key: ${B}${PRIVATE_KEY:0:14}…${NC}  (сохранён в .env)"
ok "Public Key:  ${B}${PUBLIC_KEY}${NC}"

# ════════════════════════════════════════════════════════════════════════════
step "НАСТРОЙКА FIREWALL"

ufw --force reset    >>/tmp/eclipse_install.log 2>&1
ufw default deny incoming  >>/tmp/eclipse_install.log 2>&1
ufw default allow outgoing >>/tmp/eclipse_install.log 2>&1
for port in 22 80 443 8080 8443; do
  ufw allow $port/tcp >>/tmp/eclipse_install.log 2>&1
done
ufw --force enable >>/tmp/eclipse_install.log 2>&1

ok "Порты открыты: 22 (SSH)  80 (Web UI)  443 (VLESS/TCP)  8443 (VLESS/gRPC)  8080 (API)"

# ════════════════════════════════════════════════════════════════════════════
step "ПОДГОТОВКА ФАЙЛОВ ПРОЕКТА"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Копируем файлы из: ${SCRIPT_DIR}"

mkdir -p "${INSTALL_DIR}"/{backend,frontend,nginx,data,xray_logs}

REQUIRED_FILES=(
  "docker-compose.yml"
  "backend/main.py"
  "backend/Dockerfile"
  "backend/requirements.txt"
  "frontend/index.html"
  "nginx/nginx.conf"
)

ALL_PRESENT=true
for f in "${REQUIRED_FILES[@]}"; do
  src="${SCRIPT_DIR}/${f}"
  dst="${INSTALL_DIR}/${f}"
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
    ok "Скопирован: ${f}"
  else
    warn "Не найден: ${f}"
    ALL_PRESENT=false
  fi
done

[[ "$ALL_PRESENT" == "false" ]] && warn "Некоторые файлы отсутствуют — убедитесь что setup.sh запущен из папки проекта Eclipse"

# Создаём начальный пустой конфиг xray чтобы volume монтировался нормально
mkdir -p "${INSTALL_DIR}/xray_config"
[[ ! -f "${INSTALL_DIR}/xray_config/config.json" ]] && echo '{}' > "${INSTALL_DIR}/xray_config/config.json"

# ════════════════════════════════════════════════════════════════════════════
step "СОЗДАНИЕ .env ФАЙЛА"

cat > "${INSTALL_DIR}/.env" << ENVEOF
ECLIPS_PASSWORD=${UI_PASSWORD}
SERVER_IP=${SERVER_IP}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
DATA_PATH=/app/data
ENVEOF
chmod 600 "${INSTALL_DIR}/.env"

ok "Файл .env создан: ${INSTALL_DIR}/.env  (права 600)"

# ════════════════════════════════════════════════════════════════════════════
step "ЗАПУСК DOCKER СТЕКА"

cd "${INSTALL_DIR}"

# Останавливаем если уже запущено
docker compose down >>/tmp/eclipse_install.log 2>&1 || true

run_silent "Загрузка образа teddysun/xray"  docker pull teddysun/xray:latest
run_silent "Загрузка образа nginx:alpine"   docker pull nginx:alpine
run_silent "Загрузка образа python:3.12-slim" docker pull python:3.12-slim

run_silent "Сборка backend контейнера" \
  docker compose --env-file .env build --no-cache

info "Поднимаем контейнеры…"
docker compose --env-file .env up -d >>/tmp/eclipse_install.log 2>&1
ok "Команда docker compose up выполнена"

# ════════════════════════════════════════════════════════════════════════════
step "ОЖИДАНИЕ И ПРОВЕРКА ЗАПУСКА"

echo ""
info "Проверяем готовность сервисов (до 90 секунд)…"
echo ""

declare -A SVC_STATUS=(
  [eclips_xray]=false
  [eclips_backend]=false
  [eclips_nginx]=false
)
API_OK=false
WEB_OK=false

for i in $(seq 1 18); do
  sleep 5

  for c in eclips_xray eclips_backend eclips_nginx; do
    ST=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "—")
    [[ "$ST" == "running" ]] && SVC_STATUS[$c]=true
  done

  HTTP_API=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    http://localhost:8080/health 2>/dev/null || echo "—")
  HTTP_WEB=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    http://localhost/ 2>/dev/null || echo "—")

  [[ "$HTTP_API" == "200" ]] && API_OK=true
  [[ "$HTTP_WEB" == "200" ]] && WEB_OK=true

  # Красивая строка прогресса
  xray_icon="${SVC_STATUS[eclips_xray]}" && [[ "$xray_icon" == "true" ]] && xi="${G}✔${NC}" || xi="${Y}…${NC}"
  back_icon="${SVC_STATUS[eclips_backend]}" && [[ "$back_icon" == "true" ]] && bi="${G}✔${NC}" || bi="${Y}…${NC}"
  ngnx_icon="${SVC_STATUS[eclips_nginx]}" && [[ "$ngnx_icon" == "true" ]] && ni="${G}✔${NC}" || ni="${Y}…${NC}"
  [[ "$API_OK" == "true" ]] && ai="${G}✔ 200${NC}" || ai="${Y}${HTTP_API}${NC}"
  [[ "$WEB_OK" == "true" ]] && wi="${G}✔ 200${NC}" || wi="${Y}${HTTP_WEB}${NC}"

  printf "  [%2ds]  xray %b  backend %b  nginx %b  api %b  web %b\n" \
    $((i*5)) "$xi" "$bi" "$ni" "$ai" "$wi"

  if ${SVC_STATUS[eclips_xray]} && ${SVC_STATUS[eclips_backend]} && \
     ${SVC_STATUS[eclips_nginx]} && $API_OK && $WEB_OK; then
    echo ""
    ok "${G}${B}Все сервисы запущены и отвечают!${NC}"
    break
  fi
done

echo ""

# Финальный отчёт
echo -e "  ${B}Итоговый статус:${NC}"
for c in eclips_xray eclips_backend eclips_nginx; do
  ST=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "не найден")
  LABEL="${c/eclips_/}"
  if [[ "$ST" == "running" ]]; then
    ok "${LABEL}: ${G}${B}RUNNING${NC}"
  else
    warn "${LABEL}: ${R}${B}${ST}${NC}"
    echo -e "  ${DIM}  Логи ${c} (последние 20 строк):${NC}"
    docker logs --tail 20 "$c" 2>&1 | sed 's/^/      /' || true
  fi
done

$API_OK && ok "Backend API: ${G}${B}HTTP 200${NC}" || warn "Backend API не отвечает — попробуйте через минуту"
$WEB_OK && ok "Веб-интерфейс: ${G}${B}HTTP 200${NC}" || warn "Nginx не отвечает — попробуйте через минуту"

# ════════════════════════════════════════════════════════════════════════════
# ФИНАЛЬНАЯ ИНСТРУКЦИЯ
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
echo -e "${G}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${G}${B}║              ✅  ECLIPSE VPN УСТАНОВЛЕН                   ║${NC}"
echo -e "${G}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${B}${Y}  ┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${B}${Y}  │              КАК ЗАЙТИ В ВЕБ-ИНТЕРФЕЙС              │${NC}"
echo -e "${B}${Y}  └─────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Откройте в браузере:"
echo ""
echo -e "  ${B}${C}  ➜  http://${SERVER_IP}/${NC}"
echo ""
echo -e "  Логин:   ${B}eclips${NC}"
echo -e "  Пароль:  ${B}[указанный вами при установке]${NC}"
echo ""
echo -e "${B}  ┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${B}  │            ПАРАМЕТРЫ VPN ПОДКЛЮЧЕНИЯ                │${NC}"
echo -e "${B}  └─────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Сервер:         ${C}${SERVER_IP}${NC}"
echo -e "  TCP порт 443:   ${C}VLESS + Reality  (xtls-rprx-vision, uTLS Safari)${NC}"
echo -e "  gRPC порт 8443: ${C}VLESS + Reality  (multiPath, uTLS Chrome)${NC}"
echo -e "  Public Key:     ${C}${PUBLIC_KEY}${NC}"
echo ""
echo -e "  ${DIM}QR-коды и готовые VLESS-ссылки — в веб-интерфейсе${NC}"
echo ""
echo -e "${B}  ┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${B}  │                 УПРАВЛЕНИЕ СТЕКОМ                   │${NC}"
echo -e "${B}  └─────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Статус:      ${C}cd ${INSTALL_DIR} && docker compose ps${NC}"
echo -e "  Логи live:   ${C}cd ${INSTALL_DIR} && docker compose logs -f${NC}"
echo -e "  Перезапуск:  ${C}cd ${INSTALL_DIR} && docker compose restart${NC}"
echo -e "  Остановить:  ${C}cd ${INSTALL_DIR} && docker compose down${NC}"
echo ""
echo -e "  Ключи и пароль: ${C}cat ${INSTALL_DIR}/.env${NC}"
echo -e "  Лог установки:  ${C}cat /tmp/eclipse_install.log${NC}"
echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo -e "${Y}${B}  ┌─────────────────────────────────────────────────────┐${NC}"
  echo -e "${Y}${B}  │    ⚠  ПРЕДУПРЕЖДЕНИЯ (изучите при проблемах)        │${NC}"
  echo -e "${Y}${B}  └─────────────────────────────────────────────────────┘${NC}"
  for e in "${ERRORS[@]}"; do echo -e "  ${Y}•${NC} $e"; done
  echo ""
fi

echo -e "${G}${B}═══════════════════════════════════════════════════════════${NC}"
echo ""
