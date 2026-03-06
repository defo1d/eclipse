# ECLIPS VPN — Руководство по подключению

## Подключение через Shadowrocket (iOS / macOS)

### 1. Получение ссылки

Откройте веб-интерфейс: `http://YOUR_SERVER_IP/`  
Авторизуйтесь (логин: `eclips`, пароль — установленный при инсталляции).  
Перейдите в раздел **"VLESS Ссылки"**.

---

### 2. Импорт через QR-код (быстрый способ)

1. В Shadowrocket нажмите **"+"** → **"Scan QR Code"**
2. Наведите камеру на QR-код в разделе **"QR КОДЫ"** дашборда
3. Сохраните конфигурацию

---

### 3. Импорт через ссылку

1. Скопируйте VLESS-ссылку из дашборда (нажмите на блок со ссылкой)
2. В Shadowrocket нажмите **"+"** → **"Type: URI"**
3. Вставьте ссылку → **"Done"**

---

### 4. Настройка фрагментации (обязательно при DPI-блокировке)

Фрагментация TCP-рукопожатия позволяет обходить DPI, которые анализируют первые пакеты TLS ClientHello.

**В Shadowrocket:**

1. Откройте импортированный сервер
2. Нажмите на него → **"Edit"**
3. Прокрутите вниз → раздел **"Plugin"** или **"Advanced"**
4. Включите: **"TCP Fragment"** (если доступно в вашей версии)

**Альтернативно через конфиг (config.conf):**

```ini
[General]
# Включить фрагментацию TLS
tls-fragment = true
tls-fragment-size = 1-5
tls-fragment-sleep = 1-5

[Proxy]
ECLIPS-TCP = vless, YOUR_SERVER_IP, 443, username=YOUR_UUID, tls=true, security=reality, reality-public-key=YOUR_PUBLIC_KEY, reality-short-id=YOUR_SHORT_ID, sni=icloud.com, fingerprint=safari, flow=xtls-rprx-vision, fast-open=true

ECLIPS-GRPC = vless, YOUR_SERVER_IP, 8443, username=YOUR_UUID, tls=true, security=reality, reality-public-key=YOUR_PUBLIC_KEY, reality-short-id=YOUR_SHORT_ID, sni=icloud.com, fingerprint=chrome, transport=grpc, grpc-service-name=eclips-grpc
```

---

### 5. Параметры подключения (ручная настройка)

| Параметр | TCP (порт 443) | gRPC (порт 8443) |
|---|---|---|
| Protocol | VLESS | VLESS |
| Security | Reality | Reality |
| Transport | TCP | gRPC |
| Flow | xtls-rprx-vision | — |
| SNI | icloud.com* | icloud.com* |
| Fingerprint (uTLS) | safari | chrome |
| gRPC ServiceName | — | eclips-grpc |
| gRPC Mode | — | multi |

*SNI меняется автоматически каждые 24 часа. Актуальное значение — в дашборде.

---

### 6. Рекомендуемые клиенты

| Платформа | Клиент | Примечания |
|---|---|---|
| iOS / iPadOS | Shadowrocket | App Store |
| macOS | Shadowrocket / Stash | App Store |
| Android | v2rayNG / NekoBox | Google Play / F-Droid |
| Windows | v2rayN / NekoRay | GitHub |
| Linux | sing-box / xray | CLI |

---

### 7. Emergency Orbit — экстренная смена ключей

Если замечаете замедление или блокировку:

1. Откройте дашборд → кнопка **"🚀 EMERGENCY ORBIT"**
2. Дождитесь смены (5-10 секунд)
3. В Shadowrocket: удалите старый сервер, заново отсканируйте QR или скопируйте новую ссылку

**Автоматическая ротация** происходит каждые 24 часа без разрыва соединений.

---

### 8. DPI Monitor — расшифровка метрик

| Диапазон Score | Статус | Действие |
|---|---|---|
| 0–25 | Чисто | Ничего не требуется |
| 26–50 | Слабое вмешательство | Включить фрагментацию |
| 51–75 | Умеренная блокировка | Emergency Orbit |
| 76–100 | Сильная блокировка | Orbit + смена порта |

---

### 9. Безопасность

- Веб-интерфейс защищён паролем (HTTP Basic Auth)
- Xray работает в hardened Docker-контейнере без лишних привилегий
- Private Key хранится только в `.env` на сервере
- Ротация ShortID предотвращает fingerprinting подключений

---

*Eclips VPN · Powered by Xray-core + VLESS+Reality*
