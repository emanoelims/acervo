# Screenshot service

Acervo takes a screenshot of a page when it has no preview image, or when the
user asks for a new one. The browser runs on a [Fly Sprite](https://docs.fly.io/sprites/),
not on the app's machine: Chromium needs far more memory than the 1 GB the app
has, and the Sprite pauses when idle, so it costs nothing between captures.

`server.mjs` is a small Node service around Playwright's Chromium:

- `POST /shot` with `{"url": "https://…"}` and `Authorization: Bearer <token>`
  answers a 1200×750 JPEG of the page's first screen.
- Errors are JSON: `401` bad token, `400` bad URL, `422` the page failed or
  answered 4xx/5xx, `503` too many captures waiting.
- One page renders at a time. Consent banners are hidden before the capture.
- Every request the page makes is checked: hosts that are, or resolve to,
  loopback or private addresses are blocked. The Sprite's network policy also
  blocks private ranges on the way out.

## Setup

The Sprite's URL is public; the service's own token is the only credential, so
a leaked token can only ask for screenshots. Acervo reads the URL and token
from `ACERVO_SHOTS_URL` and `ACERVO_SHOTS_TOKEN`.

```bash
sprite create acervo-shots
sprite exec -s acervo-shots \
  --file infra/screenshots/server.mjs:/home/sprite/shots/server.mjs \
  --file infra/screenshots/package.json:/home/sprite/shots/package.json \
  --file infra/screenshots/setup.sh:/home/sprite/shots/setup.sh \
  -- bash /home/sprite/shots/setup.sh

# Enforce a network policy: private addresses are always blocked under one.
sprite api /v1/sprites/acervo-shots/policy/network -- -X POST \
  -H 'content-type: application/json' -d '{"rules":[{"domain":"*","action":"allow"}]}'

# The service, started on demand by requests to the Sprite's URL.
sprite exec -s acervo-shots -- sprite-env services create shots \
  --cmd /.sprite/bin/node --args /home/sprite/shots/server.mjs --dir /home/sprite/shots \
  --env "PORT=8080,SHOT_TOKEN=<token>,PLAYWRIGHT_BROWSERS_PATH=/home/sprite/.cache/ms-playwright" \
  --http-port 8080

sprite config update -s acervo-shots --url-auth public
sprite info -s acervo-shots   # prints the URL
```

Generate the token with `openssl rand -hex 32` and set the same value as a Fly
secret on the app.

## Updating

Upload the new `server.mjs` and restart the service:

```bash
sprite exec -s acervo-shots \
  --file infra/screenshots/server.mjs:/home/sprite/shots/server.mjs \
  -- sprite-env services restart shots
```

Logs are at `/.sprite/logs/services/shots.log` inside the Sprite.
