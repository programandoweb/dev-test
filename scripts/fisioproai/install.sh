#!/usr/bin/env bash
# FisioProAI bootstrap - Jorge Méndez / Programandoweb
set -Eeuo pipefail
DOMAIN=fisioproai.pereira.expert
ROOT=/var/www/$DOMAIN
REPO=git@github-fisioproai:programandoweb/FisioProAI.git
KEY=/root/.ssh/fisioproai_deploy_ed25519
CONF=/etc/apache2/sites-available/$DOMAIN.conf
export DEBIAN_FRONTEND=noninteractive
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || die "Ejecutar con sudo."
command -v apt-get >/dev/null || die "Requiere Ubuntu/Debian."
mkdir -p "$ROOT" /root/.ssh
chmod 700 /root/.ssh
say "Preparando dependencias del host"
apt-get update
apt-get install -y git curl ca-certificates openssh-client apache2 libapache2-mod-fcgid php8.4-cli php8.4-fpm php8.4-mysql php8.4-mbstring php8.4-xml php8.4-curl php8.4-zip php8.4-gd php8.4-bcmath php8.4-intl php8.4-redis iproute2 unzip mariadb-server redis-server supervisor composer openssl python3
command -v docker >/dev/null || die "Docker no está instalado. Instalar Docker Engine + Compose v2 antes de continuar."
docker compose version >/dev/null || die "Falta docker compose v2."
systemctl enable --now apache2 php8.4-fpm mariadb redis-server supervisor docker
# No asignar puertos usados por Apache, Docker o procesos.
freeport(){ local p; for p in $(seq 8100 8999); do if ! ss -H -ltn | awk '{print $4}' | grep -Eq "[:.]$p$" && ! grep -RqsE "Listen[[:space:]]+$p([[:space:]]|$)" /etc/apache2/ports.conf /etc/apache2/sites-enabled && ! grep -RqsE ":[[:space:]]*$p:" /var/www/*/infrastructure/docker-compose.yml 2>/dev/null; then echo "$p"; return; fi; done; return 1; }
if [ -f "/etc/fisioproai-ports.env" ]; then
  source /etc/fisioproai-ports.env
else
  APACHE_PORT=$(freeport) || die "Sin puerto Apache libre."
  FRONTEND_PORT=3100
  while ss -H -ltn | grep -Eq ":$FRONTEND_PORT$"; do FRONTEND_PORT=$((FRONTEND_PORT+1)); done
  AGENT_PORT=$((FRONTEND_PORT+1))
  while ss -H -ltn | grep -Eq ":$AGENT_PORT$"; do AGENT_PORT=$((AGENT_PORT+1)); done
  printf 'APACHE_PORT=%q\nFRONTEND_PORT=%q\nAGENT_PORT=%q\n' "$APACHE_PORT" "$FRONTEND_PORT" "$AGENT_PORT" > /etc/fisioproai-ports.env
  chmod 600 /etc/fisioproai-ports.env
fi
say "Revisando VirtualHost de $DOMAIN en puerto $APACHE_PORT"
mkdir -p /var/log/apache2 "$ROOT/backend/public"
if ! grep -qE "^[[:space:]]*Listen[[:space:]]+$APACHE_PORT([[:space:]]|$)" /etc/apache2/ports.conf; then
  echo "Listen $APACHE_PORT" >> /etc/apache2/ports.conf
fi
# Conservar configuración existente si corresponde a este dominio, puerto y document root.
REWRITE_VHOST=0
if [ ! -f "$CONF" ]; then
  REWRITE_VHOST=1
else
  if ! grep -Fq "ServerName $DOMAIN" "$CONF" || ! grep -Fq "<VirtualHost *:$APACHE_PORT>" "$CONF" || ! grep -Fq "DocumentRoot $ROOT/backend/public" "$CONF"; then
    REWRITE_VHOST=1
  fi
  if grep -Fq '\\$\\{APACHE_LOG_DIR\\}' "$CONF" || grep -Fq '/etc/apache2/$' "$CONF"; then
    REWRITE_VHOST=1
  fi
  if ! grep -Fq 'ErrorLog /var/log/apache2/fisioproai-error.log' "$CONF"; then
    REWRITE_VHOST=1
  fi
fi
if [ "$REWRITE_VHOST" -eq 1 ]; then
  if [ -f "$CONF" ]; then
    cp -a "$CONF" "$CONF.backup.$(date +%Y%m%d-%H%M%S)"
    say "Respaldo del VirtualHost existente creado"
  fi
  cat > "$CONF" <<EOF
<VirtualHost *:$APACHE_PORT>
 ServerName $DOMAIN
 DocumentRoot $ROOT/backend/public
 <Directory $ROOT/backend/public>
  AllowOverride All
  Options FollowSymLinks
  Require all granted
 </Directory>
 <FilesMatch \\.php$>
  SetHandler "proxy:unix:/run/php/php8.4-fpm.sock|fcgi://localhost/"
 </FilesMatch>
 ErrorLog /var/log/apache2/fisioproai-error.log
 CustomLog /var/log/apache2/fisioproai-access.log combined
</VirtualHost>
EOF
else
  say "VirtualHost existente válido; se conserva"
fi
a2enmod rewrite proxy proxy_fcgi setenvif >/dev/null
a2ensite "$DOMAIN.conf" >/dev/null
apache2ctl configtest || die "Configuración Apache inválida"
systemctl reload apache2
say "Configurando identidad SSH exclusiva"
if [ ! -f "$KEY" ]; then ssh-keygen -t ed25519 -N '' -f "$KEY" -C "fisioproai-vps" >/dev/null; fi
chmod 600 "$KEY"
ssh-keyscan -t ed25519 github.com 2>/dev/null > /root/.ssh/fisioproai_known_hosts
# GitHub ED25519 host fingerprint must be verified against GitHub documentation.
EXPECTED="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
ACTUAL=$(ssh-keygen -lf /root/.ssh/fisioproai_known_hosts -E sha256 | awk 'NR==1 {print $2}')
[ "$ACTUAL" = "$EXPECTED" ] || die "La identidad SSH de github.com no coincide."
if ! grep -q '^Host github-fisioproai$' /root/.ssh/config 2>/dev/null; then
cat >> /root/.ssh/config <<EOF

Host github-fisioproai
 HostName github.com
 User git
 IdentityFile $KEY
 IdentitiesOnly yes
 UserKnownHostsFile /root/.ssh/fisioproai_known_hosts
 StrictHostKeyChecking yes
EOF
fi
chmod 600 /root/.ssh/config
echo
echo "=== COPIA SOLO ESTA CLAVE PUBLICA A GITHUB DEPLOY KEYS ==="
cat "$KEY.pub"
echo "https://github.com/programandoweb/FisioProAI/settings/keys"
echo "Add deploy key -> SIN Allow write access"
read -r -p "Pulsa ENTER después de registrarla... " _
say "Verificando llave y clonando"
GIT_SSH_COMMAND="ssh -F /root/.ssh/config" git ls-remote "$REPO" HEAD >/dev/null || die "La llave aún no tiene acceso al repositorio."
if [ -d "$ROOT/.git" ]; then
  git -C "$ROOT" pull --ff-only
elif [ -z "$(ls -A "$ROOT")" ]; then
  git clone --branch main "$REPO" "$ROOT"
else
  die "$ROOT no está vacío y no contiene .git; se preservaron los archivos."
fi
cd "$ROOT"
say "Preparando env y base de datos"
cp -n backend/.env.example backend/.env
cp -n agent/.env.example agent/.env
[ -f frontend/.env ] || touch frontend/.env
cp -n infrastructure/.env.example infrastructure/.env
chmod 600 backend/.env agent/.env frontend/.env infrastructure/.env
# Edición preservando valores existentes; variables secretas solo en archivos, no en argumentos de consola.
setenv(){ local file="$1" key="$2" val="$3"; FILE="$file" FIELD="$key" VALUE="$val" python3 - <<'PY'
import os
from pathlib import Path
p=Path(os.environ['FILE']); k=os.environ['FIELD']; v=os.environ['VALUE']
lines=p.read_text().splitlines()
preserve={'DB_PASSWORD','INTERNAL_API_SECRET','SOCKET_JWT_SECRET','WHATSAPP_CREDS_KEY'}
if k in preserve and any(line.startswith(k+'=') and line[len(k)+1:].strip() not in ('','null','cambiar-por-secreto-largo-aleatorio') for line in lines):
    raise SystemExit
lines=[line for line in lines if not line.startswith(k+'=')]
lines.append(k+'='+v)
p.write_text('\n'.join(lines)+'\n')
PY
}
if ! grep -q '^DB_PASSWORD=.' backend/.env; then
  DBPASS=$(openssl rand -hex 24)
  mysql -e "CREATE DATABASE IF NOT EXISTS fisioproai CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS 'fisioproai'@'127.0.0.1' IDENTIFIED BY '$DBPASS';"
  mysql -e "ALTER USER 'fisioproai'@'127.0.0.1' IDENTIFIED BY '$DBPASS';"
  mysql -e "GRANT ALL PRIVILEGES ON fisioproai.* TO 'fisioproai'@'127.0.0.1'; FLUSH PRIVILEGES;"
  setenv backend/.env DB_PASSWORD "$DBPASS"
fi
setenv backend/.env APP_URL "https://$DOMAIN"
setenv backend/.env FRONTEND_URL "https://$DOMAIN"
setenv backend/.env SANCTUM_STATEFUL_DOMAINS "$DOMAIN"
setenv backend/.env CORS_ALLOWED_ORIGINS "https://$DOMAIN"
setenv backend/.env MAIL_FROM_ADDRESS "no-reply@$DOMAIN"
setenv backend/.env AGENT_URL "http://127.0.0.1:$AGENT_PORT"
setenv backend/.env CLINICAL_DISK_ROOT /var/lib/fisioproai/clinical
SECRET=$(openssl rand -hex 32)
setenv backend/.env INTERNAL_API_SECRET "$SECRET"
SECRET=$(grep '^INTERNAL_API_SECRET=' backend/.env | cut -d= -f2-)
setenv agent/.env INTERNAL_API_SECRET "$SECRET"
JWT=$(openssl rand -hex 32)
setenv backend/.env SOCKET_JWT_SECRET "$JWT"
JWT=$(grep '^SOCKET_JWT_SECRET=' backend/.env | cut -d= -f2-)
setenv agent/.env SOCKET_JWT_SECRET "$JWT"
setenv agent/.env WHATSAPP_CREDS_KEY "$(openssl rand -base64 32)"
setenv agent/.env CORS_ORIGINS "https://$DOMAIN"
setenv agent/.env LARAVEL_INTERNAL_URL "http://host.docker.internal:$APACHE_PORT/api/internal/v1"
setenv frontend/.env NEXT_PUBLIC_API_URL "https://$DOMAIN/api/v1"
setenv frontend/.env API_INTERNAL_URL "http://host.docker.internal:$APACHE_PORT"
setenv infrastructure/.env FRONTEND_PORT "$FRONTEND_PORT"
setenv infrastructure/.env AGENT_PORT "$AGENT_PORT"
mkdir -p /var/lib/fisioproai/clinical backend/storage/framework/{cache,sessions,views} backend/bootstrap/cache
chown -R www-data:www-data /var/lib/fisioproai backend/storage backend/bootstrap/cache
chmod 750 /var/lib/fisioproai/clinical
# Redis aislado en 6381: no alterar Redis global utilizado por otros proyectos.
REDIS_HOST_IP=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
[ -n "$REDIS_HOST_IP" ] || die "Docker no tiene gateway bridge."
REDIS_PASS_FILE=/etc/fisioproai-redis.password
if [ ! -f "$REDIS_PASS_FILE" ]; then openssl rand -hex 32 > "$REDIS_PASS_FILE"; chmod 600 "$REDIS_PASS_FILE"; fi
REDIS_PASS=$(cat "$REDIS_PASS_FILE")
mkdir -p /var/lib/fisioproai/redis
cat > /etc/fisioproai-redis.conf <<EOF
bind 127.0.0.1 $REDIS_HOST_IP
port 6381
protected-mode yes
requirepass $REDIS_PASS
dir /var/lib/fisioproai/redis
appendonly yes
daemonize no
loglevel notice
EOF
cat > /etc/systemd/system/fisioproai-redis.service <<EOF
[Unit]
Description=FisioProAI isolated Redis
After=network.target docker.service
Requires=docker.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/redis-server /etc/fisioproai-redis.conf
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now fisioproai-redis
systemctl restart fisioproai-redis
REDISCLI_AUTH="$REDIS_PASS" redis-cli -p 6381 ping | grep -qx PONG || die "Redis FisioProAI no responde."
setenv backend/.env REDIS_PORT 6381
setenv backend/.env REDIS_PASSWORD "$REDIS_PASS"
setenv agent/.env REDIS_URL "redis://:$REDIS_PASS@host.docker.internal:6381"
# Redis se escucha solo en loopback y gateway Docker (no en IP pública).
say "Desplegando Laravel y contenedores"
cd backend
composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
if ! grep -q '^APP_KEY=base64:' .env; then php artisan key:generate --force; fi
php artisan migrate --force
php artisan db:seed --class=ProductionSeeder --force
php artisan config:cache
php artisan route:cache
php artisan view:cache
cd ..
docker compose -f infrastructure/docker-compose.yml --env-file infrastructure/.env up -d --build
apache2ctl configtest
curl -fsS "http://127.0.0.1:$APACHE_PORT/api/v1/health" || echo "Aviso: revisar endpoint de salud Laravel"
docker compose -f infrastructure/docker-compose.yml ps
echo
echo "APACHE: 127.0.0.1:$APACHE_PORT"
echo "FRONTEND: 127.0.0.1:$FRONTEND_PORT"
echo "AGENT: 127.0.0.1:$AGENT_PORT"
echo "Proyecto: $ROOT"
echo "Configurar 3 rutas/upstreams en Nginx Proxy Manager. No publicar puertos sensibles."
