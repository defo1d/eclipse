#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  ECLIPSE VPN — Установщик v1.2
#  Ubuntu 22.04 / 24.04  |  sudo bash setup.sh
# ═══════════════════════════════════════════════════════════════════════════════

# НЕ используем set -e — обрабатываем ошибки вручную для лучшего контроля
set -uo pipefail

# ── Цвета ────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m'; DIM='\033[2m'; NC='\033[0m'

INSTALL_DIR="/opt/eclipse"
LOG="/tmp/eclipse_install.log"
ERRORS=()
STEP=0

> "$LOG"

# ── Утилиты ───────────────────────────────────────────────────────────────────
step() {
  STEP=$((STEP+1))
  echo ""
  echo -e "${B}${C}╔═══════════════════════════════════════════════════╗${NC}"
  printf  "${B}${C}║  ШАГ %d: %-43s║\n${NC}" "$STEP" "$*"
  echo -e "${B}${C}╚═══════════════════════════════════════════════════╝${NC}"
}
ok()      { echo -e "  ${G}✔${NC}  $*"; }
info()    { echo -e "  ${C}→${NC}  $*"; }
warn()    { echo -e "  ${Y}⚠${NC}  $*"; ERRORS+=("$*"); }
die() {
  echo ""
  echo -e "${R}${B}╔═══════════════════════════════════════════════════╗${NC}"
  echo -e "${R}${B}║  ОШИБКА — УСТАНОВКА ПРЕРВАНА                      ║${NC}"
  echo -e "${R}${B}╚═══════════════════════════════════════════════════╝${NC}"
  echo -e "  ${R}$*${NC}"
  echo ""
  echo -e "  ${DIM}Полный лог: ${LOG}${NC}"
  echo -e "  ${DIM}Последние строки:${NC}"
  tail -30 "$LOG" 2>/dev/null | sed 's/^/    /'
  exit 1
}

