# work-hammer

Forti, Cisco и L2TP плюс обход блокировок за одним прокси `127.0.0.1:1080`, который ставится системным прокси Windows. Домены туннеля резолвятся его DNS и уходят в туннель, если адрес внутренний. Заблокированное идёт через VLESS, остальное напрямую.

## Каждый день

- `morning.bat` — перезапуск всего с нуля, push для Forti и Cisco
- `stop.bat` — выключить всё и вернуть прежний системный прокси
- http://localhost:3456 — статус, перезапуск и остановка по отдельности

Telegram: SOCKS5 `127.0.0.1:1080`.

## Первый раз

1. В корне: `opm install -l --dev`; в WSL (Ubuntu): `bash wsl/setup.sh`
2. Docker Desktop → Settings: General → Start when you sign in; Resources → Proxies → Manual, поля пустые
3. `forti`, `cisco`, `l2tp`, `proxy`: `.env.example` → `.env`
4. `cisco/certs/client.p12`

## .env

| Ключ | |
|--|--|
| `DOMAINS` | домены туннеля |
| `NETS` | подсети туннеля сверх тех, что выдал шлюз |
| `VLESS` | ссылки `vless://` через пробел |
| `BYPASS_DOMAINS`, `BYPASS_NETS` | что пускать через VLESS |