# Спиннер для долгих операций
spin_start() { _SPIN_MSG="$1"; _SPIN_PID=0; }
run_spin() {
  local msg="$1"; shift
  local spins='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  # Запускаем команду в фоне
  "$@" >>"$LOG" 2>&1 &
  local pid=$!
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C}${spins:$((i % ${#spins})):1}${NC}  ${DIM}%-56s${NC}" "$msg…"
    i=$((i+1))
    sleep 0.12
  done
  tput cnorm 2>/dev/null || true
  # Проверяем exit code
  if wait "$pid"; then
    printf "\r  ${G}✔${NC}  %-56s\n" "$msg"
    return 0
  else
    printf "\r  ${R}✗${NC}  %-56s\n" "$msg"
    echo ""
    echo -e "  ${R}Команда завершилась с ошибкой: $*${NC}"
    echo -e "  ${DIM}Последние строки лога:${NC}"
    tail -25 "$LOG" | sed 's/^/      /'
    echo ""
    die "Не удалось выполнить: $msg"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# БАННЕР
echo -e "${C}${B}"
cat << 'BANNER'

  ███████╗ ██████╗██╗     ██╗██████╗ ███████╗███████╗
  ██╔════╝██╔════╝██║     ██║██╔══██╗██╔════╝██╔════╝
  █████╗  ██║     ██║     ██║██████╔╝███████╗█████╗
  ██╔══╝  ██║     ██║     ██║██╔═══╝ ╚════██║██╔══╝
  ███████╗╚██████╗███████╗██║██║     ███████║███████╗
  ╚══════╝ ╚═════╝╚══════╝╚═╝╚═╝     ╚══════╝╚══════╝
           VPN INSTALLER v1.2

BANNER
echo -e "${NC}"

# ════════════════════════════════════════════════════════════════════════════
step "ПРОВЕРКА СИСТЕМЫ"

[[ $EUID -ne 0 ]] && die "Запустите от root:\n  sudo bash setup.sh"

source /etc/os-release 2>/dev/null || true
ok "ОС: ${PRETTY_NAME:-Unknown}"
ok "Ядро: $(uname -r)"
ok "Архитектура: $(uname -m)"
ok "Директория установки: ${INSTALL_DIR}"
ok "Лог: ${LOG}"

# ════════════════════════════════════════════════════════════════════════════
step "ВВОД ПАРАМЕТРОВ"

info "Определяем внешний IP…"
SERVER_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
  SERVER_IP=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
  [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  SERVER_IP=""
done
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
[[ -z "$SERVER_IP" ]] && SERVER_IP="0.0.0.0"

ok "IP сервера: ${B}${SERVER_IP}${NC}"
echo ""
read -rp "$(echo -e "  ${C}?${NC} Введите IP или домен [${B}${SERVER_IP}${NC}]: ")" _inp
SERVER_IP="${_inp:-$SERVER_IP}"
ok "Используем: ${B}${SERVER_IP}${NC}"

echo ""
while true; do
  read -rsp "$(echo -e "  ${C}?${NC} Пароль для веб-интерфейса (мин. 8 символов): ")" PASS1
  echo ""
  if [[ ${#PASS1} -lt 8 ]]; then
    echo -e "  ${R}✗  Слишком короткий${NC}"; continue
  fi
  read -rsp "$(echo -e "  ${C}?${NC} Повторите пароль: ")" PASS2
  echo ""
  if [[ "$PASS1" == "$PASS2" ]]; then
    UI_PASSWORD="$PASS1"
    ok "Пароль принят"
    break
  fi
  echo -e "  ${R}✗  Не совпадают — попробуйте ещё раз${NC}"
done

# ════════════════════════════════════════════════════════════════════════════
step "УСТАНОВКА ПАКЕТОВ"

run_spin "Обновление apt" apt-get update -qq
run_spin "Базовые пакеты" apt-get install -y -qq \
  curl wget git unzip ufw ca-certificates gnupg lsb-release software-properties-common

# ════════════════════════════════════════════════════════════════════════════
step "УСТАНОВКА DOCKER"

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
  ok "Docker уже установлен: ${DOCKER_VER}"
else
  run_spin "Добавление GPG-ключа Docker" bash -c '
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg'

  run_spin "Добавление репозитория Docker" bash -c '
    source /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq'

  run_spin "Установка Docker CE" \
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable docker >> "$LOG" 2>&1 || true
  systemctl start  docker >> "$LOG" 2>&1 || true
  ok "Docker установлен"
fi

if docker compose version >> "$LOG" 2>&1; then
  ok "Docker Compose: v2 ✔"
else
  run_spin "Установка docker-compose-plugin" apt-get install -y -qq docker-compose-plugin
fi

# ════════════════════════════════════════════════════════════════════════════
step "ГЕНЕРАЦИЯ X25519 КЛЮЧЕЙ"

# Ищем xray
XRAY_BIN=""
for candidate in xray /usr/local/bin/xray /usr/bin/xray; do
  if command -v "$candidate" &>/dev/null 2>&1; then
    XRAY_BIN="$candidate"
    break
  fi
done

if [[ -z "$XRAY_BIN" ]]; then
  info "Скачиваем xray binary…"
  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64|arm64) XARCH="arm64-v8a" ;;
    armv7*)        XARCH="arm32-v7a" ;;
    *)             XARCH="64" ;;
  esac

  # Получаем версию без падения
  XRAY_VER=$(curl -s --max-time 10 \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || true)
  [[ -z "$XRAY_VER" ]] && XRAY_VER="v24.9.30"
  info "Версия xray: ${XRAY_VER}"

  XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${XARCH}.zip"

  run_spin "Скачивание xray ${XRAY_VER}" wget -q "$XRAY_URL" -O /tmp/xray.zip
  run_spin "Распаковка xray" bash -c '
    unzip -qo /tmp/xray.zip xray -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -f /tmp/xray.zip'

  XRAY_BIN="/usr/local/bin/xray"
fi

ok "Xray binary: ${XRAY_BIN}"
echo -n "  ${C}→${NC}  Генерация ключей… "

# Запускаем x25519 и сохраняем вывод (без 2>/dev/null чтобы видеть ошибки)
KEY_RAW=$("$XRAY_BIN" x25519 2>>"$LOG") || {
  echo -e "${R}ОШИБКА${NC}"
  die "xray x25519 завершился с ошибкой. Лог: $LOG"
}

echo -e "${G}OK${NC}"
echo "xray x25519 output: $KEY_RAW" >> "$LOG"

# Парсим — поддерживаем разные форматы вывода разных версий xray
PRIVATE_KEY=$(echo "$KEY_RAW" | grep -i "private" | grep -oE '[A-Za-z0-9+/=_-]{40,}' | head -1 || true)
PUBLIC_KEY=$(echo  "$KEY_RAW" | grep -i "public"  | grep -oE '[A-Za-z0-9+/=_-]{40,}' | head -1 || true)

# Fallback: просто берём строки по порядку
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  PRIVATE_KEY=$(echo "$KEY_RAW" | awk 'NR==1{print $NF}')
  PUBLIC_KEY=$(echo  "$KEY_RAW" | awk 'NR==2{print $NF}')
fi

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  die "Не удалось распарсить ключи.\nВывод xray x25519:\n${KEY_RAW}"
fi

ok "Private Key: ${B}${PRIVATE_KEY:0:16}…${NC}"
ok "Public Key:  ${B}${PUBLIC_KEY}${NC}"

# ════════════════════════════════════════════════════════════════════════════
step "НАСТРОЙКА FIREWALL (UFW)"

ufw --force reset         >> "$LOG" 2>&1 || true
ufw default deny incoming >> "$LOG" 2>&1 || true
ufw default allow outgoing >> "$LOG" 2>&1 || true
for p in 22 80 443 8080 8443; do
  ufw allow "${p}/tcp"    >> "$LOG" 2>&1 || true
  ok "Порт ${p}/tcp — разрешён"
done
ufw --force enable        >> "$LOG" 2>&1 || true
ok "UFW включён"

# ════════════════════════════════════════════════════════════════════════════
step "ПОДГОТОВКА ФАЙЛОВ ПРОЕКТА"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Источник файлов: ${SCRIPT_DIR}"
info "Назначение: ${INSTALL_DIR}"

mkdir -p "${INSTALL_DIR}"/{backend,frontend,nginx,data,xray_config,xray_logs}

# Копируем все файлы проекта
COPY_OK=true
for f in \
  "docker-compose.yml" \
  "backend/main.py" \
  "backend/Dockerfile" \
  "backend/requirements.txt" \
  "frontend/index.html" \
  "nginx/nginx.conf"
do
  SRC="${SCRIPT_DIR}/${f}"
  DST="${INSTALL_DIR}/${f}"
  mkdir -p "$(dirname "$DST")"
  if [[ -f "$SRC" ]]; then
    cp "$SRC" "$DST"
    ok "Скопирован: ${f}"
  else
    warn "Файл не найден: ${f}"
    COPY_OK=false
  fi
done

[[ "$COPY_OK" == "false" ]] && warn "Некоторые файлы отсутствуют. Запустите setup.sh из папки проекта!"

# Начальный конфиг xray
cat > "${INSTALL_DIR}/xray_config/config.json" << 'XCFG'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}
XCFG
ok "Начальный xray config создан"

# ════════════════════════════════════════════════════════════════════════════
step "СОЗДАНИЕ .env"

cat > "${INSTALL_DIR}/.env" << ENVEOF
ECLIPS_PASSWORD=${UI_PASSWORD}
SERVER_IP=${SERVER_IP}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
DATA_PATH=/app/data
ENVEOF
chmod 600 "${INSTALL_DIR}/.env"
ok ".env создан → ${INSTALL_DIR}/.env  (права 600)"

# ════════════════════════════════════════════════════════════════════════════
step "ЗАПУСК DOCKER СТЕКА"

cd "${INSTALL_DIR}"

# Останавливаем старое если есть
info "Останавливаем предыдущий стек (если был)…"
docker compose down --remove-orphans >> "$LOG" 2>&1 || true

run_spin "Pull: teddysun/xray"      docker pull teddysun/xray:latest
run_spin "Pull: nginx:alpine"       docker pull nginx:alpine
run_spin "Pull: python:3.12-slim"   docker pull python:3.12-slim

run_spin "Build: backend контейнер" docker compose --env-file .env build --no-cache

info "Запускаем контейнеры…"
if docker compose --env-file .env up -d >> "$LOG" 2>&1; then
  ok "docker compose up — выполнено"
else
  echo -e "\n${R}  Ошибка docker compose up:${NC}"
  tail -30 "$LOG" | sed 's/^/    /'
  die "Не удалось запустить стек"
fi

# ════════════════════════════════════════════════════════════════════════════
step "ПРОВЕРКА ЗАПУСКА (до 90 секунд)"

echo ""
ALL_OK=false

for attempt in $(seq 1 18); do
  sleep 5
  SECS=$((attempt * 5))

  # Статусы контейнеров
  ST_XRAY=$(docker inspect --format='{{.State.Status}}' eclips_xray    2>/dev/null || echo "—")
  ST_BACK=$(docker inspect --format='{{.State.Status}}' eclips_backend 2>/dev/null || echo "—")
  ST_NGX=$(docker inspect --format='{{.State.Status}}'  eclips_nginx   2>/dev/null || echo "—")

  # HTTP-проверки
  HTTP_API=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8080/health 2>/dev/null || echo "—")
  HTTP_WEB=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1/          2>/dev/null || echo "—")

  # Иконки
  icon() { [[ "$1" == "running" || "$1" == "200" ]] && echo -e "${G}✔${NC}" || echo -e "${Y}${1}${NC}"; }

  printf "  ${DIM}[%3ds]${NC}  xray=%-3b  backend=%-3b  nginx=%-3b  api=${HTTP_API}  web=${HTTP_WEB}\n" \
    "$SECS" "$(icon $ST_XRAY)" "$(icon $ST_BACK)" "$(icon $ST_NGX)"

  if [[ "$ST_XRAY" == "running" && "$ST_BACK" == "running" && \
        "$ST_NGX"  == "running" && "$HTTP_API" == "200" && "$HTTP_WEB" == "200" ]]; then
    ALL_OK=true
    break
  fi
done

echo ""

# Итоговый статус каждого контейнера
check_svc() {
  local label="$1" name="$2"
  local st
  st=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "не найден")
  if [[ "$st" == "running" ]]; then
    ok "${label}: ${G}${B}RUNNING${NC}"
  else
    warn "${label}: ${R}${B}${st}${NC}"
    echo -e "  ${DIM}  Логи ${name}:${NC}"
    docker logs --tail 25 "$name" 2>&1 | sed 's/^/      /' || true
  fi
}

check_svc "Xray-core"       "eclips_xray"
check_svc "FastAPI Backend" "eclips_backend"
check_svc "Nginx"           "eclips_nginx"

F_API=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8080/health 2>/dev/null || echo "—")
F_WEB=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1/ 2>/dev/null || echo "—")

[[ "$F_API" == "200" ]] && ok "API /health: ${G}${B}HTTP 200${NC}" \
  || warn "API /health: HTTP ${F_API} (стартует, подождите минуту)"
[[ "$F_WEB" == "200" ]] && ok "Веб-интерфейс: ${G}${B}HTTP 200${NC}" \
  || warn "Веб-интерфейс: HTTP ${F_WEB} (проверьте nginx)"

# ════════════════════════════════════════════════════════════════════════════
# ФИНАЛЬНАЯ ИНСТРУКЦИЯ
# ════════════════════════════════════════════════════════════════════════════
echo ""
if $ALL_OK; then
  echo -e "${G}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${G}${B}║              ✅  ECLIPSE VPN УСТАНОВЛЕН!                  ║${NC}"
  echo -e "${G}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
else
  echo -e "${Y}${B}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${Y}${B}║     ⚠  УСТАНОВКА ЗАВЕРШЕНА С ПРЕДУПРЕЖДЕНИЯМИ             ║${NC}"
  echo -e "${Y}${B}╚═══════════════════════════════════════════════════════════╝${NC}"
  warn "Некоторые сервисы не ответили за 90 сек — попробуйте проверить через минуту"
fi

echo ""
echo -e "${B}${Y}  ┌──────────────────────────────────────────────────────┐${NC}"
echo -e "${B}${Y}  │             КАК ЗАЙТИ В ВЕБ-ИНТЕРФЕЙС               │${NC}"
echo -e "${B}${Y}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Откройте в браузере:"
echo ""
echo -e "  ${B}${C}     ➜  http://${SERVER_IP}/${NC}"
echo ""
echo -e "  Логин:   ${B}eclips${NC}"
echo -e "  Пароль:  ${B}[указанный при установке]${NC}"
echo ""
echo -e "${B}  ┌──────────────────────────────────────────────────────┐${NC}"
echo -e "${B}  │              ПАРАМЕТРЫ VPN                           │${NC}"
echo -e "${B}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  Протокол:  VLESS + Reality"
echo -e "  Сервер:    ${C}${SERVER_IP}${NC}"
echo -e "  TCP:       ${C}порт 443${NC}   (xtls-rprx-vision, uTLS Safari)"
echo -e "  gRPC:      ${C}порт 8443${NC}  (multiPath, uTLS Chrome)"
echo -e "  PublicKey: ${C}${PUBLIC_KEY}${NC}"
echo ""
echo -e "  ${DIM}QR-коды и VLESS-ссылки → в веб-интерфейсе${NC}"
echo ""
echo -e "${B}  ┌──────────────────────────────────────────────────────┐${NC}"
echo -e "${B}  │              УПРАВЛЕНИЕ СТЕКОМ                       │${NC}"
echo -e "${B}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${C}cd ${INSTALL_DIR}${NC}"
echo ""
echo -e "  Статус:     ${C}docker compose ps${NC}"
echo -e "  Логи live:  ${C}docker compose logs -f${NC}"
echo -e "  Перезапуск: ${C}docker compose restart${NC}"
echo -e "  Остановить: ${C}docker compose down${NC}"
echo ""
echo -e "  Ключи/пароль: ${C}cat ${INSTALL_DIR}/.env${NC}"
echo -e "  Лог установки: ${C}cat ${LOG}${NC}"
echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo -e "${Y}${B}  ┌──────────────────────────────────────────────────────┐${NC}"
  echo -e "${Y}${B}  │    ⚠  ПРЕДУПРЕЖДЕНИЯ                                 │${NC}"
  echo -e "${Y}${B}  └──────────────────────────────────────────────────────┘${NC}"
  for e in "${ERRORS[@]}"; do echo -e "  ${Y}•${NC} $e"; done
  echo ""
fi

echo -e "${G}${B}═══════════════════════════════════════════════════════════${NC}"
echo ""
