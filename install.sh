#!/bin/bash
# ============================================================
#  BEARWSL — Instalador interactivo del stack de desarrollo
#  (simil a Bearsampp pero para WSL2/Linux)
#
#  COMANDO AUTOCONTENIDO: verifica el entorno, instala paquetes
#  y CREA los archivos del stack (panel.sh, vhost.sh, scripts/,
#  webpanel/, docker-compose.yml, docker/roadrunner/) en
#  $BEARWSL_DIR a partir de plantillas embebidas. Idempotente:
#  solo escribe cuando faltan o difieren de la plantilla.
#
#  Pregunta qué instalar y CÓMO ejecutar los servicios:
#    · Dockerizado (contenedores multi-versión)
#    · Nativo (apt + systemd, sin contenedores)
#    · Híbrido (pregunta por familia: PHP / MariaDB / Postgres)
#
#  Resuelve incidencias comunes, instala extensiones PHP y deja
#  el stack listo: nginx, Node (fnm), Redis, Mailpit, RoadRunner
#  y el panel web de administración.
#
#  FLAGS:
#    --dry-run           muestra el plan sin ejecutar cambios
#    --yes               acepta los valores por defecto
#    --no-start          instala la configuración SIN levantar servicios
#    --mode=MODELO       container | native | hybrid (omite la pregunta)
#    --sync-files        solo (re)genera los archivos del stack y sale
# ============================================================
set -uo pipefail

DRY_RUN=0; YES=0; NO_START=0; MODE_CHOICE=""; SYNC_FILES=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --yes) YES=1 ;;
        --no-start) NO_START=1 ;;
        --sync-files) SYNC_FILES=1 ;;
        --mode=*) MODE_CHOICE="${a#--mode=}" ;;
        *) echo "Flag desconocido: $a (--dry-run | --yes | --no-start | --sync-files | --mode=container|native|hybrid)"; exit 2 ;;
    esac
done

BEARWSL_DIR="${BEARWSL_DIR:-$HOME/bearwsl}"
ENV_FILE="${BEARWSL_DIR}/.env"
WWW_DIR="/var/www"
DATA_DIR="/var/lib/bearwsl"
CONFIG_DIR="$HOME/.config/bearwsl"
RR_VERSION="2025.1.15"

mkdir -p "$BEARWSL_DIR"

GREEN=$'\e[32m'; RED=$'\e[31m'; BLUE=$'\e[34m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
info() { printf "${BLUE}ℹ${RESET}  %s\n" "$*"; }
ok()   { printf "${GREEN}✔${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
fail() { printf "${RED}✘${RESET}  %s\n" "$*"; }
hr()   { printf -- '=========================================================\n'; }

# ejecutar (respeta --dry-run); sudo implícito si hace falta
run() { # run [--sudo] cmd...
    local use_sudo=0; [ "${1:-}" = "--sudo" ] && { use_sudo=1; shift; }
    if [ "$DRY_RUN" = "1" ]; then
        printf "${YELLOW}[dry-run]${RESET} "
        [ "$use_sudo" = "1" ] && printf 'sudo '
        printf '%s\n' "$*"
        return 0
    fi
    if [ "$use_sudo" = "1" ]; then
        if [ "$(id -u)" -eq 0 ]; then "$@"
        else
            sudo -n true 2>/dev/null || sudo -v
            sudo "$@"
        fi
    else
        "$@"
    fi
}

# Credenciales sudo de una vez (durante las elecciones); evita cortes a mitad.
ensure_sudo() {
    [ "$DRY_RUN" = "1" ] && return 0
    [ "$SYNC_FILES" = "1" ] && return 0
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || { fail "No hay sudo y no eres root. Aborta."; exit 1; }
    if ! sudo -n true 2>/dev/null; then
        echo
        info "La instalación necesita permisos de administrador (sudo)."
        echo "      Introduce tu contraseña cuando se pida (una sola vez)."
        if ! sudo -v; then
            fail "Credenciales incorrectas o canceladas. Aborta."
            exit 1
        fi
    fi
    ok "Acceso sudo verificado."
}

# Reintenta un comando hasta N veces (a prueba de fallos).
retry() { # retry N cmd...
    local n="$1" i=0; shift
    until "$@"; do
        i=$((i+1))
        [ "$i" -ge "$n" ] && return 1
        warn "Fallo en: $* — reintentando ($i/$n)…"
        sleep 2
    done
    return 0
}

# ============================================================
#  0) GENERACIÓN DE ARCHIVOS DEL STACK (autocontenido, idempotente)
#     install.sh es el comando canónico: materializa los archivos del
#     stack en $BEARWSL_DIR solo si faltan o difieren de la plantilla.
#     Las plantillas van embebidas abajo, una heredoc por archivo
#     (edítalas AQUÍ — son la fuente de verdad — y regenera el repo
#     con: ./install.sh --sync-files).
# ============================================================
GEN_ERR=0
render_file() { # render_file <ruta-rel> <modo>  ← contenido por stdin
    local rel="$1" mode="$2" target="$BEARWSL_DIR/$1" tmp
    if [ "$DRY_RUN" = "1" ]; then
        printf '%s[dry-run]%s generaría/verificaría: %s\n' "$YELLOW" "$RESET" "$target"
        return 0
    fi
    mkdir -p "$(dirname "$target")"
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        # contenido idéntico: asegura también el modo de ejecución pedido
        if [ "$mode" = "755" ] && [ ! -x "$target" ]; then
            chmod +x "$target" && ok "permisos corregidos (+x): $rel"
        else
            ok "verificado (idéntico): $rel"
        fi
        rm -f "$tmp"; return 0
    fi
    if install -m "$mode" "$tmp" "$target" 2>/dev/null; then
        ok "generado/actualizado: $rel"
    else
        fail "error al escribir $rel"; GEN_ERR=1
    fi
    rm -f "$tmp"
}

gen_stack_files() {
    GEN_ERR=0
    info "Archivos del stack en $BEARWSL_DIR…"

    render_file "scripts/helpers.sh" 644 <<'_BEOF_HELPERS'
#!/bin/bash
# ============================================================
#  BEARWSL — Funciones y variables compartidas del stack
#  Uso: source "$HOME/bearwsl/scripts/helpers.sh"
#
#  Cada familia de servicios (php, db, pg) puede ejecutarse en
#  modo "container" (docker compose) o "native" (systemd en WSL).
#  El modo se guarda en .env: PHP_MODE, DB_MODE, PG_MODE.
# ============================================================

BEARWSL_DIR="${BEARWSL_DIR:-$HOME/bearwsl}"
ENV_FILE="${BEARWSL_DIR}/.env"
WWW_DIR="${WWW_DIR:-/var/www}"

# Mapa de puertos por servicio (coincide con docker-compose.yml y con los pools nativos)
declare -A SERVICE_PORT=(
  [php74]="9002" [php84]="9001" [php85]="9000"
  [mariadb10]="3307" [mariadb11]="3306"
  [postgres15]="5433" [postgres17]="5432"
  [redis]="6379" [mailpit]="8025" [roadrunner]="8080"
)

# Etiquetas legibles
declare -A SERVICE_VERSION=(
  [php74]="PHP 7.4" [php84]="PHP 8.4" [php85]="PHP 8.5"
  [mariadb10]="MariaDB 10.11" [mariadb11]="MariaDB 11.4"
  [postgres15]="PostgreSQL 15" [postgres17]="PostgreSQL 17"
  [redis]="Redis 7" [mailpit]="Mailpit" [roadrunner]="RoadRunner 2025.1.15"
)

# Servicio nativo (systemd) equivalente a cada servicio dockerizado
declare -A NATIVE_SERVICE=(
  [php74]="php7.4-fpm" [php84]="php8.4-fpm" [php85]="php8.5-fpm"
  [mariadb10]="mariadb" [mariadb11]="mariadb"
  [postgres15]="postgresql@15-main" [postgres17]="postgresql@17-main"
)

# Familias de servicios (solo una versión activa por familia)
PHP_FAMILY=(php74 php84 php85)
DB_FAMILY=(mariadb10 mariadb11)
PG_FAMILY=(postgres15 postgres17)

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        PHP_CURRENT="php85"; DB_CURRENT="mariadb11"; PG_CURRENT="postgres17"; NODE_CURRENT="22"
        PHP_MODE="container"; DB_MODE="container"; PG_MODE="container"
        save_env
        return
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"
}

save_env() {
    umask 077
    {
        echo "PHP_CURRENT=${PHP_CURRENT:-php85}"
        echo "DB_CURRENT=${DB_CURRENT:-mariadb11}"
        echo "PG_CURRENT=${PG_CURRENT:-postgres17}"
        echo "NODE_CURRENT=${NODE_CURRENT:-22}"
        echo "PHP_MODE=${PHP_MODE:-container}"
        echo "DB_MODE=${DB_MODE:-container}"
        echo "PG_MODE=${PG_MODE:-container}"
    } > "$ENV_FILE"
}

# docker compose desde el directorio del stack
compose() { ( cd "$BEARWSL_DIR" && docker compose "$@" ); }

compose_ps() { compose ps -a --format '{{.Service}}\t{{.Status}}' 2>/dev/null; }

# ¿Está corriendo el contenedor? (Up, healthy, starting)
is_service_running() {
    local name="$1"
    compose_ps | awk -F'\t' -v s="$name" '$1==s && $2 ~ /^(Up|running|healthy|starting)/ {found=1} END {exit !found}'
}

port_of() { echo "${SERVICE_PORT[$1]:-}"; }
version_of() { echo "${SERVICE_VERSION[$1]:-$1}"; }

# ------------------------------------------------------------
#  Modos: container | native
# ------------------------------------------------------------
family_of() {
    case "$1" in
        php74|php84|php85) echo php ;;
        mariadb10|mariadb11) echo db ;;
        postgres15|postgres17) echo pg ;;
        *) echo util ;;
    esac
}

family_mode() { # php|db|pg → container|native
    case "$1" in
        php) echo "${PHP_MODE:-container}" ;;
        db)  echo "${DB_MODE:-container}" ;;
        pg)  echo "${PG_MODE:-container}" ;;
    esac
}

svc_mode() { # nombre de servicio → container|native
    local f; f=$(family_of "$1")
    [ "$f" = "util" ] && { echo container; return; }
    family_mode "$f"
}

native_service_of() { echo "${NATIVE_SERVICE[$1]:-}"; }

# ¿Está corriendo? (respeta el modo del servicio)
is_svc_running() {
    local mode; mode=$(svc_mode "$1")
    if [ "$mode" = "native" ]; then
        systemctl is-active --quiet "$(native_service_of "$1")" 2>/dev/null
    else
        is_service_running "$1"
    fi
}

# Arranca según el modo (docker o systemd)
svc_start() {
    local mode; mode=$(svc_mode "$1")
    if [ "$mode" = "native" ]; then
        local ns; ns=$(native_service_of "$1")
        systemctl start "$ns" 2>/dev/null || sudo systemctl start "$ns" 2>/dev/null \
            || { printf '⚠ No se pudo iniciar el servicio nativo %s\n' "$ns" >&2; return 1; }
    else
        if ! compose up -d "$1" >/dev/null 2>&1; then
            printf '⚠ No se pudo levantar el contenedor %s (docker)\n' "$1" >&2
            return 1
        fi
    fi
    return 0
}

# Detiene según el modo (docker o systemd)
svc_stop() {
    local mode; mode=$(svc_mode "$1")
    if [ "$mode" = "native" ]; then
        local ns; ns=$(native_service_of "$1")
        systemctl stop "$ns" 2>/dev/null || sudo systemctl stop "$ns" 2>/dev/null || true
    else
        compose stop "$1" >/dev/null 2>&1
    fi
}

# Levanta las versiones actuales (respeta modos) + redis/mailpit (docker)
start_current_stack() {
    svc_start "$PHP_CURRENT"; svc_start "$DB_CURRENT"; svc_start "$PG_CURRENT"
    compose up -d redis mailpit >/dev/null 2>&1 || true
}

stop_current_stack() {
    svc_stop "$PHP_CURRENT"; svc_stop "$DB_CURRENT"; svc_stop "$PG_CURRENT"
    compose stop redis mailpit >/dev/null 2>&1 || true
}

restart_current_stack() { stop_current_stack; start_current_stack; }

# Puertos de los servicios actuales (desde .env)
php_current_port() { port_of "${PHP_CURRENT:-php85}"; }
db_current_port()  { port_of "${DB_CURRENT:-mariadb11}"; }
pg_current_port()  { port_of "${PG_CURRENT:-postgres17}"; }

# IP de la máquina (en WSL se usa para mapear los dominios en el hosts de Windows)
wsl_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

# ¿Estamos en WSL? (los dominios .test se mapean en Windows; en Linux nativo en /etc/hosts)
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
_BEOF_HELPERS
    render_file "scripts/autostart.sh" 755 <<'_BEOF_AUTOSTART'
#!/bin/bash
# BEARWSL — Autostart: levanta las versiones actuales del stack (respeta modos docker/nativo)
# shellcheck source=scripts/helpers.sh
source "$HOME/bearwsl/scripts/helpers.sh"
load_env

# Espera a que el daemon de Docker esté listo en arranque frío (hasta 60s)
_i=0
while [ "$_i" -lt 30 ]; do
    if docker info >/dev/null 2>&1; then break; fi
    sleep 2
    _i=$((_i+1))
done

start_current_stack
_BEOF_AUTOSTART
    render_file "panel.sh" 755 <<'_BEOF_PANEL'
#!/bin/bash
# ============================================================
#  BEARWSL — Panel de control del stack (simil Bearsampp)
#
#  USO:
#    panel.sh                       → menú interactivo
#    panel.sh --status              → estado de todos los servicios
#    panel.sh --up | --down | --restart
#    panel.sh --logs [servicio] [líneas]
#    panel.sh --health              → health check del stack
#    panel.sh --panel start|stop|status|token
#    panel.sh --env                 → versiones actuales
#    panel.sh --switch php|db|pg <version>
# ============================================================
set -uo pipefail

BEARWSL_DIR="${BEARWSL_DIR:-$HOME/bearwsl}"
# shellcheck source=scripts/helpers.sh
if ! source "$BEARWSL_DIR/scripts/helpers.sh" 2>/dev/null; then
    echo "⚠ No encuentro $BEARWSL_DIR/scripts/helpers.sh" >&2; exit 1
fi
load_env

GREEN=$'\e[32m'; RED=$'\e[31m'; BLUE=$'\e[34m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
TICK="${GREEN}✔${RESET}"; CROSS="${RED}✘${RESET}"

hr() { printf -- '=========================================================\n'; }
sep() { printf -- '---------------------------------------------------------\n'; }

# Estado de un servicio → ⬆ verde / ⬇ rojo
svc_icon() {
    if is_svc_running "$1"; then printf '%s' "${GREEN}⬆${RESET}"; else printf '%s' "${RED}⬇${RESET}"; fi
}

# ============================================================
#  COMANDOS CLI
# ============================================================
cmd_status() {
    hr
    printf '%s\n' "   🟢  BEARWSL — ESTADO DEL STACK  (${BOLD}$(hostname)${RESET} · $(wsl_ip))"
    hr
    printf '  %-12s %-14s %-8s %-6s %s\n' "SERVICIO" "VERSIÓN" "PUERTO" "ESTADO" "SALUD"
    sep
    local svc
    for svc in "${PHP_FAMILY[@]}" "${DB_FAMILY[@]}" "${PG_FAMILY[@]}" redis mailpit roadrunner; do
        local st health=""
        st=$(compose_ps | awk -F'\t' -v s="$svc" '$1==s {print $2}')
        case "$st" in
            *healthy*) health="${GREEN}healthy${RESET}" ;;
            *unhealthy*) health="${RED}unhealthy${RESET}" ;;
            *Up*) health="${YELLOW}arrancando${RESET}" ;;
            *) health="—" ;;
        esac
        if [ -n "$st" ] && echo "$st" | grep -qE '^(Up|running|healthy)'; then
            printf '  %-12s %-14s %-8s %-6s %s\n' "$svc" "$(version_of "$svc")" "$(port_of "$svc")" "${GREEN}⬆${RESET}" "$health"
        else
            printf '  %-12s %-14s %-8s %-6s %s\n' "$svc" "$(version_of "$svc")" "$(port_of "$svc")" "${RED}⬇${RESET}" "—"
        fi
    done
    sep
    printf '  Actuales → PHP: %s (%s)   MariaDB: %s (%s)   Postgres: %s (%s)   Node: %s\n' \
        "${GREEN}${PHP_CURRENT}${RESET}" "$PHP_MODE" "${GREEN}${DB_CURRENT}${RESET}" "$DB_MODE" \
        "${GREEN}${PG_CURRENT}${RESET}" "$PG_MODE" "${GREEN}${NODE_CURRENT}${RESET}"
    hr
}

cmd_logs() {
    local svc="${1:-$PHP_CURRENT}" lines="${2:-120}"
    compose logs --tail="$lines" -f "$svc"
}

cmd_health() {
    hr; printf '%s\n' "   🩺  HEALTH CHECK"
    hr
    # Docker daemon
    if docker info >/dev/null 2>&1; then printf '  %s Docker daemon accesible\n' "$TICK"; else printf '  %s Docker daemon NO accesible\n' "$CROSS"; fi
    # nginx
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then printf '  %s nginx: configuración válida\n' "$TICK"; else printf '  %s nginx: configuración inválida\n' "$CROSS"; fi
    else printf '  %s nginx no instalado\n' "$CROSS"; fi
    # Servicios con salud
    local svc
    for svc in "${PHP_FAMILY[@]}" "${DB_FAMILY[@]}" "${PG_FAMILY[@]}" redis mailpit roadrunner; do
        local st; st=$(compose_ps | awk -F'\t' -v s="$svc" '$1==s {print $2}')
        case "$st" in
            *healthy*) printf '  %s %-12s healthy\n' "$TICK" "$svc" ;;
            *Up*) printf '  %s %-12s up (sin healthcheck aún)\n' "$YELLOW" "$svc" ;;
            *) printf '  %s %-12s detenido\n' "$CROSS" "$svc" ;;
        esac
    done
    hr
}

cmd_panel() {
    local action="${1:-status}"
    case "$action" in
        start)
            local ok_systemd=1
            if command -v systemctl >/dev/null 2>&1; then
                sudo -n systemctl start bearwsl-panel 2>/dev/null || sudo systemctl start bearwsl-panel 2>/dev/null || ok_systemd=0
            else
                ok_systemd=0
            fi
            if [ "$ok_systemd" = "0" ]; then
                printf '%s systemd no disponible/falló; arrancando el panel manualmente (php -S)…\n' "$YELLOW"
                nohup php -S 0.0.0.0:8088 -t "$BEARWSL_DIR/webpanel" "$BEARWSL_DIR/webpanel/router.php" >/dev/null 2>&1 &
                sleep 1
            fi
            cmd_panel status ;;
        stop)
            if command -v systemctl >/dev/null 2>&1; then
                sudo -n systemctl stop bearwsl-panel 2>/dev/null || sudo systemctl stop bearwsl-panel 2>/dev/null
            fi
            pkill -f 'php -S 0.0.0.0:8088' 2>/dev/null
            printf '%s Panel web detenido\n' "$TICK" ;;
        token)
            local tf="$HOME/.config/bearwsl/panel_token"
            if [ -f "$tf" ]; then printf 'Token del panel: %s\n' "${GREEN}$(cat "$tf")${RESET}"; else printf '%s Aún no existe token (inicia el panel una vez o ejecuta install.sh)\n' "$CROSS"; fi ;;
        status|*)
            if curl -fsS http://127.0.0.1:8088/api/ping >/dev/null 2>&1; then
                printf '%s Panel web: %sCORRIENDO%s → http://127.0.0.1:8088  (o http://panel.bearwsl.test)\n' "$TICK" "$GREEN" "$RESET"
            else
                printf '%s Panel web: detenido (usa: panel.sh --panel start)\n' "$CROSS"
            fi
            ;;
    esac
}

cmd_switch() {
    local family="$1" version="$2" stop_list=()
    case "$family" in
        php) stop_list=("${PHP_FAMILY[@]}"); PHP_CURRENT="$version" ;;
        db)  stop_list=("${DB_FAMILY[@]}");  DB_CURRENT="$version" ;;
        pg)  stop_list=("${PG_FAMILY[@]}");  PG_CURRENT="$version" ;;
        *) printf 'Familia inválida: %s (php|db|pg)\n' "$family"; return 2 ;;
    esac
    local s
    for s in "${stop_list[@]}"; do
        [ "$s" != "$version" ] && svc_stop "$s"
    done
    save_env
    svc_start "$version" || return 1
    printf '%s Ahora %s = %s (modo %s)\n' "$TICK" "$family" "${GREEN}$version${RESET}" "$(svc_mode "$version")"
}

# asegura que sudoers tenga permiso para gestionar servicios nativos (idempotente)
ensure_native_sudoers() {
    sudo -n true 2>/dev/null || return 0
    local line="$USER ALL=(root) NOPASSWD: /usr/bin/systemctl start php7.4-fpm, /usr/bin/systemctl stop php7.4-fpm, /usr/bin/systemctl restart php7.4-fpm, /usr/bin/systemctl start php8.4-fpm, /usr/bin/systemctl stop php8.4-fpm, /usr/bin/systemctl restart php8.4-fpm, /usr/bin/systemctl start php8.5-fpm, /usr/bin/systemctl stop php8.5-fpm, /usr/bin/systemctl restart php8.5-fpm, /usr/bin/systemctl start mariadb, /usr/bin/systemctl stop mariadb, /usr/bin/systemctl restart mariadb, /usr/bin/systemctl start postgresql@15-main, /usr/bin/systemctl stop postgresql@15-main, /usr/bin/systemctl restart postgresql@15-main, /usr/bin/systemctl start postgresql@17-main, /usr/bin/systemctl stop postgresql@17-main, /usr/bin/systemctl restart postgresql@17-main"
    sudo sh -c "umask 077; grep -q 'systemctl start php7.4-fpm' /etc/sudoers.d/bearwsl 2>/dev/null || echo '$line' >> /etc/sudoers.d/bearwsl; chmod 440 /etc/sudoers.d/bearwsl 2>/dev/null"
    sudo sh -c 'visudo -c >/dev/null 2>&1' || printf '%s Revisa /etc/sudoers.d/bearwsl\n' "$CROSS"
}

# migra una familia entre container y native (detiene primero el runtime contrario)
cmd_mode() {
    local family="${1:-}" target="${2:-}" members=() mode_key="" cur=""
    case "$family" in
        php) members=("${PHP_FAMILY[@]}"); mode_key="PHP_MODE"; cur="$PHP_CURRENT" ;;
        db)  members=("${DB_FAMILY[@]}");  mode_key="DB_MODE";  cur="$DB_CURRENT" ;;
        pg)  members=("${PG_FAMILY[@]}");  mode_key="PG_MODE";  cur="$PG_CURRENT" ;;
        *) printf 'Uso: panel.sh --mode php|db|pg container|native\n'; return 2 ;;
    esac
    case "$target" in
        container|native) ;;
        *) printf 'Modo inválido: %s (container|native)\n' "$target"; return 2 ;;
    esac

    # 1) detener TODO lo de la familia (docker + nativo) → evita conflictos de puerto
    local m ns
    for m in "${members[@]}"; do compose stop "$m" >/dev/null 2>&1; done
    for m in "${members[@]}"; do
        ns=$(native_service_of "$m")
        [ -n "$ns" ] && { systemctl stop "$ns" 2>/dev/null || sudo -n systemctl stop "$ns" 2>/dev/null || true; }
    done

    # 2) arrancar el runtime objetivo
    if [ "$target" = "container" ]; then
        if ! command -v docker >/dev/null 2>&1; then
            printf '%s Docker no está instalado. Ejecuta: ./install.sh\n' "$CROSS"; return 1
        fi
        compose up -d "$cur" || { printf '%s No se pudo levantar %s (docker)\n' "$CROSS" "$cur"; return 1; }
    else
        ns=$(native_service_of "$cur")
        if ! systemctl start "$ns" 2>/dev/null && ! sudo -n systemctl start "$ns" 2>/dev/null; then
            printf '%s No se pudo iniciar %s (¿instalado? prueba: ./install.sh con modo nativo)\n' "$CROSS" "$ns"
            return 1
        fi
        ensure_native_sudoers
    fi

    # 3) guardar modo
    eval "${mode_key}=${target}"
    save_env
    printf '%s %s ahora en modo %s (%s activo)\n' "$TICK" "$family" "$target" "$cur"
}

cmd_mode_interactive() {
    echo "Familia: [1] PHP   [2] MariaDB   [3] Postgres"; echo -n "Selecciona [1]: "; read -r f
    case "$f" in 2) f="db" ;; 3) f="pg" ;; *) f="php" ;; esac
    echo "Modo: [1] Docker   [2] Nativo"; echo -n "Selecciona [1]: "; read -r m
    case "$m" in 2) m="native" ;; *) m="container" ;; esac
    cmd_mode "$f" "$m"
}

# ============================================================
#  MENÚ INTERACTIVO
# ============================================================
mostrar_menu() {
    clear
    hr
    printf '              🟢  %sBEARWSL CONTROL PANEL%s  🟢\n' "$BOLD" "$RESET"
    hr
    printf '  [1] PHP Versión      → Actual: %s%s%s\n' "$GREEN" "$PHP_CURRENT" "$RESET"
    printf '  [2] MariaDB Versión  → Actual: %s%s%s\n' "$GREEN" "$DB_CURRENT" "$RESET"
    printf '  [3] Postgres Versión → Actual: %s%s%s\n' "$GREEN" "$PG_CURRENT" "$RESET"
    printf '  [4] Node.js Versión  → Actual: %s%s%s\n' "$GREEN" "$NODE_CURRENT" "$RESET"
    printf '  [M] Modo servicios   → PHP:%s  MariaDB:%s  Postgres:%s  (docker/nativo)\n' "$PHP_MODE" "$DB_MODE" "$PG_MODE"
    sep
    printf '   %s  ESTADO DOCKER\n' "$BLUE"
    printf '     PHP: 74:%s  84:%s  85:%s      RR:%s\n' "$(svc_icon php74)" "$(svc_icon php84)" "$(svc_icon php85)" "$(svc_icon roadrunner)"
    printf '     SQL: M10:%s M11:%s   PGS: G15:%s G17:%s\n' "$(svc_icon mariadb10)" "$(svc_icon mariadb11)" "$(svc_icon postgres15)" "$(svc_icon postgres17)"
    printf '     OTR: RED:%s MLP:%s\n' "$(svc_icon redis)" "$(svc_icon mailpit)"
    sep
    printf '  [5] 🌐 Nuevo Virtual Host     [6] 📋 Listar Virtual Hosts\n'
    printf '  [7] 🌍 Panel Web (start/abrir/token)\n'
    printf '  [8] 📜 Logs de servicio        [9] 🩺 Health check\n'
    printf '  [10] 🔄 Modo servicios (docker/nativo)\n'
    sep
    printf '  [I] INICIAR STACK   [D] DETENER   [R] REINICIAR   [X] Salir\n'
    hr
    if is_wsl; then
        printf '  IP WSL: %s%s%s   (mapea estos dominios en el hosts de Windows)\n' "$YELLOW" "$(wsl_ip)" "$RESET"
    else
        printf '  Hosts: dominios .test registrados en /etc/hosts (127.0.0.1)\n'
    fi
    echo -n "Selecciona una opción: "
}

seleccion_php() {
    echo "1) PHP 7.4 (9002)   2) PHP 8.4 (9001)   3) PHP 8.5 (9000)"
    echo -n "Selecciona [3]: "; read -r v
    case "$v" in 1) cmd_switch php php74 ;; 2) cmd_switch php php84 ;; *) cmd_switch php php85 ;; esac
}
seleccion_db() {
    echo "1) MariaDB 10.11 (3307)   2) MariaDB 11.4 (3306)"
    echo -n "Selecciona [2]: "; read -r v
    case "$v" in 1) cmd_switch db mariadb10 ;; *) cmd_switch db mariadb11 ;; esac
}
seleccion_pg() {
    echo "1) Postgres 15 (5433)   2) Postgres 17 (5432)"
    echo -n "Selecciona [2]: "; read -r v
    case "$v" in 1) cmd_switch pg postgres15 ;; *) cmd_switch pg postgres17 ;; esac
}
seleccion_node() {
    echo -n "Versión de Node a instalar (ej: 20, 22): "; read -r v
    if command -v fnm >/dev/null 2>&1 || [ -x "$HOME/.local/share/fnm/fnm" ]; then
        export PATH="$HOME/.local/share/fnm:$PATH"
        eval "$("$HOME/.local/share/fnm/fnm" env 2>/dev/null)"
        fnm install "$v" 2>/dev/null && fnm default "$v"
        NODE_CURRENT="$v"; save_env
    else
        echo "⚠ fnm no está instalado. Ejecuta: ./install.sh"
    fi
}

# ============================================================
#  DESPACHADOR CLI / MENÚ INTERACTIVO
# ============================================================
case "${1:-}" in
    --status)   cmd_status ;;
    --up)       start_current_stack ;;
    --down)     stop_current_stack ;;
    --restart)  restart_current_stack ;;
    --mode)     cmd_mode "${2:-}" "${3:-}" ;;
    --logs)     cmd_logs "${2:-$PHP_CURRENT}" "${3:-120}" ;;
    --health)   cmd_health ;;
    --panel)    cmd_panel "${2:-status}" ;;
    --env)      printf 'PHP_CURRENT=%s  DB_CURRENT=%s  PG_CURRENT=%s  NODE_CURRENT=%s\n' "$PHP_CURRENT" "$DB_CURRENT" "$PG_CURRENT" "$NODE_CURRENT" ;;
    --switch)   [ -n "${3:-}" ] && cmd_switch "$2" "$3" || { echo "Uso: panel.sh --switch php|db|pg <version>"; exit 2; } ;;
    -h|--help)
        grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | head -16 ;;
    "") : ;; # sin argumentos → menú interactivo
    *) echo "Opción desconocida: $1  (usa --status, --up, --down, --restart, --logs, --health, --panel, --switch, --env)"; exit 2 ;;
esac
[ -n "${1:-}" ] && exit 0

while true; do
    mostrar_menu; read -r opcion
    case $opcion in
        1) seleccion_php ;;
        2) seleccion_db ;;
        3) seleccion_pg ;;
        4) seleccion_node ;;
        5) BEARWSL_INTERACTIVE=1 "$BEARWSL_DIR/vhost.sh" create ;;
        6) "$BEARWSL_DIR/vhost.sh" list ; echo -n "Presiona enter para continuar..."; read -r ;;
        7) cmd_panel ;;
        8) echo -n "Servicio [php85]: "; read -r svc; cmd_logs "${svc:-php85}" ;;
        9) cmd_health ; echo -n "Presiona enter para continuar..."; read -r ;;
        10|m|M) cmd_mode_interactive ;;
        [Ii]) start_current_stack ; sleep 1 ;;
        [Dd]) stop_current_stack ; sleep 1 ;;
        [Rr]) restart_current_stack ; sleep 1 ;;
        [Xx]) clear; exit 0 ;;
    esac
done
_BEOF_PANEL
    render_file "vhost.sh" 755 <<'_BEOF_VHOST'
#!/bin/bash
# ============================================================
#  BEARWSL — Administrador de Virtual Hosts (nginx)
#
#  USO:
#    vhost.sh                              → modo interactivo
#    vhost.sh create --domain d [--folder f] [--backend fpm|roadrunner]
#                    [--php 74|84|85] [--laravel]
#    vhost.sh delete <dominio> [--force]
#    vhost.sh list [--json]
#    vhost.sh enable <dominio>
#    vhost.sh disable <dominio>
#    vhost.sh info <dominio>
#
#  Rutas de backend (nginx):
#    fpm         → fastcgi_pass 127.0.0.1:<puerto php> (PHP-FPM)
#    roadrunner  → proxy_pass http://127.0.0.1:8080  (RoadRunner)
#
#  Variables de entorno útiles (tests / entornos distintos):
#    NGINX_DIR=/etc/nginx   BEARWSL_NO_VERIFY=1   BEARWSL_TEST_MODE=1
# ============================================================
set -uo pipefail

BEARWSL_DIR="${BEARWSL_DIR:-$HOME/bearwsl}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
SITES_AVAILABLE="$NGINX_DIR/sites-available"
SITES_ENABLED="$NGINX_DIR/sites-enabled"
WWW_DIR="${WWW_DIR:-/var/www}"
RR_PORT="8080"

# shellcheck source=scripts/helpers.sh
if ! source "$BEARWSL_DIR/scripts/helpers.sh" 2>/dev/null; then
    echo "⚠ No encuentro $BEARWSL_DIR/scripts/helpers.sh" >&2; exit 1
fi
load_env

say()  { printf '%s\n' "$*"; }
err()  { printf '⚠  %s\n' "$*" >&2; }
ok()   { printf '✔  %s\n' "$*"; }
hr()   { printf -- '---------------------------------------------------------\n'; }

# ---- ejecución como root (directo o vía sudo) ----
run_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@" 2>/dev/null || sudo "$@"; fi
}

# ---- /etc/hosts: en Linux nativo los dominios .test se registran aquí ----
# (en WSL se mapean en el hosts de Windows)
# comprueba si <dominio> aparece como campo en /etc/hosts (exacto, sin falsos positivos)
hosts_has() {
    local d="$1"
    awk -v d="$d" '{for(i=2;i<=NF;i++) if($i==d) f=1} END{exit !f}' /etc/hosts 2>/dev/null
}

hosts_add() { # hosts_add dominio — añade 127.0.0.1 <dominio> (idempotente)
    local d="$1"
    if is_wsl || [ "${BEARWSL_TEST_MODE:-0}" = "1" ]; then return 0; fi
    if hosts_has "$d"; then return 0; fi
    run_root sh -c "echo '127.0.0.1 $d' >> /etc/hosts"
    ok "Añadido a /etc/hosts: 127.0.0.1 $d"
}

hosts_del() { # hosts_del dominio — quita las líneas que contienen <dominio>
    local d="$1" tmp
    if is_wsl || [ "${BEARWSL_TEST_MODE:-0}" = "1" ]; then return 0; fi
    hosts_has "$d" || return 0
    tmp=$(mktemp)
    run_root awk -v d="$d" '{f=0; for(i=2;i<=NF;i++) if($i==d) f=1; if(!f) print}' /etc/hosts > "$tmp"
    run_root install -m 644 "$tmp" /etc/hosts
    rm -f "$tmp"
    ok "Eliminado de /etc/hosts: $d"
}

# ---- recarga de nginx (con verificación de sintaxis) ----
nginx_reload() {
    if [ "${BEARWSL_TEST_MODE:-0}" = "1" ]; then
        say "[test] nginx -t + reload (omitido)"; return 0
    fi
    if ! nginx -t 2>/dev/null && ! run_root nginx -t 2>/dev/null; then
        err "La configuración de nginx no es válida. Revisa: nginx -t"; return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || run_root systemctl reload nginx
    else
        nginx -s reload 2>/dev/null || run_root nginx -s reload
    fi
    ok "nginx recargado"
}

# ---- verificación de que el servicio de backend existe y está corriendo ----
check_backend() {
    local backend="$1" php_service="$2"
    [ "${BEARWSL_NO_VERIFY:-0}" = "1" ] && return 0
    if [ "$backend" = "roadrunner" ]; then
        if ! is_svc_running roadrunner; then
            err "RoadRunner (b-roadrunner) no está corriendo."
            echo -n "¿Iniciarlo? [S/n]: "; read -r r
            if [[ ! "$r" =~ ^[Nn]$ ]]; then svc_start roadrunner; else err "Abortado: inicia roadrunner y reintenta."; return 1; fi
        fi
    else
        if ! is_svc_running "$php_service"; then
            err "$(version_of "$php_service") no está corriendo (modo $(svc_mode "$php_service"))."
            echo -n "¿Iniciarlo? [S/n]: "; read -r r
            if [[ ! "$r" =~ ^[Nn]$ ]]; then svc_start "$php_service"; else err "Abortado: inicia $php_service y reintenta."; return 1; fi
        fi
    fi
    return 0
}

# ---- generación del bloque server de nginx ----
generate_config() {
    local domain="$1" root_path="$2" backend="$3" php_port="$4"
    if [ "$backend" = "roadrunner" ]; then
        cat <<CONF
server {
    listen 80;
    server_name $domain;
    root $root_path;
    index index.php index.html;

    # Ruta roadrunner: proxy a RoadRunner (127.0.0.1:$RR_PORT)
    location / {
        proxy_pass http://127.0.0.1:$RR_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Healthcheck del vhost (útil para verificar que nginx responde)
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 'ok';
    }
}
CONF
    else
        cat <<CONF
server {
    listen 80;
    server_name $domain;
    root $root_path;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Ruta fpm: PHP-FPM (127.0.0.1:$php_port)
    location ~ \\.php$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:$php_port;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
CONF
    fi
}

# ---- escritura de archivos en /etc/nginx ----
write_site() {
    local domain="$1" content="$2"
    if [ -w "$SITES_AVAILABLE" ]; then
        printf '%s\n' "$content" > "$SITES_AVAILABLE/$domain"
    else
        printf '%s\n' "$content" | run_root tee "$SITES_AVAILABLE/$domain" >/dev/null
    fi
    [ -w "$SITES_ENABLED" ] && ln -sf "$SITES_AVAILABLE/$domain" "$SITES_ENABLED/$domain" \
        || run_root ln -sf "$SITES_AVAILABLE/$domain" "$SITES_ENABLED/$domain"
}

domain_valid() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]] && [[ "$1" != *".."* ]]; }

folder_valid() {
    case "$1" in
        ""|.*|*..*|/*|*/*) return 1 ;;
        *) return 0 ;;
    esac
}

ensure_folder() {
    local folder="$1"
    if [ ! -d "$WWW_DIR/$folder" ]; then
        say "La carpeta $WWW_DIR/$folder no existe. Creándola…"
        if mkdir -p "$WWW_DIR/$folder" 2>/dev/null; then
            chmod 2775 "$WWW_DIR/$folder" 2>/dev/null || true
            chgrp www-data "$WWW_DIR/$folder" 2>/dev/null || true
        else
            run_root mkdir -p "$WWW_DIR/$folder"
            run_root chmod 2775 "$WWW_DIR/$folder"
            run_root chgrp www-data "$WWW_DIR/$folder"
        fi
    fi
}

# ============================================================
#  COMANDO: create
# ============================================================
cmd_create() {
    local domain="" folder="" backend="fpm" php_ver="" laravel=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --domain)    domain="$2"; shift 2 ;;
            --folder)    folder="$2"; shift 2 ;;
            --backend)   backend="$2"; shift 2 ;;
            --php)       php_ver="$2"; shift 2 ;;
            --laravel)   laravel=1; shift ;;
            *) err "Opción desconocida: $1"; return 2 ;;
        esac
    done

    # --- pregunta interactiva si faltan datos ---
    if [ -z "$domain" ]; then
        echo -n "Dominio (ej: api.test): "; read -r domain
    fi
    if ! domain_valid "$domain"; then err "Dominio inválido: $domain"; return 2; fi
    if [ -f "$SITES_AVAILABLE/$domain" ]; then err "Ya existe un vhost para $domain"; return 2; fi

    if [ -z "$folder" ]; then
        echo -n "Carpeta dentro de /var/www: "; read -r folder
    fi
    if ! folder_valid "$folder"; then err "Carpeta inválida: $folder"; return 2; fi
    ensure_folder "$folder"

    if [ -z "$backend" ] || { [ "$backend" != "fpm" ] && [ "$backend" != "roadrunner" ]; }; then
        echo "Backend: [1] PHP-FPM   [2] RoadRunner"; echo -n "Selecciona: "; read -r b
        case "$b" in 2|[Rr]*) backend="roadrunner" ;; *) backend="fpm" ;; esac
    fi

    # --- resolución de la versión de PHP (solo fpm) ---
    local php_service="${PHP_CURRENT:-php85}"
    if [ "$backend" = "fpm" ]; then
        if [ -n "$php_ver" ]; then
            case "$php_ver" in
                74) php_service="php74" ;; 84) php_service="php84" ;; 85) php_service="php85" ;;
                *) err "Versión PHP no soportada: $php_ver (usa 74, 84 o 85)"; return 2 ;;
            esac
        elif [ "${BEARWSL_INTERACTIVE:-0}" = "1" ]; then
            echo "Versión PHP: [1] 7.4 (9002)  [2] 8.4 (9001)  [3] 8.5 (9000, actual)"; echo -n "Selecciona [3]: "; read -r pv
            case "$pv" in 1) php_service="php74" ;; 2) php_service="php84" ;; *) php_service="php85" ;; esac
        fi
    fi

    # --- verificación de que el servicio existe / está corriendo ---
    check_backend "$backend" "$php_service" || return 1

    # --- carpeta raíz (Laravel apunta a /public) ---
    local root_path="$WWW_DIR/$folder"
    if [ -n "$laravel" ] && [ "$laravel" = "1" ]; then root_path="$WWW_DIR/$folder/public"; fi
    if [ "${BEARWSL_INTERACTIVE:-0}" = "1" ]; then
        echo -n "¿Es Laravel? (S/N): "; read -r il
        [[ "$il" =~ ^[Ss]$ ]] && root_path="$WWW_DIR/$folder/public"
    fi

    local php_port; php_port=$(port_of "$php_service")
    local content; content=$(generate_config "$domain" "$root_path" "$backend" "${php_port:-9000}")

    write_site "$domain" "$content"
    nginx_reload || return 1

    hr
    ok "Vhost creado: http://$domain  ($backend, root: $root_path)"
    if is_wsl; then
        local ip; ip=$(wsl_ip)
        [ -n "$ip" ] && say "Mapea el host en Windows (hosts): $ip $domain"
    else
        hosts_add "$domain"
    fi
    hr
}

# ============================================================
#  COMANDO: list
# ============================================================
cmd_list() {
    local json="${1:-}"
    [ -d "$SITES_AVAILABLE" ] || { err "No existe $SITES_AVAILABLE"; return 1; }
    shopt -s nullglob
    local confs=("$SITES_AVAILABLE"/*)
    shopt -u nullglob

    if [ "$json" = "--json" ]; then
        # Salida simple para la API web: dominio|estado|backend|root
        local entry
        for conf in "${confs[@]}"; do
            [ -f "$conf" ] || continue
            local dom root backend port
            dom=$(basename "$conf")
            root=$(grep -m1 '^\s*root ' "$conf" | sed 's/.*root //; s/;//')
            if grep -q 'proxy_pass http://127.0.0.1:8080' "$conf"; then
                backend="roadrunner"; port="8080"
            else
                backend="fpm"; port=$(grep -m1 'fastcgi_pass' "$conf" | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2)
                port="${port:-9000}"
            fi
            local st="disabled"
            [ -L "$SITES_ENABLED/$dom" ] && st="enabled"
            printf '%s|%s|%s|%s|%s\n' "$dom" "$st" "$backend" "$port" "$root"
        done
        return 0
    fi

    hr
    say "   📋  VIRTUAL HOSTS DEFINIDOS  ($NGINX_DIR)"
    hr
    [ ${#confs[@]} -eq 0 ] && { say "   No hay virtual hosts."; hr; return 0; }
    local i=1
    for conf in "${confs[@]}"; do
        [ -f "$conf" ] || continue
        local dom root backend port st
        dom=$(basename "$conf")
        root=$(grep -m1 '^\s*root ' "$conf" | sed 's/.*root //; s/;//')
        if grep -q 'proxy_pass http://127.0.0.1:8080' "$conf"; then
            backend="roadrunner"; port="8080"
        else
            backend="fpm"; port=$(grep -m1 'fastcgi_pass' "$conf" | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2)
            port="${port:-9000}"
        fi
        if [ -L "$SITES_ENABLED/$dom" ]; then st="✅ habilitado"; else st="❌ deshabilitado"; fi
        say "   [$i] $dom"
        say "       backend : $backend (puerto $port)   $st"
        say "       root    : $root"
        hr
        ((i++))
    done
    return 0
}

# ============================================================
#  COMANDO: enable / disable / delete / info
# ============================================================
site_exists() {
    local domain="$1"
    if [ ! -f "$SITES_AVAILABLE/$domain" ]; then err "No existe el vhost $domain"; return 1; fi
    return 0
}

cmd_enable() {
    local domain="$1"
    site_exists "$domain" || return 1
    [ -w "$SITES_ENABLED" ] && ln -sf "$SITES_AVAILABLE/$domain" "$SITES_ENABLED/$domain" \
        || run_root ln -sf "$SITES_AVAILABLE/$domain" "$SITES_ENABLED/$domain"
    nginx_reload && ok "Habilitado: $domain"
}

cmd_disable() {
    local domain="$1"
    site_exists "$domain" || return 1
    [ -w "$SITES_ENABLED" ] && rm -f "$SITES_ENABLED/$domain" \
        || run_root rm -f "$SITES_ENABLED/$domain"
    nginx_reload && ok "Deshabilitado: $domain"
}

cmd_delete() {
    local domain="$1" force="${2:-}"
    site_exists "$domain" || return 1
    if [ "$force" != "--force" ]; then
        echo -n "¿Eliminar el vhost $domain? (la carpeta NO se borra) [s/N]: "; read -r r
        [[ "$r" =~ ^[Ss]$ ]] || { say "Cancelado."; return 0; }
    fi
    [ -w "$SITES_ENABLED" ] && rm -f "$SITES_ENABLED/$domain" || run_root rm -f "$SITES_ENABLED/$domain"
    [ -w "$SITES_AVAILABLE" ] && rm -f "$SITES_AVAILABLE/$domain" || run_root rm -f "$SITES_AVAILABLE/$domain"
    nginx_reload && ok "Eliminado: $domain"
    hosts_del "$domain"
}

cmd_info() {
    local domain="$1"
    site_exists "$domain" || return 1
    hr
    say "   Información de $domain"
    hr
    cat "$SITES_AVAILABLE/$domain"
    hr
    if [ -L "$SITES_ENABLED/$domain" ]; then say "Estado: ✅ habilitado"; else say "Estado: ❌ deshabilitado"; fi
    hr
}

# ============================================================
#  MODO INTERACTIVO
# ============================================================
interactive() {
    while true; do
        clear
        hr
        say "           📋  ADMINISTRADOR DE VIRTUAL HOSTS"
        hr
        local i=1
        if [ -d "$SITES_AVAILABLE" ]; then
            shopt -s nullglob
            local confs=("$SITES_AVAILABLE"/*)
            shopt -u nullglob
            for conf in "${confs[@]}"; do
                [ -f "$conf" ] || continue
                local dom root st
                dom=$(basename "$conf")
                root=$(grep -m1 '^\s*root ' "$conf" | sed 's/.*root //; s/;//')
                if [ -L "$SITES_ENABLED/$dom" ]; then st="✅"; else st="❌"; fi
                say "   [$i] $st $dom → $root"
                ((i++))
            done
        fi
        [ "$i" -eq 1 ] && say "   (no hay virtual hosts aún)"
        hr
        say "   [N] Nuevo vhost      [D] Borrar vhost"
        say "   [0] Volver al menú principal"
        hr
        echo -n "Selecciona: "; read -r opcion
        case "$opcion" in
            0|[Xx]) clear; return 0 ;;
            [Nn]) BEARWSL_INTERACTIVE=1 cmd_create ;;
            [Dd])
                echo -n "Dominio a borrar: "; read -r d
                cmd_delete "$d" ;;
            *)
                if [[ "$opcion" =~ ^[0-9]+$ ]] && [ -d "$SITES_AVAILABLE" ]; then
                    shopt -s nullglob
                    local arr=("$SITES_AVAILABLE"/*)
                    shopt -u nullglob
                    if [ "$opcion" -ge 1 ] && [ "$opcion" -le ${#arr[@]} ]; then
                        local dom2; dom2=$(basename "${arr[$((opcion-1))]}")
                        if [ -L "$SITES_ENABLED/$dom2" ]; then cmd_disable "$dom2"; else cmd_enable "$dom2"; fi
                    fi
                fi
                ;;
        esac
    done
}

# ============================================================
#  DESPACHADOR
# ============================================================
case "${1:-}" in
    create)  shift; cmd_create "$@" ;;
    list)    cmd_list "${2:-}" ;;
    enable)  [ -n "${2:-}" ] && cmd_enable "$2" || { err "Uso: vhost.sh enable <dominio>"; exit 2; } ;;
    disable) [ -n "${2:-}" ] && cmd_disable "$2" || { err "Uso: vhost.sh disable <dominio>"; exit 2; } ;;
    delete)  [ -n "${2:-}" ] && cmd_delete "$2" "${3:-}" || { err "Uso: vhost.sh delete <dominio>"; exit 2; } ;;
    info)    [ -n "${2:-}" ] && cmd_info "$2" || { err "Uso: vhost.sh info <dominio>"; exit 2; } ;;
    "")
        interactive
        ;;
    help|-h|--help)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -30
        ;;
    *)
        err "Comando desconocido: $1"
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -12
        exit 2 ;;
esac
_BEOF_VHOST
    render_file "docker-compose.yml" 644 <<'_BEOF_COMPOSE'
name: bearwsl

# ============================================================
#  BEARWSL — Stack de desarrollo completo (simil Bearsampp)
#  Docker Compose: versiones múltiples de PHP, MariaDB, Postgres
#  + Redis, Mailpit y RoadRunner.
#
#  Puertos (cada versión tiene el suyo, evita conflictos):
#    php74→9002  php84→9001  php85→9000
#    mariadb10→3307  mariadb11→3306
#    postgres15→5433  postgres17→5432
#    redis→6379  mailpit→8025/1025  roadrunner→8080
#
#  Conectividad desde PHP: dentro de los contenedores usa los
#  nombres de servicio como host (mariadb11, postgres17, redis).
#  Desde Windows/WSL usa localhost + el puerto del host.
# ============================================================

networks:
  bear_network:
    name: bear_network
    driver: bridge

x-php-base: &php-base
  restart: unless-stopped
  volumes:
    - /var/www:/var/www:rw
  networks:
    - bear_network
  healthcheck:
    test: ["CMD-SHELL", "nc -z 127.0.0.1 9000 || exit 1"]
    interval: 15s
    timeout: 3s
    retries: 5
    start_period: 30s

x-db-base: &db-base
  restart: unless-stopped
  networks:
    - bear_network

services:
  # ----------------------------------------------------------
  # PHP-FPM (varias versiones)
  # Extensión extra: docker exec b-php85 install-php-extensions xdebug
  # ----------------------------------------------------------
  php74:
    image: php:7.4-fpm-alpine
    container_name: b-php74
    <<: *php-base
    ports: ["9002:9000"]
    command: >
      sh -c "curl -fsSL https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions
      -o /usr/local/bin/install-php-extensions && chmod +x /usr/local/bin/install-php-extensions &&
      install-php-extensions pdo_mysql mysqli pdo_pgsql pgsql redis gd zip bcmath intl opcache mbstring sockets exif pcntl soap pdo_sqlite sqlite3 curl &&
      php-fpm"

  php84:
    image: php:8.4-fpm-alpine
    container_name: b-php84
    <<: *php-base
    ports: ["9001:9000"]
    command: >
      sh -c "curl -fsSL https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions
      -o /usr/local/bin/install-php-extensions && chmod +x /usr/local/bin/install-php-extensions &&
      install-php-extensions pdo_mysql mysqli pdo_pgsql pgsql redis gd zip bcmath intl opcache mbstring sockets exif pcntl soap pdo_sqlite sqlite3 curl &&
      php-fpm"

  php85:
    image: php:8.5-fpm-alpine
    container_name: b-php85
    <<: *php-base
    ports: ["9000:9000"]
    command: >
      sh -c "curl -fsSL https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions
      -o /usr/local/bin/install-php-extensions && chmod +x /usr/local/bin/install-php-extensions &&
      install-php-extensions pdo_mysql mysqli pdo_pgsql pgsql redis gd zip bcmath intl opcache mbstring sockets exif pcntl soap pdo_sqlite sqlite3 curl &&
      php-fpm"

  # ----------------------------------------------------------
  # MariaDB (varias versiones)
  # ----------------------------------------------------------
  mariadb10:
    image: mariadb:10.11
    container_name: b-mariadb10
    <<: *db-base
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_ROOT_HOST: "%"
    ports: ["3307:3306"]
    volumes:
      - /var/lib/bearwsl/data/mariadb/v10:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h127.0.0.1 -uroot -proot --silent || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

  mariadb11:
    image: mariadb:11.4
    container_name: b-mariadb11
    <<: *db-base
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_ROOT_HOST: "%"
    ports: ["3306:3306"]
    volumes:
      - /var/lib/bearwsl/data/mariadb/v11:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h127.0.0.1 -uroot -proot --silent || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

  # ----------------------------------------------------------
  # PostgreSQL (varias versiones)
  # ----------------------------------------------------------
  postgres15:
    image: postgres:15-alpine
    container_name: b-postgres15
    <<: *db-base
    environment:
      POSTGRES_PASSWORD: root
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
    ports: ["5433:5432"]
    volumes:
      - /var/lib/bearwsl/data/postgres/v15:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -h 127.0.0.1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

  postgres17:
    image: postgres:17-alpine
    container_name: b-postgres17
    <<: *db-base
    environment:
      POSTGRES_PASSWORD: root
      POSTGRES_USER: postgres
      POSTGRES_DB: postgres
    ports: ["5432:5432"]
    volumes:
      - /var/lib/bearwsl/data/postgres/v17:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -h 127.0.0.1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

  # ----------------------------------------------------------
  # Utilidades
  # ----------------------------------------------------------
  redis:
    image: redis:7-alpine
    container_name: b-redis
    <<: *db-base
    ports: ["6379:6379"]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 5

  mailpit:
    image: axllent/mailpit
    container_name: b-mailpit
    <<: *db-base
    ports: ["8025:8025", "1025:1025"]

  # ----------------------------------------------------------
  # RoadRunner — ruta "roadrunner" de nginx (proxy → 8080)
  # Imagen propia con PHP 8.3 + binario rr (ver docker/roadrunner)
  # ----------------------------------------------------------
  roadrunner:
    build:
      context: ./docker/roadrunner
      args:
        RR_VERSION: 2025.1.15
    image: bearwsl/roadrunner:2025.1.15
    container_name: b-roadrunner
    restart: unless-stopped
    ports: ["8080:8080"]
    volumes:
      - /var/www:/var/www:rw
    working_dir: /var/www
    networks:
      - bear_network
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 8080 || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 20s
_BEOF_COMPOSE
    render_file "docker/roadrunner/Dockerfile" 644 <<'_BEOF_RR_DOCKERFILE'
# ============================================================
#  BEARWSL — RoadRunner (servidor de aplicaciones PHP)
#  Ruta "roadrunner" de nginx → proxy a 127.0.0.1:8080
# ============================================================
FROM php:8.3-cli-alpine

# Versión estable verificada de RoadRunner (GitHub releases)
ARG RR_VERSION=2025.1.15

# 1) Extensiones PHP necesarias para la mayoría de desarrollos
#    (mismo set que los contenedores php-fpm del stack)
RUN curl -fsSL https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions \
        -o /usr/local/bin/install-php-extensions \
    && chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions pdo_mysql mysqli pdo_pgsql pgsql redis gd zip bcmath \
        intl opcache mbstring sockets exif pcntl soap pdo_sqlite sqlite3 curl

# 2) Binario RoadRunner (detección de arquitectura: amd64 / arm64)
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)  RR_ARCH=amd64 ;; \
        aarch64) RR_ARCH=arm64 ;; \
        *) echo "Arquitectura no soportada: $(uname -m)"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/roadrunner-server/roadrunner/releases/download/v${RR_VERSION}/roadrunner-${RR_VERSION}-linux-${RR_ARCH}.tar.gz" \
        -o /tmp/rr.tar.gz; \
    tar -xzf /tmp/rr.tar.gz -C /tmp; \
    mv "/tmp/roadrunner-${RR_VERSION}-linux-${RR_ARCH}/rr" /usr/local/bin/rr; \
    chmod +x /usr/local/bin/rr; \
    rm -rf /tmp/rr.tar.gz /tmp/roadrunner-*

# 3) Composer + dependencias del worker stub (PSR-7)
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && mkdir -p /opt/rr-worker \
    && cd /opt/rr-worker \
    && composer require --no-interaction --no-progress spiral/roadrunner-http:^3 nyholm/psr7:^1 \
    && rm -rf /root/.composer/cache /tmp/*

# 4) Worker stub + configuración por defecto (fallback global)
COPY worker.php /opt/rr-worker/worker.php
COPY .rr.yaml /etc/roadrunner/.rr.yaml

WORKDIR /var/www

# Si el proyecto tiene su propio .rr.yaml en /var/www se usa; si no, el stub
CMD ["sh", "-c", "if [ -f /var/www/.rr.yaml ]; then exec rr serve -c /var/www/.rr.yaml; else exec rr serve -c /etc/roadrunner/.rr.yaml; fi"]
_BEOF_RR_DOCKERFILE
    render_file "docker/roadrunner/.rr.yaml" 644 <<'_BEOF_RR_YAML'
# Configuración global por defecto de RoadRunner (fallback).
# Los proyectos pueden definir su propio /var/www/.rr.yaml y tendrá prioridad.
version: "3"

server:
  command: "php /opt/rr-worker/worker.php"

http:
  address: "0.0.0.0:8080"
  pool:
    num_workers: 4
    max_jobs: 100

logs:
  mode: development
  level: info
_BEOF_RR_YAML
    render_file "docker/roadrunner/worker.php" 644 <<'_BEOF_RR_WORKER'
<?php
/**
 * Worker stub de BEARWSL para RoadRunner.
 * Se usa cuando el proyecto no define su propio worker / .rr.yaml.
 * Los proyectos reales deben reemplazar esta respuesta con su aplicación
 * (ej: Spiral, Laravel con roadrunner-laravel, Symfony con RoadRunner, etc.)
 */

declare(strict_types=1);

use Nyholm\Psr7;
use Spiral\RoadRunner;
use Spiral\RoadRunner\Http\PSR7Worker;

require '/opt/rr-worker/vendor/autoload.php';

$worker = RoadRunner\Worker::create();
$psr7 = new PSR7Worker(
    $worker,
    new Psr7\Factory\Psr17Factory(),
    new Psr7\Factory\Psr17Factory(),
    new Psr7\Factory\Psr17Factory()
);

$html = <<<'HTML'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>RoadRunner · BEARWSL</title>
<style>
  body{font-family:system-ui,-apple-system,sans-serif;background:#0f172a;color:#e2e8f0;
       display:grid;place-items:center;min-height:100vh;margin:0}
  .card{max-width:640px;background:#1e293b;border:1px solid #334155;border-radius:16px;
        padding:32px;box-shadow:0 20px 50px rgba(0,0,0,.4)}
  h1{margin:0 0 8px;font-size:24px}
  .badge{display:inline-block;background:#16a34a22;color:#4ade80;border:1px solid #16a34a55;
         border-radius:999px;padding:4px 12px;font-size:13px;font-weight:600;margin-bottom:16px}
  p{color:#94a3b8;line-height:1.6;margin:8px 0}
  code{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:2px 6px;color:#7dd3fc}
</style>
</head>
<body>
  <div class="card">
    <span class="badge">● RoadRunner activo</span>
    <h1>🚀 RoadRunner está funcionando</h1>
    <p>Este worker <em>stub</em> es la respuesta por defecto de BEARWSL.
       Tu virtual host con ruta <code>roadrunner</code> está sirviendo vía
       <code>proxy → 127.0.0.1:8080</code>.</p>
    <p>Para servir tu aplicación: crea <code>/var/www/tu-proyecto/.rr.yaml</code>
       y un worker (Spiral, Laravel Octane + roadrunner, etc.) y reinicia el servicio:
       <code>docker compose restart roadrunner</code></p>
    <p><small>PHP <code>8.3</code> · RoadRunner <code>2025.1.15</code></small></p>
  </div>
</body>
</html>
HTML;

while (true) {
    try {
        $request = $psr7->waitRequest();
        if ($request === null) {
            break; // el servidor se está deteniendo
        }
    } catch (\Throwable $e) {
        $psr7->getWorker()->error((string) $e);
        continue;
    }

    $response = new Psr7\Response(200, ['Content-Type' => 'text/html; charset=utf-8']);
    $response->getBody()->write($html);
    $psr7->respond($response);
}
_BEOF_RR_WORKER
    render_file "webpanel/index.html" 644 <<'_BEOF_INDEX'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>BEARWSL · Panel de control</title>
  <link rel="icon" href="/favicon.svg">
  <link rel="stylesheet" href="/style.css">
</head>
<body>

  <!-- Pantalla de login -->
  <div id="login" class="login-overlay hidden">
    <div class="login-card">
      <div class="login-logo">🐻</div>
      <h1>BEARWSL</h1>
      <p class="muted">Panel de control del stack de desarrollo</p>
      <form id="loginForm" autocomplete="off">
        <label for="tokenInput">Token de acceso</label>
        <input type="password" id="tokenInput" placeholder="pega el token aquí" required>
        <button type="submit" class="primary block">Entrar</button>
      </form>
      <p class="hint muted">El token está en <code>~/.config/bearwsl/panel_token</code><br>o ejecuta: <code>panel.sh --panel token</code></p>
    </div>
  </div>

  <!-- Barra superior -->
  <header class="topbar">
    <div class="brand">
      <span class="logo">🐻</span>
      <div>
        <h1>BEARWSL</h1>
        <p>Stack de desarrollo · inspirado en <a href="https://bearsampp.com/" target="_blank" rel="noopener" title="Gracias Troy Hall">Bearsampp</a></p>
      </div>
    </div>
    <div class="top-actions">
      <span id="stackPill" class="pill neutral">conectando…</span>
      <button class="btn ok" id="btnUp">▶ Iniciar</button>
      <button class="btn warn" id="btnDown">⏹ Detener</button>
      <button class="btn" id="btnRestart">⟳ Reiniciar</button>
      <button class="btn ghost" id="btnRefresh" title="Actualizar">⟳</button>
      <button class="btn ghost" id="btnLogout" title="Cerrar sesión">Salir</button>
    </div>
  </header>

  <main id="main" class="hidden">
    <!-- Servicios + Versiones -->
    <section class="grid-2">
      <div class="card">
        <div class="card-head">
          <h2>📦 Servicios Docker</h2>
          <span class="badge" id="svcCount">0</span>
        </div>
        <div class="table-wrap">
          <table id="servicesTable">
            <thead><tr><th>Servicio</th><th>Estado</th><th>Salud</th><th>Acciones</th></tr></thead>
            <tbody></tbody>
          </table>
        </div>
      </div>

      <div class="card">
        <h2>⚙️ Versiones</h2>
        <div id="versions" class="versions"></div>
      </div>
    </section>

    <!-- Vhosts + Directorios -->
    <section class="grid-2">
      <div class="card">
        <div class="card-head">
          <h2>🌐 Virtual Hosts</h2>
          <button class="primary small" id="btnNewVhost">+ Nuevo vhost</button>
        </div>
        <div class="table-wrap">
          <table id="vhostsTable">
            <thead><tr><th>Dominio</th><th>Backend</th><th>Root</th><th>Estado</th><th></th></tr></thead>
            <tbody></tbody>
          </table>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <h2>📁 Directorios /var/www</h2>
          <a class="badge link" href="http://bearwsl.test/" target="_blank">bearwsl.test ↗</a>
        </div>
        <div id="wwwDirs" class="dirs"></div>
      </div>
    </section>

    <!-- Utilidades + Comandos -->
    <section class="grid-2">
      <div class="card">
        <h2>🧰 Utilidades instaladas</h2>
        <div id="utils" class="chips"></div>
      </div>
      <div class="card">
        <h2>💻 Comandos disponibles</h2>
        <div id="commands" class="commands"></div>
      </div>
    </section>

    <!-- Sistema -->
    <section class="card">
      <h2>🖥️ Sistema</h2>
      <div id="system" class="system"></div>
    </section>
  </main>

  <footer class="foot muted">BEARWSL · panel web · php -S · nginx + docker compose<br>Inspirado en <a href="https://bearsampp.com/" target="_blank" rel="noopener" title="Gracias Troy Hall">Bearsampp</a> · Gracias a <a href="https://github.com/N6REJ" target="_blank" rel="noopener" title="Troy Hall (N6REJ)">Troy Hall (N6REJ)</a></footer>

  <!-- Modal nuevo vhost -->
  <div id="modal" class="modal hidden">
    <div class="modal-card">
      <div class="modal-head">
        <h2>Nuevo Virtual Host</h2>
        <button class="ghost" id="btnCloseModal">✕</button>
      </div>
      <form id="vhostForm">
        <label>Dominio</label>
        <input type="text" id="fDomain" placeholder="ej: api.test" required>
        <label>Carpeta dentro de /var/www</label>
        <input type="text" id="fFolder" list="wwwList" placeholder="ej: api" required>
        <datalist id="wwwList"></datalist>
        <label>Backend (ruta nginx)</label>
        <div class="seg">
          <button type="button" class="seg-btn active" data-backend="fpm">PHP-FPM</button>
          <button type="button" class="seg-btn" data-backend="roadrunner">RoadRunner</button>
        </div>
        <input type="hidden" id="fBackend" value="fpm">
        <label id="phpLabel">Versión de PHP</label>
        <select id="fPhp">
          <option value="php85">PHP 8.5 (9000)</option>
          <option value="php84">PHP 8.4 (9001)</option>
          <option value="php74">PHP 7.4 (9002)</option>
        </select>
        <label class="check"><input type="checkbox" id="fLaravel"> Es Laravel (root → /public)</label>
        <button type="submit" class="primary block">Crear vhost</button>
      </form>
    </div>
  </div>

  <div id="toast" class="toast hidden"></div>
  <script src="/app.js"></script>
</body>
</html>
_BEOF_INDEX
    render_file "webpanel/style.css" 644 <<'_BEOF_STYLE'
/* ============================================================
   BEARWSL — Panel web · tema oscuro
   ============================================================ */
:root {
  --bg: #0b1120;
  --bg2: #0f172a;
  --card: #16213a;
  --card2: #1b2947;
  --line: #26355a;
  --text: #e2e8f0;
  --muted: #8ea3c0;
  --accent: #34d399;
  --accent2: #38bdf8;
  --grad: linear-gradient(135deg, #34d399, #38bdf8);
  --danger: #f87171;
  --warn: #fbbf24;
  --radius: 14px;
  --shadow: 0 12px 32px rgba(0, 0, 0, .35);
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  background:
    radial-gradient(1200px 500px at 80% -10%, rgba(56, 189, 248, .10), transparent 60%),
    radial-gradient(900px 500px at 10% -10%, rgba(52, 211, 153, .10), transparent 60%),
    var(--bg);
  color: var(--text);
  min-height: 100vh;
}
.hidden { display: none !important; }
.muted { color: var(--muted); }
a { color: var(--accent2); }

/* ---------- topbar ---------- */
.topbar {
  position: sticky; top: 0; z-index: 50;
  display: flex; align-items: center; justify-content: space-between; gap: 16px;
  padding: 12px 24px;
  background: rgba(11, 17, 32, .85);
  backdrop-filter: blur(12px);
  border-bottom: 1px solid var(--line);
  flex-wrap: wrap;
}
.brand { display: flex; align-items: center; gap: 12px; }
.brand .logo { font-size: 34px; filter: drop-shadow(0 4px 10px rgba(52,211,153,.35)); }
.brand h1 { margin: 0; font-size: 20px; letter-spacing: .5px; }
.brand h1::after { content: ""; }
.brand p { margin: 0; font-size: 12px; color: var(--muted); }
.top-actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }

/* ---------- botones ---------- */
.btn {
  border: 1px solid var(--line);
  background: var(--card2);
  color: var(--text);
  border-radius: 10px;
  padding: 8px 14px;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  transition: transform .12s ease, box-shadow .12s ease, background .12s ease, border-color .12s ease;
}
.btn:hover { transform: translateY(-1px); box-shadow: 0 6px 16px rgba(0,0,0,.3); border-color: var(--accent2); }
.btn:active { transform: translateY(0); }
.btn.ok { background: linear-gradient(135deg, #059669, #10b981); border-color: transparent; }
.btn.warn { background: linear-gradient(135deg, #b45309, #d97706); border-color: transparent; }
.btn.ghost { background: transparent; }
.btn.primary {
  background: var(--grad); border: none; color: #06222b; font-weight: 700;
  border-radius: 10px; padding: 8px 16px; cursor: pointer;
}
.btn.primary:hover { filter: brightness(1.08); }
.btn.primary.small, .btn.small { padding: 5px 10px; font-size: 12px; border-radius: 8px; }
.btn.block { width: 100%; margin-top: 8px; padding: 10px; }

/* ---------- pills / badges ---------- */
.pill {
  display: inline-flex; align-items: center; gap: 6px;
  border-radius: 999px; padding: 6px 14px; font-size: 12px; font-weight: 700;
  border: 1px solid var(--line);
}
.pill.ok    { background: rgba(52, 211, 153, .12); color: var(--accent); border-color: rgba(52, 211, 153, .4); }
.pill.bad   { background: rgba(248, 113, 113, .12); color: var(--danger); border-color: rgba(248, 113, 113, .4); }
.pill.warn  { background: rgba(251, 191, 36, .12); color: var(--warn); border-color: rgba(251, 191, 36, .4); }
.pill.neutral { background: var(--card2); color: var(--muted); }
.badge {
  display: inline-block; border-radius: 999px; padding: 3px 10px;
  font-size: 11px; font-weight: 700;
  background: var(--card2); color: var(--muted); border: 1px solid var(--line);
}
.badge.link { text-decoration: none; color: var(--accent2); }
.badge.link:hover { border-color: var(--accent2); }
.badge.green { background: rgba(52,211,153,.12); color: var(--accent); border-color: rgba(52,211,153,.4); }
.badge.red { background: rgba(248,113,113,.12); color: var(--danger); border-color: rgba(248,113,113,.4); }
.badge.yellow { background: rgba(251,191,36,.12); color: var(--warn); border-color: rgba(251,191,36,.4); }

/* ---------- layout ---------- */
main {
  max-width: 1400px; margin: 24px auto; padding: 0 24px;
  display: flex; flex-direction: column; gap: 20px;
}
.grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
@media (max-width: 1000px) { .grid-2 { grid-template-columns: 1fr; } }
.card {
  background: linear-gradient(180deg, var(--card), var(--bg2));
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 20px;
  box-shadow: var(--shadow);
  overflow: hidden;
}
.card h2 { margin: 0 0 14px; font-size: 16px; display: flex; align-items: center; gap: 8px; }
.card-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
.card-head h2 { margin: 0; }

/* ---------- tablas ---------- */
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th {
  text-align: left; color: var(--muted); font-size: 11px; text-transform: uppercase;
  letter-spacing: .6px; padding: 8px 10px; border-bottom: 1px solid var(--line);
}
td { padding: 9px 10px; border-bottom: 1px solid rgba(38, 53, 90, .5); vertical-align: middle; }
tr:last-child td { border-bottom: none; }
tbody tr { transition: background .1s ease; }
tbody tr:hover { background: rgba(56, 189, 248, .04); }
td .mono { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; font-size: 12px; }
.svc-btn {
  border: 1px solid var(--line); background: var(--card2); color: var(--muted);
  border-radius: 7px; padding: 3px 8px; font-size: 11px; cursor: pointer; margin-right: 4px;
  transition: all .12s ease;
}
.svc-btn:hover { color: var(--text); border-color: var(--accent2); }
.svc-btn.danger:hover { border-color: var(--danger); color: var(--danger); }

/* ---------- versiones ---------- */
.versions { display: flex; flex-direction: column; gap: 12px; }
.ver-row {
  display: flex; align-items: center; justify-content: space-between; gap: 10px;
  background: var(--card2); border: 1px solid var(--line); border-radius: 10px; padding: 10px 14px;
}
.ver-info { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ver-name { font-weight: 700; font-size: 13px; }
.ver-current { font-size: 11px; color: var(--accent); font-weight: 700; }
.ver-detail { font-size: 11px; color: var(--muted); font-family: ui-monospace, monospace; }
.ver-switch { display: flex; gap: 6px; }
.chip-ver {
  border: 1px solid var(--line); background: transparent; color: var(--muted);
  border-radius: 999px; padding: 4px 10px; font-size: 11px; cursor: pointer; transition: all .12s ease;
}
.chip-ver:hover { color: var(--text); border-color: var(--accent2); }
.chip-ver.on { background: var(--grad); color: #06222b; border-color: transparent; font-weight: 700; }
.chip-ver.offline { opacity: .55; }

/* ---------- directorios ---------- */
.dirs { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
.dir-card {
  display: flex; flex-direction: column; gap: 6px;
  background: var(--card2); border: 1px solid var(--line); border-radius: 10px; padding: 12px;
  transition: transform .12s ease, border-color .12s ease, box-shadow .12s ease;
}
.dir-card:hover { transform: translateY(-2px); border-color: var(--accent2); box-shadow: 0 8px 20px rgba(0,0,0,.35); }
.dir-name { font-weight: 700; font-size: 13px; word-break: break-all; }
.dir-path { font-size: 11px; color: var(--muted); font-family: ui-monospace, monospace; word-break: break-all; }
.dir-link { font-size: 12px; text-decoration: none; font-weight: 600; }
.dir-link:hover { text-decoration: underline; }
.dir-empty { color: var(--muted); font-size: 13px; padding: 8px 0; }

/* ---------- utilidades (chips) ---------- */
.chips { display: flex; flex-wrap: wrap; gap: 8px; }
.chip {
  display: inline-flex; align-items: center; gap: 6px;
  border-radius: 999px; padding: 6px 12px; font-size: 12px;
  border: 1px solid var(--line); background: var(--card2);
}
.chip .dot { width: 8px; height: 8px; border-radius: 50%; }
.chip .dot.ok { background: var(--accent); box-shadow: 0 0 8px rgba(52,211,153,.8); }
.chip .dot.no { background: var(--danger); }
.chip .v { color: var(--muted); font-family: ui-monospace, monospace; font-size: 11px; }

/* ---------- comandos ---------- */
.commands { display: flex; flex-direction: column; gap: 8px; }
.cmd-row {
  display: flex; align-items: center; justify-content: space-between; gap: 10px;
  background: var(--bg2); border: 1px solid var(--line); border-radius: 8px; padding: 8px 12px;
}
.cmd-text { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; font-size: 12px; color: #a5f3fc; word-break: break-all; }
.cmd-desc { font-size: 11px; color: var(--muted); margin-top: 2px; }
.cmd-copy {
  flex-shrink: 0; border: 1px solid var(--line); background: transparent; color: var(--muted);
  border-radius: 6px; padding: 3px 8px; font-size: 11px; cursor: pointer;
}
.cmd-copy:hover { color: var(--text); border-color: var(--accent2); }

/* ---------- sistema ---------- */
.system { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
.sys-item {
  background: var(--card2); border: 1px solid var(--line); border-radius: 10px; padding: 12px;
}
.sys-item .k { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; }
.sys-item .v { font-size: 14px; font-weight: 700; margin-top: 4px; font-family: ui-monospace, monospace; word-break: break-all; }

/* ---------- login ---------- */
.login-overlay {
  position: fixed; inset: 0; z-index: 100;
  display: grid; place-items: center;
  background: radial-gradient(900px 500px at 50% -10%, rgba(56,189,248,.12), transparent 60%), var(--bg);
}
.login-card {
  width: min(400px, 92vw); background: var(--card); border: 1px solid var(--line);
  border-radius: 18px; padding: 32px; box-shadow: var(--shadow); text-align: center;
}
.login-logo { font-size: 56px; filter: drop-shadow(0 8px 20px rgba(52,211,153,.4)); }
.login-card h1 { margin: 8px 0 4px; }
.login-card form { text-align: left; margin-top: 20px; }
.login-card label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 6px; font-weight: 600; }
.login-card input {
  width: 100%; background: var(--bg2); border: 1px solid var(--line); color: var(--text);
  border-radius: 10px; padding: 11px 14px; font-size: 14px; outline: none;
  transition: border-color .12s ease;
}
.login-card input:focus { border-color: var(--accent2); }
.hint { font-size: 12px; margin-top: 16px; line-height: 1.6; }
code { background: var(--bg2); border: 1px solid var(--line); border-radius: 5px; padding: 1px 6px; font-size: 11px; color: #a5f3fc; }

/* ---------- modal ---------- */
.modal {
  position: fixed; inset: 0; z-index: 90;
  display: grid; place-items: center;
  background: rgba(4, 8, 18, .7); backdrop-filter: blur(6px);
}
.modal-card {
  width: min(480px, 92vw); max-height: 90vh; overflow-y: auto;
  background: var(--card); border: 1px solid var(--line);
  border-radius: 16px; padding: 24px; box-shadow: var(--shadow);
}
.modal-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
.modal-head h2 { margin: 0; font-size: 17px; }
.modal form label { display: block; font-size: 12px; color: var(--muted); font-weight: 600; margin: 12px 0 6px; }
.modal input[type="text"], .modal select {
  width: 100%; background: var(--bg2); border: 1px solid var(--line); color: var(--text);
  border-radius: 10px; padding: 10px 12px; font-size: 14px; outline: none;
}
.modal input[type="text"]:focus, .modal select:focus { border-color: var(--accent2); }
.modal label.check { display: flex; align-items: center; gap: 8px; font-weight: 500; color: var(--text); cursor: pointer; }
.modal label.check input { width: auto; }
.seg { display: flex; gap: 6px; }
.seg-btn {
  flex: 1; border: 1px solid var(--line); background: var(--bg2); color: var(--muted);
  border-radius: 10px; padding: 9px; font-size: 13px; font-weight: 600; cursor: pointer;
  transition: all .12s ease;
}
.seg-btn.active { background: var(--grad); color: #06222b; border-color: transparent; }

/* ---------- toast ---------- */
.toast {
  position: fixed; bottom: 24px; right: 24px; z-index: 120;
  max-width: 420px; background: var(--card2); border: 1px solid var(--line);
  border-left: 4px solid var(--accent2); border-radius: 10px; padding: 12px 16px;
  font-size: 13px; box-shadow: var(--shadow); white-space: pre-wrap;
}
.toast.err { border-left-color: var(--danger); }
.toast .tt { font-weight: 700; display: block; margin-bottom: 2px; }
.toast pre { margin: 6px 0 0; font-size: 11px; max-height: 160px; overflow: auto; color: var(--muted); font-family: ui-monospace, monospace; }

/* ---------- footer / misc ---------- */
.foot { text-align: center; padding: 20px; font-size: 12px; line-height: 1.9; }
.foot a { color: var(--accent); text-decoration: none; border-bottom: 1px dotted var(--accent); }
.foot a:hover { color: var(--text); }
.skeleton { position: relative; overflow: hidden; background: var(--card2); border-radius: 8px; height: 40px; }
.skeleton::after {
  content: ""; position: absolute; inset: 0;
  background: linear-gradient(90deg, transparent, rgba(255,255,255,.06), transparent);
  animation: sk 1.4s infinite;
}
@keyframes sk { from { transform: translateX(-100%); } to { transform: translateX(100%); } }
_BEOF_STYLE
    render_file "webpanel/app.js" 644 <<'_BEOF_APPJS'
/* ============================================================
   BEARWSL — Panel web · lógica frontend
   ============================================================ */
(() => {
  'use strict';

  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => [...document.querySelectorAll(sel)];
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  let DATA = null;
  let refreshTimer = null;

  /* ---------------- fetch wrapper ---------------- */
  async function api(path, opts = {}) {
    const res = await fetch(path, {
      headers: { 'Content-Type': 'application/json' },
      ...opts,
    });
    if (res.status === 401) {
      showLogin();
      throw new Error('no_auth');
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok && !data.ok) throw new Error(data.message || data.error || res.statusText);
    return data;
  }

  /* ---------------- toast ---------------- */
  let toastTimer = null;
  function toast(title, body = '', type = '') {
    const el = $('#toast');
    el.className = `toast ${type}`;
    el.innerHTML = `<span class="tt">${esc(title)}</span>${body ? `<pre>${esc(body).slice(0, 1500)}</pre>` : ''}`;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hidden'), 6000);
  }

  /* ---------------- login ---------------- */
  function showLogin() {
    $('#login').classList.remove('hidden');
    $('#main').classList.add('hidden');
  }
  $('#loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
      await api('/api/login', { method: 'POST', body: JSON.stringify({ token: $('#tokenInput').value.trim() }) });
      $('#login').classList.add('hidden');
      $('#main').classList.remove('hidden');
      toast('Sesión iniciada', 'Bienvenido al panel de BEARWSL');
      load();
    } catch (err) {
      toast('Token incorrecto', 'Revisa el token en ~/.config/bearwsl/panel_token', 'err');
    }
  });
  $('#btnLogout').addEventListener('click', async () => {
    try { await api('/api/logout', { method: 'POST' }); } catch (_) {}
    location.reload();
  });

  /* ---------------- render: servicios ---------------- */
  function renderServices(svcs) {
    const tb = $('#servicesTable tbody');
    const up = svcs.filter((s) => s.status.includes('Up')).length;
    $('#svcCount').textContent = `${up}/${svcs.length} activos`;
    const pill = $('#stackPill');
    if (up === 0) { pill.className = 'pill bad'; pill.textContent = '● stack detenido'; }
    else if (up === svcs.length) { pill.className = 'pill ok'; pill.textContent = '● stack activo'; }
    else { pill.className = 'pill warn'; pill.textContent = `● parcial (${up}/${svcs.length})`; }

    tb.innerHTML = svcs.map((s) => {
      const on = s.status.includes('Up');
      const badge = on
        ? (s.health === 'healthy' ? '<span class="badge green">healthy</span>' : '<span class="badge yellow">up</span>')
        : '<span class="badge red">down</span>';
      const btns = on
        ? `<button class="svc-btn" data-svc="${esc(s.service)}" data-act="stop">detener</button>
           <button class="svc-btn" data-svc="${esc(s.service)}" data-act="restart">reiniciar</button>`
        : `<button class="svc-btn" data-svc="${esc(s.service)}" data-act="start">iniciar</button>`;
      return `<tr>
        <td><span class="mono">${esc(s.service)}</span><br><span class="muted" style="font-size:10px">${esc(s.image || '')}</span></td>
        <td>${badge}</td>
        <td class="muted" style="font-size:11px">${esc(s.status)}</td>
        <td>${btns}</td>
      </tr>`;
    }).join('');
  }

  /* ---------------- render: versiones ---------------- */
  function renderVersions(v) {
    const el = $('#versions');
    const env = DATA.env;
    const phpRow = (svc, label) => {
      const p = v.php[svc] || { running: false, version: '' };
      const on = env.PHP_CURRENT === svc;
      return `
        <div class="ver-row">
          <div class="ver-info">
            <span class="ver-name">${label}</span>
            ${on ? '<span class="ver-current">● actual</span>' : ''}
            <span class="ver-detail">${p.version ? `v${esc(p.version)}` : p.running ? '—' : 'detenido'}</span>
          </div>
          <div class="ver-switch">${on ? '' : `<button class="chip-ver" data-switch="php" data-ver="${svc}">usar</button>`}</div>
        </div>`;
    };
    const dbRow = (label, value, svc, family) => {
      const mode = family === 'DB_CURRENT' ? DATA.modes.db : DATA.modes.pg;
      return `
      <div class="ver-row">
        <div class="ver-info">
          <span class="ver-name">${label} <span class="badge ${mode === 'native' ? 'yellow' : ''}">${mode === 'native' ? 'nativo' : 'docker'}</span></span>
          <span class="ver-detail">${esc(value || '—')}</span>
        </div>
        <div class="ver-switch">${env[family] === svc ? '' : `<button class="chip-ver" data-switch="${family === 'DB_CURRENT' ? 'db' : 'pg'}" data-ver="${svc}">usar</button>`}</div>
      </div>`;
    };

    el.innerHTML = `
      <div class="ver-row" style="flex-direction:column;align-items:flex-start;gap:6px">
        <div class="ver-info" style="width:100%;justify-content:space-between">
          <span class="ver-name">PHP-FPM <span class="badge ${DATA.modes.php === 'native' ? 'yellow' : ''}">${DATA.modes.php === 'native' ? 'nativo' : 'docker'}</span></span>
          <span class="ver-detail">${esc(v.php_native || '')} (nativo)</span>
        </div>
        <div style="display:flex;gap:6px;flex-wrap:wrap">
          <button class="chip-ver ${env.PHP_CURRENT === 'php74' ? 'on' : ''} ${v.php.php74?.running ? '' : 'offline'}" data-switch="php" data-ver="php74">7.4</button>
          <button class="chip-ver ${env.PHP_CURRENT === 'php84' ? 'on' : ''} ${v.php.php84?.running ? '' : 'offline'}" data-switch="php" data-ver="php84">8.4</button>
          <button class="chip-ver ${env.PHP_CURRENT === 'php85' ? 'on' : ''} ${v.php.php85?.running ? '' : 'offline'}" data-switch="php" data-ver="php85">8.5</button>
        </div>
      </div>
      ${dbRow('MariaDB', v.mariadb, 'mariadb10', 'DB_CURRENT')}
      ${dbRow('PostgreSQL', v.postgres, 'postgres15', 'PG_CURRENT')}
      <div class="ver-row">
        <div class="ver-info">
          <span class="ver-name">Redis</span>
          <span class="ver-detail">${esc(v.redis || '—')}</span>
        </div>
      </div>
      <div class="ver-row">
        <div class="ver-info">
          <span class="ver-name">Node.js</span>
          <span class="ver-detail">${esc(v.node.current || '—')} · ${esc((v.node.versions || []).map((n) => n.version).join(', '))}</span>
        </div>
      </div>
      <div class="ver-row">
        <div class="ver-info">
          <span class="ver-name">RoadRunner</span>
          <span class="ver-detail">${esc(v.roadrunner || 'no instalado')}</span>
        </div>
      </div>
      <div class="ver-row">
        <div class="ver-info">
          <span class="ver-name">nginx</span>
          <span class="ver-detail">${esc(v.nginx || '—')}</span>
        </div>
      </div>`;
  }

  /* ---------------- render: vhosts ---------------- */
  function renderVhosts(vhosts) {
    const tb = $('#vhostsTable tbody');
    if (!vhosts.length) {
      tb.innerHTML = '<tr><td colspan="5" class="muted" style="text-align:center;padding:20px">No hay virtual hosts todavía.</td></tr>';
      return;
    }
    tb.innerHTML = vhosts.map((v) => `
      <tr>
        <td><span class="mono">${esc(v.domain)}</span></td>
        <td><span class="badge ${v.backend === 'roadrunner' ? 'green' : ''}">${esc(v.backend)}</span>
            <span class="muted" style="font-size:10px">:${esc(v.port)}</span></td>
        <td class="muted" style="font-size:11px;word-break:break-all">${esc(v.root)}</td>
        <td>${v.enabled ? '<span class="badge green">habilitado</span>' : '<span class="badge red">deshabilitado</span>'}</td>
        <td style="white-space:nowrap">
          <button class="svc-btn" data-vhost="${esc(v.domain)}" data-act="${v.enabled ? 'disable' : 'enable'}">${v.enabled ? 'deshabilitar' : 'habilitar'}</button>
          <button class="svc-btn danger" data-vhost="${esc(v.domain)}" data-act="delete">borrar</button>
        </td>
      </tr>`).join('');
  }

  /* ---------------- render: directorios ---------------- */
  function renderWww(dirs) {
    const el = $('#wwwDirs');
    if (!dirs.length) { el.innerHTML = '<div class="dir-empty">/var/www está vacío. Crea un proyecto.</div>'; return; }
    el.innerHTML = dirs.map((d) => `
      <div class="dir-card">
        <span class="dir-name">📁 ${esc(d.name)}</span>
        <span class="dir-path">${esc(d.path)}</span>
        <a class="dir-link" href="${esc(d.link)}" target="_blank">abrir ↗</a>
      </div>`).join('');
  }

  /* ---------------- render: utilidades ---------------- */
  function renderUtils(utils) {
    $('#utils').innerHTML = Object.entries(utils).map(([name, u]) => `
      <span class="chip">
        <span class="dot ${u.present ? 'ok' : 'no'}"></span>
        <span>${esc(name)}</span>
        ${u.version ? `<span class="v">${esc(u.version.split('\n')[0].slice(0, 60))}</span>` : ''}
      </span>`).join('');
  }

  /* ---------------- render: comandos ---------------- */
  function renderCommands(cmds) {
    $('#commands').innerHTML = cmds.map((c) => `
      <div class="cmd-row">
        <div>
          <div class="cmd-text">$ ${esc(c.cmd)}</div>
          <div class="cmd-desc">${esc(c.desc)}</div>
        </div>
        <button class="cmd-copy" data-copy="${esc(c.cmd)}">copiar</button>
      </div>`).join('');
  }

  /* ---------------- render: sistema ---------------- */
  function renderSystem(sys) {
    $('#system').innerHTML = [
      ['Host', sys.hostname], ['IP', sys.ip], ['Tiempo activo', sys.uptime],
      ['Disco ' + DATA.config.www, sys.disk], ['Memoria', sys.mem],
    ].map(([k, v]) => `<div class="sys-item"><div class="k">${esc(k)}</div><div class="v">${esc(v || '—')}</div></div>`).join('');
  }

  /* ---------------- acciones ---------------- */
  async function actStack(action) {
    try {
      const r = await api('/api/stack', { method: 'POST', body: JSON.stringify({ action }) });
      toast(`Stack: ${action}`, r.output, r.ok ? '' : 'err');
      load();
    } catch (err) { toast('Error', err.message, 'err'); }
  }
  async function actService(svc, action) {
    try {
      const r = await api('/api/service', { method: 'POST', body: JSON.stringify({ service: svc, action }) });
      toast(`${svc}: ${action}`, r.output, r.ok ? '' : 'err');
      load();
    } catch (err) { toast('Error', err.message, 'err'); }
  }
  async function actVhost(domain, action) {
    try {
      const r = await api(`/api/vhost/${action}`, { method: 'POST', body: JSON.stringify({ domain }) });
      toast(`Vhost ${domain}: ${action}`, r.output, r.ok ? '' : 'err');
      load();
    } catch (err) { toast('Error', err.message, 'err'); }
  }
  async function actSwitch(family, version) {
    try {
      const r = await api('/api/switch', { method: 'POST', body: JSON.stringify({ family, version }) });
      toast(`Cambiado: ${family} → ${version}`, r.output, r.ok ? '' : 'err');
      load();
    } catch (err) { toast('Error', err.message, 'err'); }
  }

  document.addEventListener('click', (e) => {
    const svcBtn = e.target.closest('[data-svc]');
    if (svcBtn) return actService(svcBtn.dataset.svc, svcBtn.dataset.act);

    const vBtn = e.target.closest('[data-vhost]');
    if (vBtn) {
      if (vBtn.dataset.act === 'delete' && !confirm(`¿Borrar el vhost ${vBtn.dataset.vhost}? (la carpeta NO se borra)`)) return;
      return actVhost(vBtn.dataset.vhost, vBtn.dataset.act);
    }

    const sw = e.target.closest('[data-switch]');
    if (sw) return actSwitch(sw.dataset.switch, sw.dataset.ver);

    const copy = e.target.closest('[data-copy]');
    if (copy) {
      navigator.clipboard?.writeText(copy.dataset.copy).then(() => toast('Copiado', copy.dataset.copy));
    }
  });

  $('#btnUp').addEventListener('click', () => actStack('up'));
  $('#btnDown').addEventListener('click', () => actStack('down'));
  $('#btnRestart').addEventListener('click', () => actStack('restart'));
  $('#btnRefresh').addEventListener('click', load);

  /* ---------------- modal nuevo vhost ---------------- */
  const modal = $('#modal');
  $('#btnNewVhost').addEventListener('click', () => {
    const list = $('#wwwList');
    list.innerHTML = (DATA?.www || []).map((d) => `<option value="${esc(d.name)}">`).join('');
    $('#fBackend').value = 'fpm';
    $$('.seg-btn').forEach((b) => b.classList.toggle('active', b.dataset.backend === 'fpm'));
    $('#phpLabel').style.opacity = '1';
    $('#fPhp').disabled = false;
    modal.classList.remove('hidden');
  });
  $('#btnCloseModal').addEventListener('click', () => modal.classList.add('hidden'));
  modal.addEventListener('click', (e) => { if (e.target === modal) modal.classList.add('hidden'); });
  $$('.seg-btn').forEach((b) => b.addEventListener('click', () => {
    $$('.seg-btn').forEach((x) => x.classList.toggle('active', x === b));
    const rr = b.dataset.backend === 'roadrunner';
    $('#fBackend').value = b.dataset.backend;
    $('#phpLabel').style.opacity = rr ? '.4' : '1';
    $('#fPhp').disabled = rr;
  }));

  $('#vhostForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
      const r = await api('/api/vhost/create', {
        method: 'POST',
        body: JSON.stringify({
          domain: $('#fDomain').value.trim(),
          folder: $('#fFolder').value.trim(),
          backend: $('#fBackend').value,
          php: $('#fPhp').value,
          laravel: $('#fLaravel').checked,
        }),
      });
      modal.classList.add('hidden');
      toast('Vhost creado', r.output, r.ok ? '' : 'err');
      load();
    } catch (err) { toast('Error', err.message, 'err'); }
  });

  /* ---------------- load + autofresh ---------------- */
  async function load() {
    try {
      DATA = await api('/api/overview');
      renderServices(DATA.services);
      renderVersions(DATA.versions);
      renderVhosts(DATA.vhosts);
      renderWww(DATA.www);
      renderUtils(DATA.utilities);
      renderCommands(DATA.commands);
      renderSystem(DATA.system);
      $('#main').classList.remove('hidden');
      $('#login').classList.add('hidden');
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(load, 20000);
    } catch (err) {
      if (err.message === 'no_auth') showLogin();
    }
  }

  load();
})();
_BEOF_APPJS
    render_file "webpanel/router.php" 644 <<'_BEOF_ROUTER'
<?php
/**
 * ============================================================
 *  BEARWSL — Panel web de administración (PHP built-in server)
 *
 *  Ejecutar:  php -S 0.0.0.0:8088 webpanel/router.php
 *  systemd:   systemctl start bearwsl-panel
 *  URL:       http://panel.bearwsl.test  o  http://127.0.0.1:8088
 * ============================================================
 */

declare(strict_types=1);

error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');

$HOME       = (string) (getenv('HOME') ?: ($_SERVER['HOME'] ?? '/home/dev'));
$BEARWSL    = rtrim((string) (getenv('BEARWSL_DIR') ?: "$HOME/bearwsl"), '/');
$CONFIG     = rtrim((string) (getenv('BEARWSL_CONFIG_DIR') ?: "$HOME/.config/bearwsl"), '/');
$TOKEN_FILE = "$CONFIG/panel_token";
$NGINX_DIR  = rtrim((string) (getenv('NGINX_DIR') ?: '/etc/nginx'), '/');
$WWW        = getenv('WWW_DIR') ?: '/var/www';
$COMPOSE    = "cd " . escapeshellarg($BEARWSL) . " && docker compose";
$NATIVE_MAP = [
    'php74' => 'php7.4-fpm', 'php84' => 'php8.4-fpm', 'php85' => 'php8.5-fpm',
    'mariadb10' => 'mariadb', 'mariadb11' => 'mariadb',
    'postgres15' => 'postgresql@15-main', 'postgres17' => 'postgresql@17-main',
];

session_set_cookie_params(['lifetime' => 0, 'path' => '/', 'httponly' => true, 'samesite' => 'Lax']);
session_name('bearwsl_panel');
session_start();

$uri    = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

/* ------------------------------------------------------------------ */
/*  Helpers                                                            */
/* ------------------------------------------------------------------ */

function json_out(array $data, int $code = 200): void
{
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/** Ejecuta un comando de shell y devuelve [stdout+stderr, exitcode]. */
function sh(string $cmd): array
{
    $out = [];
    $code = 0;
    exec($cmd . ' 2>&1', $out, $code);
    return [implode("\n", $out), $code];
}

function token_value(): string
{
    global $TOKEN_FILE, $CONFIG;
    if (is_file($TOKEN_FILE)) {
        $t = trim((string) file_get_contents($TOKEN_FILE));
        if ($t !== '') {
            return $t;
        }
    }
    @mkdir($CONFIG, 0700, true);
    $t = bin2hex(random_bytes(16));
    @file_put_contents($TOKEN_FILE, $t . "\n");
    @chmod($TOKEN_FILE, 0600);
    return $t;
}

function authed(): bool
{
    if (($_SESSION['authed'] ?? false) === true) {
        return true;
    }
    $t = (string) ($_GET['token'] ?? '');
    return $t !== '' && hash_equals(token_value(), $t);
}

function need_auth(): void
{
    if (!authed()) {
        json_out(['ok' => false, 'error' => 'no_auth', 'message' => 'No autenticado. Ingresa el token del panel.'], 401);
    }
}

function post_json(): array
{
    $raw = (string) file_get_contents('php://input');
    $d = json_decode($raw, true);
    return is_array($d) ? $d : [];
}

function compose_ps_rows(): array
{
    global $COMPOSE;
    [$out] = sh($COMPOSE . ' ps -a --format json');
    $rows = [];
    foreach (explode("\n", trim($out)) as $line) {
        $line = trim($line);
        if ($line === '') {
            continue;
        }
        $d = json_decode($line, true);
        if (is_array($d)) {
            $rows[] = $d;
        }
    }
    return $rows;
}

function docker_exec(string $container, string $cmdline): string
{
    [$out, $code] = sh('docker exec ' . escapeshellarg($container) . ' ' . $cmdline . ' 2>&1');
    return $code === 0 ? trim($out) : '';
}

function load_env(): array
{
    global $BEARWSL;
    $env = ['PHP_CURRENT' => 'php85', 'DB_CURRENT' => 'mariadb11', 'PG_CURRENT' => 'postgres17', 'NODE_CURRENT' => '22', 'PHP_MODE' => 'container', 'DB_MODE' => 'container', 'PG_MODE' => 'container'];
    $f = "$BEARWSL/.env";
    if (is_file($f)) {
        foreach (file($f, FILE_IGNORE_NEW_LINES) as $line) {
            if (str_contains($line, '=')) {
                [$k, $v] = explode('=', $line, 2);
                $env[trim($k)] = trim($v);
            }
        }
    }
    $env['PHP_MODE'] = ($env['PHP_MODE'] ?? '') !== '' ? $env['PHP_MODE'] : 'container';
    $env['DB_MODE'] = ($env['DB_MODE'] ?? '') !== '' ? $env['DB_MODE'] : 'container';
    $env['PG_MODE'] = ($env['PG_MODE'] ?? '') !== '' ? $env['PG_MODE'] : 'container';
    return $env;
}

function save_env(array $env): bool
{
    global $BEARWSL;
    $content = "PHP_CURRENT={$env['PHP_CURRENT']}\nDB_CURRENT={$env['DB_CURRENT']}\nPG_CURRENT={$env['PG_CURRENT']}\nNODE_CURRENT={$env['NODE_CURRENT']}\nPHP_MODE={$env['PHP_MODE']}\nDB_MODE={$env['DB_MODE']}\nPG_MODE={$env['PG_MODE']}\n";
    return @file_put_contents("$BEARWSL/.env", $content) !== false;
}

function sudo_vhost(array $args): array
{
    global $BEARWSL;
    $parts = ['sudo', '-n', escapeshellarg("$BEARWSL/vhost.sh")];
    foreach ($args as $a) {
        $parts[] = escapeshellarg((string) $a);
    }
    [$out, $code] = sh(implode(' ', $parts));
    return [$out, $code];
}

function util_check(string $cmd, string $verFlag): array
{
    [$out, $code] = sh('command -v ' . escapeshellarg($cmd) . ' >/dev/null 2>&1 && ' . $cmd . ' ' . $verFlag . ' 2>&1 | head -1');
    return ['present' => $code === 0, 'version' => $code === 0 ? trim($out) : ''];
}

function util_check_env(string $cmd, string $verFlag, string $envSetup): array
{
    $pre = 'bash -lc ' . escapeshellarg($envSetup . '; command -v ' . $cmd . ' >/dev/null 2>&1 && ' . $cmd . ' ' . $verFlag . ' 2>&1 | head -1');
    [$out, $code] = sh($pre);
    return ['present' => $code === 0, 'version' => $code === 0 ? trim($out) : ''];
}

/* ------------------------------------------------------------------ */
/*  Estáticos (index.html, style.css, app.js, favicon)                 */
/* ------------------------------------------------------------------ */

$staticMap = [
    '/'             => 'index.html',
    '/index.html'   => 'index.html',
    '/style.css'    => 'style.css',
    '/app.js'       => 'app.js',
    '/favicon.svg'  => 'favicon.svg',
];

if ($method === 'GET' && isset($staticMap[$uri])) {
    $file = __DIR__ . '/' . $staticMap[$uri];
    if (is_file($file)) {
        $mime = match (pathinfo($file, PATHINFO_EXTENSION)) {
            'css' => 'text/css',
            'js' => 'application/javascript',
            'svg' => 'image/svg+xml',
            default => 'text/html; charset=utf-8',
        };
        header('Content-Type: ' . $mime);
        header('Content-Length: ' . (string) filesize($file));
        readfile($file);
        exit;
    }
    json_out(['ok' => false, 'error' => 'not_found'], 404);
}

/* ------------------------------------------------------------------ */
/*  API                                                                */
/* ------------------------------------------------------------------ */

if (!str_starts_with($uri, '/api/')) {
    json_out(['ok' => false, 'error' => 'not_found'], 404);
}

$route = substr($uri, 5); // quitar "/api/"

/* ---- ping (sin auth, usado por panel.sh --panel status) ---- */
if ($route === 'ping' && $method === 'GET') {
    json_out(['ok' => true, 'service' => 'bearwsl-panel', 'time' => date('c')]);
}

/* ---- login / logout ---- */
if ($route === 'login' && $method === 'POST') {
    $d = post_json();
    $t = (string) ($d['token'] ?? '');
    if ($t !== '' && hash_equals(token_value(), $t)) {
        $_SESSION['authed'] = true;
        json_out(['ok' => true]);
    }
    json_out(['ok' => false, 'error' => 'bad_token'], 401);
}

if ($route === 'logout' && $method === 'POST') {
    $_SESSION['authed'] = false;
    session_destroy();
    json_out(['ok' => true]);
}

/* ---- token (authed) ---- */
if ($route === 'token' && $method === 'GET') {
    need_auth();
    json_out(['ok' => true, 'token' => token_value()]);
}

/* ---- overview ---- */
if ($route === 'overview' && $method === 'GET') {
    need_auth();

    $env = load_env();

    // Servicios docker (compose ps)
    $services = [];
    foreach (compose_ps_rows() as $r) {
        $status = (string) ($r['Status'] ?? '');
        $health = '';
        if (str_contains($status, 'healthy')) {
            $health = 'healthy';
        } elseif (str_contains($status, 'unhealthy')) {
            $health = 'unhealthy';
        } elseif (str_contains($status, '(health')) {
            $health = 'starting';
        }
        // El formato JSON de compose también expone el campo Health
        if ($health === '' && !empty($r['Health'])) {
            $health = (string) $r['Health'];
        }
        $services[] = [
            'service' => (string) ($r['Service'] ?? ''),
            'name'    => (string) ($r['Name'] ?? ''),
            'image'   => (string) ($r['Image'] ?? ''),
            'state'   => (string) ($r['State'] ?? ''),
            'status'  => $status,
            'health'  => $health,
        ];
    }
    usort($services, static fn ($a, $b) => strcmp($a['service'], $b['service']));

    // Servicios nativos (systemd) — se añaden según el modo de cada familia
    $nativeMap = [
        'php74'      => ['unit' => 'php7.4-fpm',        'mode' => $env['PHP_MODE'] ?? 'container'],
        'php84'      => ['unit' => 'php8.4-fpm',        'mode' => $env['PHP_MODE'] ?? 'container'],
        'php85'      => ['unit' => 'php8.5-fpm',        'mode' => $env['PHP_MODE'] ?? 'container'],
        'mariadb10'  => ['unit' => 'mariadb',           'mode' => $env['DB_MODE'] ?? 'container'],
        'mariadb11'  => ['unit' => 'mariadb',           'mode' => $env['DB_MODE'] ?? 'container'],
        'postgres15' => ['unit' => 'postgresql@15-main', 'mode' => $env['PG_MODE'] ?? 'container'],
        'postgres17' => ['unit' => 'postgresql@17-main', 'mode' => $env['PG_MODE'] ?? 'container'],
    ];
    $known = array_column($services, 'service');
    foreach ($nativeMap as $svc => $info) {
        if (($info['mode'] ?? 'container') !== 'native' || in_array($svc, $known, true)) {
            continue;
        }
        [$st] = sh('systemctl is-active ' . escapeshellarg($info['unit']) . ' 2>/dev/null');
        $active = trim($st) === 'active';
        $services[] = [
            'service' => $svc,
            'name'    => $svc,
            'image'   => 'native',
            'state'   => $active ? 'running' : 'inactive',
            'status'  => $active ? 'Up (native)' : 'down (native)',
            'health'  => $active ? 'native' : '',
        ];
    }
    usort($services, static fn ($a, $b) => strcmp($a['service'], $b['service']));

    // Versiones (respeta el modo container/native por familia)
    $phpNativeMode = ($env['PHP_MODE'] ?? 'container') === 'native';
    $phpVersions = [];
    foreach (['php74' => 'php7.4', 'php84' => 'php8.4', 'php85' => 'php8.5'] as $svc => $pkg) {
        $running = false;
        $version = '';
        if ($phpNativeMode) {
            [$st] = sh('systemctl is-active ' . escapeshellarg($pkg . '-fpm') . ' 2>/dev/null');
            $running = trim($st) === 'active';
            if ($running) {
                [$vv] = sh(escapeshellarg($pkg) . " -r 'echo PHP_VERSION;' 2>/dev/null");
                $version = trim($vv);
            }
        } else {
            foreach ($services as $s) {
                if ($s['service'] === $svc && str_contains($s['status'], 'Up')) {
                    $running = true;
                }
            }
            $version = $running ? docker_exec('b-' . $svc, "php -r 'echo PHP_VERSION;'") : '';
        }
        $phpVersions[$svc] = ['running' => $running, 'version' => $version];
    }

    $dbSvc = $env['DB_CURRENT'] ?: 'mariadb11';
    $pgSvc = $env['PG_CURRENT'] ?: 'postgres17';
    $maria = $pg = $redis = $rr = '';
    if (($env['DB_MODE'] ?? 'container') === 'native') {
        [$mariaOut] = sh('mariadb --version 2>/dev/null');
        $maria = trim($mariaOut);
    }
    if (($env['PG_MODE'] ?? 'container') === 'native') {
        $pgMajor = str_replace('postgres', '', $pgSvc);
        [$pgOut] = sh('/usr/lib/postgresql/' . $pgMajor . '/bin/postgres --version 2>/dev/null');
        $pg = trim($pgOut);
    }
    foreach ($services as $s) {
        if (($env['DB_MODE'] ?? 'container') === 'container' && $s['service'] === $dbSvc && str_contains($s['status'], 'Up')) {
            $maria = docker_exec('b-' . $dbSvc, 'mariadb --version 2>&1');
        } elseif (($env['PG_MODE'] ?? 'container') === 'container' && $s['service'] === $pgSvc && str_contains($s['status'], 'Up')) {
            $pg = docker_exec('b-' . $pgSvc, 'postgres --version');
        } elseif ($s['service'] === 'redis' && str_contains($s['status'], 'Up')) {
            $redis = docker_exec('b-redis', 'redis-server --version');
        } elseif ($s['service'] === 'roadrunner' && str_contains($s['status'], 'Up')) {
            $rr = docker_exec('b-roadrunner', 'rr --version 2>&1');
        }
    }
    if ($rr === '') {
        [$rrOut] = sh('rr --version 2>&1');
        $rr = trim($rrOut);
    }

    [$nginxOut] = sh('nginx -v 2>&1');
    [$dockerOut] = sh('docker --version 2>&1');
    [$composeOut] = sh('docker compose version 2>&1');
    [$phpNative] = sh("php -r 'echo PHP_VERSION;' 2>&1");

    // Node (fnm)
    $nodeVersions = [];
    [$fnmOut] = sh('bash -lc \'export PATH="$HOME/.local/share/fnm:$PATH"; if command -v fnm >/dev/null 2>&1; then fnm ls; else echo "fnm:not-installed"; fi\'');
    foreach (preg_split('/\r?\n/', trim($fnmOut)) as $line) {
        $line = trim($line);
        if ($line === '' || $line === 'fnm:not-installed') {
            continue;
        }
        $parts = preg_split('/\s+/', $line);
        $nodeVersions[] = ['version' => $parts[0] ?? $line, 'default' => in_array('default', $parts, true) || str_contains($line, '*')];
    }
    [$nodeCur] = sh('bash -lc \'export PATH="$HOME/.local/share/fnm:$PATH"; node --version 2>/dev/null\'');
    $nodeCur = trim($nodeCur);

    // Utilidades
    $utilities = [
        'docker'   => util_check('docker', '--version'),
        'docker compose' => util_check('docker', 'compose version'),
        'git'      => util_check('git', '--version'),
        'curl'     => util_check('curl', '--version'),
        'composer' => util_check('composer', '--version'),
        'php'      => util_check('php', '-v'),
        'fnm'      => util_check_env('fnm', '--version', 'export PATH="$HOME/.local/share/fnm:$PATH"'),
        'node'     => util_check_env('node', '--version', 'export PATH="$HOME/.local/share/fnm:$PATH"; eval "$("$HOME/.local/share/fnm/fnm" env --shell bash 2>/dev/null)"'),
        'npm'      => util_check_env('npm', '--version', 'export PATH="$HOME/.local/share/fnm:$PATH"; eval "$("$HOME/.local/share/fnm/fnm" env --shell bash 2>/dev/null)"'),
        'nginx'    => util_check('nginx', '-v'),
        'python3'  => util_check('python3', '--version'),
        'rr'       => util_check('rr', '--version'),
        'redis-cli' => util_check('redis-cli', '--version'),
        'mysql'    => util_check('mysql', '--version'),
    ];

    // Vhosts
    $vhosts = [];
    $avail = "$NGINX_DIR/sites-available";
    $enabled = "$NGINX_DIR/sites-enabled";
    if (is_dir($avail)) {
        foreach (scandir($avail) as $f) {
            if ($f === '.' || $f === '..') {
                continue;
            }
            $conf = "$avail/$f";
            if (!is_file($conf)) {
                continue;
            }
            $txt = (string) file_get_contents($conf);
            $root = '';
            if (preg_match('/^\s*root\s+(.+?);/m', $txt, $m)) {
                $root = trim($m[1]);
            }
            $backend = 'fpm';
            $port = '9000';
            if (str_contains($txt, 'proxy_pass http://127.0.0.1:8080')) {
                $backend = 'roadrunner';
                $port = '8080';
            } elseif (preg_match('/fastcgi_pass\s+127\.0\.0\.1:(\d+)/', $txt, $m)) {
                $port = $m[1];
            }
            $vhosts[] = [
                'domain'  => $f,
                'root'    => $root,
                'backend' => $backend,
                'port'    => $port,
                'enabled' => is_link("$enabled/$f"),
            ];
        }
        usort($vhosts, static fn ($a, $b) => strcmp($a['domain'], $b['domain']));
    }

    // Directorios de /var/www
    $www = [];
    if (is_dir($WWW)) {
        foreach (scandir($WWW) as $f) {
            if ($f === '.' || $f === '..' || str_starts_with($f, '.')) {
                continue;
            }
            if (!is_dir("$WWW/$f")) {
                continue;
            }
            // enlace: vhost que apunte a esta carpeta, si no → autoindex bearwsl.test
            $link = "http://bearwsl.test/$f/";
            foreach ($vhosts as $v) {
                if (str_starts_with($v['root'], "$WWW/$f")) {
                    $link = "http://{$v['domain']}";
                    break;
                }
            }
            $www[] = ['name' => $f, 'path' => "$WWW/$f", 'link' => $link];
        }
        usort($www, static fn ($a, $b) => strcmp($a['name'], $b['name']));
    }

    // Comandos disponibles
    $commands = [
        ['cmd' => 'panel.sh', 'desc' => 'Panel de control interactivo + CLI del stack'],
        ['cmd' => 'panel.sh --status', 'desc' => 'Estado de todos los servicios (con salud)'],
        ['cmd' => 'panel.sh --logs php85', 'desc' => 'Logs en vivo de un servicio'],
        ['cmd' => 'panel.sh --switch php php84', 'desc' => 'Cambiar la versión actual de PHP'],
        ['cmd' => 'panel.sh --switch db mariadb10', 'desc' => 'Cambiar la versión actual de MariaDB'],
        ['cmd' => 'panel.sh --health', 'desc' => 'Health check completo del stack'],
        ['cmd' => 'vhost.sh create --domain api.test --folder api --backend fpm', 'desc' => 'Crear vhost con ruta PHP-FPM'],
        ['cmd' => 'vhost.sh create --domain app.test --folder app --backend roadrunner --laravel', 'desc' => 'Crear vhost con ruta RoadRunner'],
        ['cmd' => 'vhost.sh list', 'desc' => 'Listar virtual hosts'],
        ['cmd' => 'vhost.sh enable mi.test', 'desc' => 'Habilitar un vhost'],
        ['cmd' => 'vhost.sh delete mi.test', 'desc' => 'Eliminar un vhost (no borra la carpeta)'],
        ['cmd' => 'docker compose ps', 'desc' => 'Estado de los contenedores'],
        ['cmd' => 'docker compose logs -f php85', 'desc' => 'Logs en vivo de un contenedor'],
        ['cmd' => 'docker exec -it b-php85 bash', 'desc' => 'Terminal dentro del contenedor PHP'],
        ['cmd' => 'rr serve -c /var/www/mi-app/.rr.yaml', 'desc' => 'RoadRunner local con el binario nativo'],
    ];

    // Sistema
    [$host] = sh('hostname');
    [$ip] = sh("hostname -I 2>/dev/null | awk '{print \$1}'");
    [$uptime] = sh('uptime -p 2>/dev/null');
    [$disk] = sh('df -h ' . escapeshellarg($WWW) . ' 2>/dev/null | tail -1');
    [$mem] = sh('free -h 2>/dev/null | awk \'NR==2{print $3"/"$2}\'');

    json_out([
        'ok' => true,
        'env' => $env,
        'services' => $services,
        'versions' => [
            'php' => $phpVersions,
            'mariadb' => $maria,
            'postgres' => $pg,
            'redis' => $redis,
            'roadrunner' => $rr,
            'node' => ['current' => $nodeCur, 'versions' => $nodeVersions],
            'nginx' => trim($nginxOut),
            'docker' => trim($dockerOut),
            'compose' => trim($composeOut),
            'php_native' => trim($phpNative),
        ],
        'utilities' => $utilities,
        'vhosts' => $vhosts,
        'www' => $www,
        'commands' => $commands,
        'system' => [
            'hostname' => trim($host),
            'ip' => trim($ip),
            'uptime' => trim($uptime),
            'disk' => trim($disk),
            'mem' => trim($mem),
        ],
        'config' => ['bearwsl_dir' => $BEARWSL, 'nginx_dir' => $NGINX_DIR, 'www' => $WWW],
        'modes' => ['php' => $env['PHP_MODE'], 'db' => $env['DB_MODE'], 'pg' => $env['PG_MODE']],
    ]);
}

/* ---- logs ---- */
if ($route === 'logs' && $method === 'GET') {
    need_auth();
    $svc = (string) ($_GET['service'] ?? 'php85');
    $lines = max(20, min(2000, (int) ($_GET['lines'] ?? 200)));
    if (!preg_match('/^[a-z0-9_]+$/', $svc)) {
        json_out(['ok' => false, 'error' => 'bad_service'], 400);
    }
    global $COMPOSE;
    [$out, $code] = sh($COMPOSE . ' logs --tail=' . $lines . ' ' . escapeshellarg($svc) . ' 2>&1');
    json_out(['ok' => $code === 0, 'service' => $svc, 'logs' => $out]);
}

/* ---- stack ---- */
if ($route === 'stack' && $method === 'POST') {
    need_auth();
    $d = post_json();
    $action = (string) ($d['action'] ?? '');
    $env = load_env();
    $families = ['php' => $env['PHP_CURRENT'], 'db' => $env['DB_CURRENT'], 'pg' => $env['PG_CURRENT']];
    $modes = ['php' => $env['PHP_MODE'], 'db' => $env['DB_MODE'], 'pg' => $env['PG_MODE']];
    global $COMPOSE;
    $dockerSvcs = [];
    $nativeStart = [];
    $nativeStop = [];
    foreach ($families as $f => $svc) {
        if (($modes[$f] ?? 'container') === 'native' && isset($NATIVE_MAP[$svc])) {
            $nativeStart[] = 'sudo -n systemctl start ' . escapeshellarg($NATIVE_MAP[$svc]);
            $nativeStop[] = 'sudo -n systemctl stop ' . escapeshellarg($NATIVE_MAP[$svc]);
        } else {
            $dockerSvcs[] = $svc;
        }
    }
    $dockerSvcs = array_merge($dockerSvcs, ['redis', 'mailpit', 'roadrunner']);
    $dockerStr = implode(' ', $dockerSvcs);
    $cmd = match ($action) {
        'up' => implode(' && ', array_merge($nativeStart, [$COMPOSE . ' up -d ' . $dockerStr])),
        'down' => implode(' && ', array_merge([$COMPOSE . ' stop ' . $dockerStr], $nativeStop)),
        'restart' => implode(' && ', array_merge(
            $nativeStop,
            [$COMPOSE . ' stop ' . $dockerStr . ' 2>/dev/null || true'],
            $nativeStart,
            [$COMPOSE . ' up -d ' . $dockerStr]
        )),
        default => null,
    };
    if ($cmd === null) {
        json_out(['ok' => false, 'error' => 'bad_action'], 400);
    }
    [$out, $code] = sh($cmd);
    json_out(['ok' => $code === 0, 'output' => $out]);
}

/* ---- servicio individual ---- */
if ($route === 'service' && $method === 'POST') {
    need_auth();
    $d = post_json();
    $svc = (string) ($d['service'] ?? '');
    $action = (string) ($d['action'] ?? '');
    if (!preg_match('/^[a-z0-9_]+$/', $svc) || !in_array($action, ['start', 'stop', 'restart'], true)) {
        json_out(['ok' => false, 'error' => 'bad_request'], 400);
    }
    global $COMPOSE;
    [$out, $code] = sh($COMPOSE . ' ' . $action . ' ' . escapeshellarg($svc) . ' 2>&1');
    json_out(['ok' => $code === 0, 'output' => $out]);
}

/* ---- cambiar versión (php|db|pg) ---- */
if ($route === 'switch' && $method === 'POST') {
    need_auth();
    $d = post_json();
    $family = (string) ($d['family'] ?? '');
    $version = (string) ($d['version'] ?? '');
    $defs = [
        'php' => ['key' => 'PHP_CURRENT', 'modeKey' => 'PHP_MODE', 'members' => ['php74', 'php84', 'php85']],
        'db'  => ['key' => 'DB_CURRENT', 'modeKey' => 'DB_MODE', 'members' => ['mariadb10', 'mariadb11']],
        'pg'  => ['key' => 'PG_CURRENT', 'modeKey' => 'PG_MODE', 'members' => ['postgres15', 'postgres17']],
    ];
    if (!isset($defs[$family]) || !in_array($version, $defs[$family]['members'], true)) {
        json_out(['ok' => false, 'error' => 'bad_request'], 400);
    }
    $env = load_env();
    $env[$defs[$family]['key']] = $version;
    save_env($env);

    global $COMPOSE;
    $cmds = [];
    if (($env[$defs[$family]['modeKey']] ?? 'container') === 'native') {
        // modo nativo: gestiona servicios systemd (sudo -n, configurado por install.sh)
        foreach ($defs[$family]['members'] as $m) {
            if ($m !== $version && isset($NATIVE_MAP[$m])) {
                $cmds[] = 'sudo -n systemctl stop ' . escapeshellarg($NATIVE_MAP[$m]);
            }
        }
        $cmds[] = 'sudo -n systemctl start ' . escapeshellarg($NATIVE_MAP[$version]);
    } else {
        foreach ($defs[$family]['members'] as $m) {
            if ($m !== $version) {
                $cmds[] = $COMPOSE . ' stop ' . $m;
            }
        }
        $cmds[] = $COMPOSE . ' up -d ' . $version;
    }
    [$out, $code] = sh(implode(' && ', $cmds) . ' 2>&1');
    json_out(['ok' => $code === 0, 'output' => $out, 'env' => $env]);
}

/* ---- vhost: create ---- */
if ($route === 'vhost/create' && $method === 'POST') {
    need_auth();
    $d = post_json();
    $domain = trim((string) ($d['domain'] ?? ''));
    $folder = trim((string) ($d['folder'] ?? ''));
    $backend = (string) ($d['backend'] ?? 'fpm') === 'roadrunner' ? 'roadrunner' : 'fpm';
    $php = (string) ($d['php'] ?? '');
    $laravel = !empty($d['laravel']);

    if (!preg_match('/^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$/', $domain) || str_contains($domain, '..')) {
        json_out(['ok' => false, 'error' => 'bad_domain'], 400);
    }
    if ($folder === '' || str_starts_with($folder, '.') || str_contains($folder, '..') || str_starts_with($folder, '/')) {
        json_out(['ok' => false, 'error' => 'bad_folder'], 400);
    }

    $args = ['create', '--domain', $domain, '--folder', $folder, '--backend', $backend];
    if ($backend === 'fpm' && in_array($php, ['php74', 'php84', 'php85'], true)) {
        $args[] = '--php';
        $args[] = $php;
    }
    if ($laravel) {
        $args[] = '--laravel';
    }
    [$out, $code] = sudo_vhost($args);
    json_out(['ok' => $code === 0, 'output' => $out, 'code' => $code]);
}

/* ---- vhost: enable / disable ---- */
if (($route === 'vhost/enable' || $route === 'vhost/disable') && $method === 'POST') {
    need_auth();
    $d = post_json();
    $domain = trim((string) ($d['domain'] ?? ''));
    if (!preg_match('/^[a-zA-Z0-9._-]+$/', $domain)) {
        json_out(['ok' => false, 'error' => 'bad_domain'], 400);
    }
    $action = $route === 'vhost/enable' ? 'enable' : 'disable';
    [$out, $code] = sudo_vhost([$action, $domain]);
    json_out(['ok' => $code === 0, 'output' => $out, 'code' => $code]);
}

/* ---- vhost: delete ---- */
if ($route === 'vhost/delete' && $method === 'POST') {
    need_auth();
    $d = post_json();
    $domain = trim((string) ($d['domain'] ?? ''));
    if (!preg_match('/^[a-zA-Z0-9._-]+$/', $domain)) {
        json_out(['ok' => false, 'error' => 'bad_domain'], 400);
    }
    [$out, $code] = sudo_vhost(['delete', $domain, '--force']);
    json_out(['ok' => $code === 0, 'output' => $out, 'code' => $code]);
}

json_out(['ok' => false, 'error' => 'not_found'], 404);
_BEOF_ROUTER
    render_file "webpanel/favicon.svg" 644 <<'_BEOF_FAVICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#34d399"/><stop offset="1" stop-color="#38bdf8"/>
    </linearGradient>
  </defs>
  <rect width="32" height="32" rx="7" fill="url(#g)"/>
  <text x="16" y="22" font-size="18" text-anchor="middle">🐻</text>
</svg>
_BEOF_FAVICON
}

if [ "$SYNC_FILES" = "1" ]; then
    gen_stack_files
    if [ "$GEN_ERR" = "1" ]; then
        echo "ERROR — no se pudieron escribir algunos archivos en $BEARWSL_DIR"
        exit 1
    fi
    echo "OK — archivos del stack listos en $BEARWSL_DIR"
    exit 0
fi

gen_stack_files || true

cd "$BEARWSL_DIR" || { fail "No se pudo acceder a $BEARWSL_DIR"; exit 1; }
# shellcheck source=scripts/helpers.sh
if ! source "$BEARWSL_DIR/scripts/helpers.sh" 2>/dev/null; then
    if [ "$DRY_RUN" = "1" ]; then
        warn "[dry-run] scripts/helpers.sh aún no existe; se generará en la instalación real."
    else
        fail "No se pudo generar scripts/helpers.sh en $BEARWSL_DIR"; exit 1
    fi
fi

ask_yes() { # ask_yes "pregunta" "default(s|n)" — pregunta a stderr, respuesta por exit code
    local q="$1" d="${2:-s}"
    [ "$YES" = "1" ] && { printf '%s [%s]\n' "$q" "$d" >&2; return 0; }
    local r
    while true; do
        echo -n "$q [${d^^}/${d,,}]: " >&2; read -r r
        case "${r:-$d}" in [Ss]) return 0 ;; [Nn]) return 1 ;; *) echo "Responde s o n." >&2 ;; esac
    done
}

ask_list() { # ask_list "pregunta" "opciones por defecto" — pregunta a stderr, SOLO la respuesta a stdout
    local q="$1" def="$2" sep="${3:- }"
    [ "$YES" = "1" ] && { printf '%s [%s]\n' "$q" "$def" >&2; echo "$def"; return 0; }
    echo -n "$q [$def]: " >&2; read -r r
    [ -z "$r" ] && r="$def"
    echo "$r" | tr "$sep" " "
}

ask_mode() { # pregunta 1/2/3 (docker/nativo/híbrido)
    if [ -n "$MODE_CHOICE" ]; then
        printf 'Modo de servicios: %s\n' "$MODE_CHOICE" >&2
        echo "$MODE_CHOICE"; return
    fi
    [ "$YES" = "1" ] && { echo "1"; return; }
    echo "¿Cómo quieres ejecutar los servicios (PHP, MariaDB, Postgres)?" >&2
    echo "  [1] Dockerizado (recomendado) — contenedores multi-versión" >&2
    echo "  [2] Nativo (apt + systemd) — sin contenedores para los servicios" >&2
    echo "  [3] Híbrido — preguntar por cada familia" >&2
    local r
    echo -n "Selecciona [1]: " >&2; read -r r
    echo "${r:-1}"
}

map_service() { # 7.4 → php74 | 10.11 → mariadb10 | 15 → postgres15
    case "$1" in
        7.4) echo php74 ;; 8.4) echo php84 ;; 8.5) echo php85 ;;
        10.11) echo mariadb10 ;; 11.4) echo mariadb11 ;;
        15) echo postgres15 ;; 17) echo postgres17 ;;
    esac
}

# ============================================================
#  0) DETECCIÓN DEL ENTORNO
# ============================================================
echo; hr
printf '              🟢  %sINSTALADOR BEARWSL%s  🟢\n' "$BOLD" "$RESET"
hr

if grep -qi microsoft /proc/version 2>/dev/null; then
    WSL=1; info "WSL detectado (WSL2)."
else
    WSL=0; info "Linux nativo (${YELLOW}$(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')${RESET})."
fi

if command -v apt-get >/dev/null 2>&1; then PKG="apt"; elif command -v dnf >/dev/null 2>&1; then PKG="dnf"; else PKG=""; fi
[ -z "$PKG" ] && { fail "Solo soportamos Debian/Ubuntu (apt) por ahora. Aborta."; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in x86_64) RR_ARCH=amd64 ;; aarch64) RR_ARCH=arm64 ;; *) fail "Arquitectura no soportada: $ARCH"; exit 1 ;; esac
info "Arquitectura: $ARCH → roadrunner-$RR_ARCH"

if ps -p 1 -o comm= 2>/dev/null | grep -q systemd; then HAS_SYSTEMD=1; else HAS_SYSTEMD=0; fi

if ! curl -fsS --max-time 10 https://api.github.com >/dev/null 2>&1; then
    warn "Sin acceso a internet (GitHub). Revisa:"
    warn "  · DNS:          sudo sh -c 'echo nameserver 8.8.8.8 > /etc/resolv.conf'"
    warn "  · Proxy:        export https_proxy=http://proxy:puerto"
    ask_yes "¿Continuar igualmente?" "n" || exit 1
fi

if [ "$WSL" = "1" ]; then
    if [ "$(date +%s)" -lt 1700000000 ] 2>/dev/null; then
        warn "Reloj de WSL desincronizado. Corrigiendo…"
        run --sudo hwclock -s 2>/dev/null || warn "No se pudo sincronizar el reloj (hwclock)."
    fi
fi

# ============================================================
#  1) PREGUNTAS DE INSTALACIÓN
# ============================================================
echo; hr; printf '   %sCONFIGURACIÓN%s\n' "$BOLD" "$RESET"; hr
ensure_sudo

# --- cargar versiones actuales si ya hay .env (los MODOS siempre los decide la pregunta) ---
if [ -f "$ENV_FILE" ]; then
    command -v load_env >/dev/null 2>&1 && load_env
fi

# --- modo de servicios (docker / nativo / híbrido) ---
MC=$(ask_mode)
case "$MC" in
    2|native) PHP_MODE="native"; DB_MODE="native"; PG_MODE="native" ;;
    3|hybrid)
        echo " — Híbrido: pregunta por familia —" >&2
        if [ "$YES" = "1" ]; then
            PHP_MODE="container"; DB_MODE="container"; PG_MODE="container"
        else
            r3=""
            echo -n "PHP:      [1] Docker [2] Nativo [1]: " >&2; read -r r3; [ "${r3:-1}" = "2" ] && PHP_MODE="native" || PHP_MODE="container"
            echo -n "MariaDB:  [1] Docker [2] Nativo [1]: " >&2; read -r r3; [ "${r3:-1}" = "2" ] && DB_MODE="native" || DB_MODE="container"
            echo -n "Postgres: [1] Docker [2] Nativo [1]: " >&2; read -r r3; [ "${r3:-1}" = "2" ] && PG_MODE="native" || PG_MODE="container"
        fi
        ;;
    1|container|*) PHP_MODE="container"; DB_MODE="container"; PG_MODE="container" ;;
esac

ALL_NATIVE=0
[ "$PHP_MODE" = "native" ] && [ "$DB_MODE" = "native" ] && [ "$PG_MODE" = "native" ] && ALL_NATIVE=1

if command -v docker >/dev/null 2>&1; then HAVE_DOCKER=1; else HAVE_DOCKER=0; fi
if command -v nginx >/dev/null 2>&1; then HAVE_NGINX=1; else HAVE_NGINX=0; fi

DOCKER_DEF="s"; [ "$ALL_NATIVE" = "1" ] && DOCKER_DEF="n"
ask_yes "¿Instalar/verificar Docker Engine + Compose?" "$DOCKER_DEF" && DO_DOCKER=1 || DO_DOCKER=0
ask_yes "¿Instalar/verificar nginx (para los vhosts)?" "s" && DO_NGINX=1 || DO_NGINX=0

PHP_CHOICES=$(ask_list "Versiones de PHP a incluir (separadas por espacio):" "7.4 8.4 8.5")
DB_CHOICES=$(ask_list  "Versiones de MariaDB (10.11 11.4):" "10.11 11.4")
PG_CHOICES=$(ask_list  "Versiones de Postgres (15 17):" "15 17")
ask_yes "¿Instalar Node.js vía fnm (gestor de versiones)?" "s" && DO_FNM=1 || DO_FNM=0
[ "$DO_FNM" = "1" ] && NODE_VER=$(ask_list "Versión de Node por defecto:" "22" | tr -d ' ')

DO_UTILS=0
if [ "$DO_DOCKER" = "1" ]; then
    ask_yes "¿Incluir Redis + Mailpit (contenedores)?" "s" && DO_UTILS=1 || DO_UTILS=0
fi

ask_yes "¿Instalar RoadRunner (binario CLI; en modo Docker además el contenedor para la ruta nginx)?" "s" && DO_RR=1 || DO_RR=0
ask_yes "¿Instalar el panel web de administración?" "s" && DO_PANEL=1 || DO_PANEL=0
if [ "$DO_PANEL" = "1" ]; then
    ask_yes "¿Autoiniciar el panel web al arrancar?" "s" && PANEL_AUTOSTART=1 || PANEL_AUTOSTART=0
fi
ask_yes "¿Autoiniciar el stack completo al arrancar el sistema?" "n" && STACK_AUTOSTART=1 || STACK_AUTOSTART=0

# --- versiones actuales + persistir .env (incluye modos) ---
if [ ! -f "$ENV_FILE" ]; then
    PHP_CURRENT=$(map_service "$(echo "$PHP_CHOICES" | awk '{print $NF}')")
    DB_CURRENT=$(map_service "$(echo "$DB_CHOICES" | awk '{print $NF}')")
    PG_CURRENT=$(map_service "$(echo "$PG_CHOICES" | awk '{print $NF}')")
    [ -z "$PHP_CURRENT" ] && PHP_CURRENT=php85
    [ -z "$DB_CURRENT" ] && DB_CURRENT=mariadb11
    [ -z "$PG_CURRENT" ] && PG_CURRENT=postgres17
    NODE_CURRENT="${NODE_VER:-22}"
fi
[ "$DRY_RUN" = "0" ] && save_env

if [ "$DRY_RUN" = "1" ]; then
    echo; hr; printf '   %sPLAN (solo simulación)%s\n' "$BOLD" "$RESET"; hr
    echo "  · Modo servicios : PHP=$PHP_MODE  MariaDB=$DB_MODE  Postgres=$PG_MODE  (todo native → sin contenedores)"
    echo "  · Docker+Compose : $DO_DOCKER   nginx: $DO_NGINX   NO_START: $NO_START"
    echo "  · PHP: $PHP_CHOICES   MariaDB: $DB_CHOICES   Postgres: $PG_CHOICES"
    echo "  · Node/fnm: $DO_FNM (${NODE_VER:-22})   Utilidades(docker): $DO_UTILS   RoadRunner: $DO_RR"
    echo "  · Panel web: $DO_PANEL (autostart: ${PANEL_AUTOSTART:-0})   Stack autostart: ${STACK_AUTOSTART:-0}"
    echo "  · Archivos del stack: se generarán/verificarán (13) en $BEARWSL_DIR (idempotente)"
    hr
    exit 0
fi

# ============================================================
#  2) PAQUETES BASE
# ============================================================
echo; info "Instalando paquetes base (git, curl, ca-certificates, unzip)…"
if [ "$PKG" = "apt" ]; then
    retry 3 run --sudo apt-get update -qq || warn "apt-get update falló tras reintentos (revisa red/permisos)."
    run --sudo apt-get install -y -qq git curl ca-certificates unzip gnupg || warn "No se instalaron todos los paquetes base."
fi

# ============================================================
#  3) DOCKER + COMPOSE (solo si hace falta)
# ============================================================
if [ "$DO_DOCKER" = "1" ]; then
    echo; info "Verificando Docker…"
    if [ "$HAVE_DOCKER" = "0" ]; then
        warn "Docker no está instalado. Instalando con el script oficial…"
        run --sudo sh -c 'curl -fsSL https://get.docker.com | sh'
        run --sudo chmod 644 /etc/apt/sources.list.d/docker.list 2>/dev/null || true
        retry 3 run --sudo apt-get update -qq || warn "apt-get update falló tras reintentos (Docker)."
    else
        ok "Docker ya instalado: $(docker --version 2>/dev/null || echo '?')"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        warn "Plugin docker compose faltante. Instalando…"
        if [ "$PKG" = "apt" ]; then
            run --sudo apt-get install -y -qq docker-compose-plugin || \
                run --sudo sh -c 'curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-'"$ARCH"'" -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose'
        fi
    else
        ok "Compose: $(docker compose version 2>/dev/null | head -1)"
    fi

    if ! docker info >/dev/null 2>&1; then
        warn "El daemon de Docker no responde. Intentando arrancarlo…"
        dtry=0
        while [ "$dtry" -lt 5 ] && ! docker info >/dev/null 2>&1; do
            dtry=$((dtry+1))
            run --sudo systemctl enable --now docker >/dev/null 2>&1 || run --sudo service docker start >/dev/null 2>&1 || true
            sleep 3
            [ "$dtry" -lt 5 ] && warn "Reintentando Docker (intento $dtry/5)…"
        done
        if ! docker info >/dev/null 2>&1; then
            fail "Docker sigue sin arrancar. Revisa: systemctl status docker y journalctl -u docker"
        else
            ok "Daemon Docker arrancado (intento $dtry)."
        fi
    else
        ok "Daemon Docker accesible."
    fi

    if ! id -nG | grep -qw docker; then
        warn "El usuario $USER no está en el grupo docker."
        run --sudo usermod -aG docker "$USER"
        if id -nG | grep -qw docker; then
            ok "Usuario $USER añadido al grupo docker."
        else
            warn "No se pudo verificar el grupo docker."
        fi
        warn "Vuelve a iniciar sesión (o ejecuta: newgrp docker) para usar docker sin sudo."
    fi
fi

# ============================================================
#  4) NGINX
# ============================================================
if [ "$DO_NGINX" = "1" ]; then
    echo; info "Verificando nginx…"
    if [ "$HAVE_NGINX" = "0" ]; then
        warn "nginx no está instalado. Instalando…"
        if [ "$PKG" = "apt" ]; then run --sudo apt-get install -y -qq nginx; fi
    else
        ok "nginx: $(nginx -v 2>&1)"
    fi
    [ -d /etc/nginx/sites-available ] || run --sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    run --sudo systemctl enable nginx 2>/dev/null || true
fi

# ============================================================
#  5) DIRECTORIOS DE DATOS
# ============================================================
echo; info "Creando estructura de directorios…"
run --sudo mkdir -p "$DATA_DIR"/{data,backups,logs}
run --sudo mkdir -p "$DATA_DIR/data"/{mariadb/v10,mariadb/v11,postgres/v15,postgres/v17}
if [ ! -d "$WWW_DIR" ]; then
    run --sudo mkdir -p "$WWW_DIR"
fi
if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    run --sudo chgrp www-data "$WWW_DIR" 2>/dev/null || true
    run --sudo chmod 2775 "$WWW_DIR" 2>/dev/null || true
fi

# ============================================================
#  6) NODE VÍA FNM
# ============================================================
if [ "$DO_FNM" = "1" ]; then
    echo; info "Configurando Node.js vía fnm…"
    FNM_BIN="$HOME/.local/share/fnm/fnm"
    if [ ! -x "$FNM_BIN" ]; then
        warn "fnm no está instalado. Instalando…"
        run sh -c 'curl -fsSL https://fnm.vercel.app/install | bash' || \
            run sh -c 'curl -fsSL https://raw.githubusercontent.com/Schniz/fnm/master/.ci/install.sh | bash'
        grep -q 'fnm env' "$HOME/.bashrc" 2>/dev/null || {
            printf '\n# fnm (bearwsl)\neval "$(fnm env --use-on-cd --shell bash)"\n' >> "$HOME/.bashrc"
            ok "Hook de fnm añadido a ~/.bashrc"
        }
    else
        ok "fnm: $("$FNM_BIN" --version 2>/dev/null)"
    fi
    if [ -x "$FNM_BIN" ]; then
        export PATH="$HOME/.local/share/fnm:$PATH"
        eval "$("$FNM_BIN" env 2>/dev/null)"
        if ! fnm list 2>/dev/null | grep -q "v${NODE_VER}"; then
            info "Instalando Node $NODE_VER (puede tardar)…"
            run fnm install "$NODE_VER"
        fi
        run fnm default "$NODE_VER"
        ok "Node: $(node --version 2>/dev/null)"
    fi
fi

# ============================================================
#  7) SERVICIOS NATIVOS (según modo; solo si no está instalado)
# ============================================================
# --- PHP nativo multi-versión (ondrej PPA) con pools en puertos alineados ---
# añade el repo de PHP multi-versión según el sistema:
#   Ubuntu → PPA ondrej/php (Launchpad)   Debian → packages.sury.org (keyring oficial)
add_php_repo() {
    local OS_ID
    OS_ID=$(grep -m1 '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    if [ "$OS_ID" = "debian" ]; then
        run --sudo apt-get install -y -qq lsb-release ca-certificates curl || true
        run --sudo sh -c 'curl -fsSL -o /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb && dpkg -i /tmp/debsuryorg-archive-keyring.deb' \
            || warn "No se pudo instalar el keyring de packages.sury.org (revisa red)."
        local CODENAME; CODENAME=$(grep -m1 '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
        [ -z "$CODENAME" ] && CODENAME=$(lsb_release -sc 2>/dev/null)
        if [ -z "$CODENAME" ]; then
            warn "No se pudo determinar el codename de Debian; añade manualmente: echo 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ <codename> main' > /etc/apt/sources.list.d/php.list"
            return 1
        fi
        run --sudo sh -c "echo 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main' > /etc/apt/sources.list.d/php.list" \
            || warn "No se pudo añadir el repo packages.sury.org (revisa red)."
        run --sudo chmod 644 /etc/apt/sources.list.d/php.list 2>/dev/null || true
    else
        run --sudo apt-get install -y -qq software-properties-common || true
        run --sudo add-apt-repository -y ppa:ondrej/php 2>/dev/null || warn "No se pudo añadir PPA ondrej (revisa red)."
    fi
}

install_native_php() {
    local chosen="$1"
    echo; info "Instalando PHP nativo (repo ondrej/sury, multi-versión)…"
    add_php_repo
    retry 3 run --sudo apt-get update -qq || warn "apt-get update falló tras reintentos (PHP)."
    local v pkg port
    for v in $chosen; do
        case "$v" in
            7.4) pkg="php7.4"; port=9002 ;;
            8.4) pkg="php8.4"; port=9001 ;;
            8.5) pkg="php8.5"; port=9000 ;;
            *) continue ;;
        esac
        if ! command -v "${pkg}-fpm" >/dev/null 2>&1 && [ ! -x "/usr/sbin/${pkg}-fpm" ] && ! command -v "php-fpm$v" >/dev/null 2>&1; then
            run --sudo apt-get install -y -qq "$pkg-fpm" "$pkg-mysql" "$pkg-pgsql" "$pkg-redis" \
                "$pkg-gd" "$pkg-zip" "$pkg-bcmath" "$pkg-intl" "$pkg-opcache" "$pkg-mbstring" \
                "$pkg-exif" "$pkg-pcntl" "$pkg-soap" "$pkg-sqlite3" "$pkg-xml" "$pkg-curl" \
                || warn "Faltaron algunos paquetes de $pkg (puede que no existan para esa versión)."
            # A prueba de fallos: si la versión no quedó instalada, refresca listas y reintenta lo esencial.
            if ! command -v "php-fpm$v" >/dev/null 2>&1 && [ ! -x "/usr/sbin/php-fpm$v" ]; then
                retry 2 run --sudo apt-get update -qq || true
                run --sudo apt-get install -y -qq "$pkg-fpm" || warn "No se pudo instalar $pkg-fpm (versión quizá no disponible en el repo)."
            fi
        fi
        # pool: escuchar en 127.0.0.1:puerto (alineado con docker)
        if [ -f "/etc/php/${v}/fpm/pool.d/www.conf" ]; then
            run --sudo sed -i "s|^listen = .*|listen = 127.0.0.1:${port}|" "/etc/php/${v}/fpm/pool.d/www.conf"
        fi
        run --sudo systemctl enable "$pkg-fpm" 2>/dev/null || true
        if [ "$NO_START" = "0" ]; then
            run --sudo systemctl start "$pkg-fpm" 2>/dev/null || true
            sleep 1
            if ! run --sudo systemctl is-active --quiet "$pkg-fpm"; then
                warn "No arrancó $pkg-fpm; comprobando config y reintentando…"
                run --sudo "/usr/sbin/php-fpm$v" -t 2>/dev/null || true
                run --sudo systemctl start "$pkg-fpm" 2>/dev/null || warn "Sigue sin arrancar $pkg-fpm (revisa: systemctl status $pkg-fpm)"
            fi
        fi
    done
}

# --- MariaDB nativo ---
install_native_db() {
    echo; info "Instalando MariaDB nativo…"
    if ! command -v mariadb >/dev/null 2>&1 && [ ! -x /usr/sbin/mariadbd ]; then
        run --sudo apt-get install -y -qq mariadb-server || warn "No se pudo instalar mariadb-server."
    fi
    run --sudo systemctl enable mariadb 2>/dev/null || true
    if [ "$NO_START" = "0" ]; then
        run --sudo systemctl start mariadb 2>/dev/null || warn "No arrancó mariadb."
    fi
    # acceso TCP root/root para dev (best effort; si falla, usar 'sudo mariadb')
    run --sudo mariadb -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY 'root'; GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null \
        || warn "Acceso TCP de MariaDB no configurado; usa: sudo mariadb"
}

# --- PostgreSQL nativo multi-versión (PGDG) con puertos alineados ---
install_native_pg() {
    local chosen="$1"
    echo; info "Instalando PostgreSQL nativo (PGDG, multi-versión)…"
    local CODENAME; CODENAME=$(grep -m1 VERSION_CODENAME /etc/os-release | cut -d= -f2)
    [ -z "$CODENAME" ] && CODENAME=$(lsb_release -cs 2>/dev/null)
    run --sudo apt-get install -y -qq gnupg ca-certificates 2>/dev/null || true
    run --sudo install -m 0755 -d /etc/apt/keyrings
    run --sudo sh -c "echo 'deb [signed-by=/etc/apt/keyrings/pgdg.asc] http://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main' > /etc/apt/sources.list.d/pgdg.list" || warn "PGDG repo falló."
    run --sudo chmod 644 /etc/apt/sources.list.d/pgdg.list 2>/dev/null || true
    if ! run --sudo sh -c 'curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.asc'; then
        warn "Clave PGDG falló; reintentando…"
        run --sudo sh -c 'curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.asc' || warn "Clave PGDG falló de nuevo (se usará solo el repo de Debian)."
    fi
    retry 3 run --sudo apt-get update -qq || warn "apt-get update falló tras reintentos (PGDG)."
    local v
    for v in $chosen; do
        case "$v" in
            15) run --sudo apt-get install -y -qq postgresql-15 || warn "postgresql-15 falló." ;;
            17) run --sudo apt-get install -y -qq postgresql-17 || warn "postgresql-17 falló." ;;
        esac
    done
    # cluster 15 en puerto 5433 (el 17 usa 5432 por defecto)
    if echo "$chosen" | grep -q 15; then
        if [ ! -d /etc/postgresql/15/main ] && [ "$DRY_RUN" = "0" ]; then
            sudo pg_createcluster 15 main -p 5433 2>/dev/null || warn "pg_createcluster 15 falló (configúralo a mano en /etc/postgresql/15/main/postgresql.conf, port=5433)."
        fi
        if [ -f /etc/postgresql/15/main/postgresql.conf ]; then
            run --sudo sed -i "s/^port = .*/port = 5433/" /etc/postgresql/15/main/postgresql.conf
            run --sudo pg_ctlcluster 15 main start 2>/dev/null || run --sudo systemctl restart postgresql@15-main 2>/dev/null || true
        fi
    fi
    run --sudo systemctl enable postgresql 2>/dev/null || true
    if [ "$NO_START" = "0" ]; then
        run --sudo systemctl start postgresql 2>/dev/null || warn "No arrancó postgresql."
    fi
    run --sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'root';" 2>/dev/null || true
}

if [ "$PHP_MODE" = "native" ]; then install_native_php "$PHP_CHOICES"; fi
if [ "$DB_MODE" = "native" ]; then install_native_db; fi
if [ "$PG_MODE" = "native" ]; then install_native_pg "$PG_CHOICES"; fi

# ============================================================
#  8) ROADRUNNER
# ============================================================
if [ "$DO_RR" = "1" ]; then
    echo; info "RoadRunner…"
    if [ ! -x /usr/local/bin/rr ] || ! /usr/local/bin/rr --version >/dev/null 2>&1; then
        info "Descargando binario rr v$RR_VERSION ($RR_ARCH)…"
        run --sudo sh -c "curl -fsSL 'https://github.com/roadrunner-server/roadrunner/releases/download/v${RR_VERSION}/roadrunner-${RR_VERSION}-linux-${RR_ARCH}.tar.gz' -o /tmp/rr.tar.gz && tar -xzf /tmp/rr.tar.gz -C /tmp && mv /tmp/roadrunner-${RR_VERSION}-linux-${RR_ARCH}/rr /usr/local/bin/rr && chmod +x /usr/local/bin/rr && rm -rf /tmp/rr.tar.gz /tmp/roadrunner-*"
        if /usr/local/bin/rr --version >/dev/null 2>&1; then
            ok "rr CLI: $(/usr/local/bin/rr --version 2>&1 | head -1)"
        else
            fail "No se pudo instalar el binario rr (revisa red)."
        fi
    else
        ok "rr CLI: $(/usr/local/bin/rr --version 2>&1 | head -1)"
    fi
fi

# ============================================================
#  9) CONFIGURAR NGINX (vhosts por defecto)
# ============================================================
if [ "$DO_NGINX" = "1" ]; then
    echo; info "Configurando vhosts por defecto…"
    if [ ! -f /etc/nginx/sites-available/bearwsl.test ]; then
        run --sudo tee /etc/nginx/sites-available/bearwsl.test >/dev/null <<'NGINX'
server {
    listen 80;
    server_name bearwsl.test;
    root /var/www;
    index index.php index.html;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
NGINX
        run --sudo ln -sf /etc/nginx/sites-available/bearwsl.test /etc/nginx/sites-enabled/bearwsl.test
    fi
    if [ "$DO_PANEL" = "1" ] && [ ! -f /etc/nginx/sites-available/panel.bearwsl.test ]; then
        run --sudo tee /etc/nginx/sites-available/panel.bearwsl.test >/dev/null <<'NGINX'
server {
    listen 80;
    server_name panel.bearwsl.test;
    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINX
        run --sudo ln -sf /etc/nginx/sites-available/panel.bearwsl.test /etc/nginx/sites-enabled/panel.bearwsl.test
    fi
    if run --sudo nginx -t; then
        run --sudo systemctl reload nginx 2>/dev/null || run --sudo nginx -s reload || true
        ok "nginx configurado y recargado."
    else
        fail "nginx -t falló; revisa la configuración manualmente."
    fi
fi

# ============================================================
#  9b) DOMINIOS .TEST EN /etc/hosts (solo Linux nativo)
#      En WSL los dominios se mapean en el hosts de Windows.
# ============================================================
if [ "$WSL" = "0" ] && [ "$DO_NGINX" = "1" ]; then
    info "Registrando dominios .test en /etc/hosts…"
    for d in bearwsl.test $( [ "$DO_PANEL" = "1" ] && echo panel.bearwsl.test ); do
        if ! awk -v d="$d" '{for(i=2;i<=NF;i++) if($i==d) f=1} END{exit !f}' /etc/hosts 2>/dev/null; then
            run --sudo sh -c "echo '127.0.0.1 $d' >> /etc/hosts"
        fi
    done
    ok "Dominios .test disponibles en 127.0.0.1 (/etc/hosts)."
fi

# ============================================================
#  10) SUDOERS (vhosts + nginx + panel + servicios nativos)
# ============================================================
echo; info "Configurando sudoers (vhosts, nginx, panel y servicios nativos sin contraseña)…"
SUDOERS_EXTRA=""
if [ "$PHP_MODE" = "native" ]; then
    SUDOERS_EXTRA="$SUDOERS_EXTRA, /usr/bin/systemctl start php7.4-fpm, /usr/bin/systemctl stop php7.4-fpm, /usr/bin/systemctl restart php7.4-fpm, /usr/bin/systemctl start php8.4-fpm, /usr/bin/systemctl stop php8.4-fpm, /usr/bin/systemctl restart php8.4-fpm, /usr/bin/systemctl start php8.5-fpm, /usr/bin/systemctl stop php8.5-fpm, /usr/bin/systemctl restart php8.5-fpm"
fi
if [ "$DB_MODE" = "native" ]; then
    SUDOERS_EXTRA="$SUDOERS_EXTRA, /usr/bin/systemctl start mariadb, /usr/bin/systemctl stop mariadb, /usr/bin/systemctl restart mariadb"
fi
if [ "$PG_MODE" = "native" ]; then
    SUDOERS_EXTRA="$SUDOERS_EXTRA, /usr/bin/systemctl start postgresql@15-main, /usr/bin/systemctl stop postgresql@15-main, /usr/bin/systemctl restart postgresql@15-main, /usr/bin/systemctl start postgresql@17-main, /usr/bin/systemctl stop postgresql@17-main, /usr/bin/systemctl restart postgresql@17-main"
fi
{
    echo "# bearwsl: vhosts, nginx, panel y servicios nativos sin contraseña"
    echo "$USER ALL=(root) NOPASSWD: $BEARWSL_DIR/vhost.sh, /usr/sbin/nginx -t, /usr/bin/nginx -t, /usr/bin/systemctl reload nginx, /usr/sbin/systemctl reload nginx, /usr/bin/systemctl restart nginx, /usr/sbin/systemctl restart nginx, /usr/bin/systemctl start bearwsl-panel, /usr/sbin/systemctl start bearwsl-panel, /usr/bin/systemctl stop bearwsl-panel, /usr/sbin/systemctl stop bearwsl-panel, /usr/bin/systemctl restart bearwsl-panel, /usr/sbin/systemctl restart bearwsl-panel"
    if [ -n "$SUDOERS_EXTRA" ]; then
        echo "$USER ALL=(root) NOPASSWD: ${SUDOERS_EXTRA#, }"
    fi
} | run --sudo tee /etc/sudoers.d/bearwsl >/dev/null
run --sudo chmod 440 /etc/sudoers.d/bearwsl
run --sudo visudo -c >/dev/null 2>&1 && ok "sudoers válido." || warn "Revisa /etc/sudoers.d/bearwsl"

# ============================================================
#  11) PANEL WEB (token + servicio systemd)
# ============================================================
PANEL_TOKEN=""
if [ "$DO_PANEL" = "1" ]; then
    echo; info "Configurando panel web…"
    if [ ! -f "$CONFIG_DIR/panel_token" ]; then
        run mkdir -p "$CONFIG_DIR"
        PANEL_TOKEN=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)
        run sh -c "umask 077; printf '%s\n' '$PANEL_TOKEN' > '$CONFIG_DIR/panel_token'"
    else
        PANEL_TOKEN=$(cat "$CONFIG_DIR/panel_token")
        ok "Token existente reutilizado."
    fi

    if [ "$HAS_SYSTEMD" = "1" ]; then
        run --sudo tee /etc/systemd/system/bearwsl-panel.service >/dev/null <<UNIT
[Unit]
Description=BEARWSL Web Panel (PHP built-in server)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$BEARWSL_DIR/webpanel
Environment=HOME=$HOME
Environment=BEARWSL_DIR=$BEARWSL_DIR
ExecStart=/usr/bin/php -S 0.0.0.0:8088 $BEARWSL_DIR/webpanel/router.php
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
        run --sudo systemctl daemon-reload
        if [ "${PANEL_AUTOSTART:-0}" = "1" ]; then
            run --sudo systemctl enable bearwsl-panel
        fi
        run --sudo systemctl start bearwsl-panel || warn "El panel no arrancó: systemctl status bearwsl-panel"
    else
        warn "Sin systemd: inicia el panel con: panel.sh --panel start"
    fi
fi

# ============================================================
#  12) AUTOSTART DEL STACK (systemd usuario)
# ============================================================
if [ "${STACK_AUTOSTART:-0}" = "1" ] && [ "$HAS_SYSTEMD" = "1" ]; then
    echo; info "Configurando autostart del stack…"
    chmod +x "$BEARWSL_DIR/scripts/autostart.sh"
    mkdir -p "$HOME/.config/systemd/user"
    run tee "$HOME/.config/systemd/user/bearwsl-stack.service" >/dev/null <<UNIT
[Unit]
Description=BEARWSL stack autostart
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$BEARWSL_DIR
ExecStart=$BEARWSL_DIR/scripts/autostart.sh
ExecStop=docker compose stop

[Install]
WantedBy=default.target
UNIT
    run systemctl --user daemon-reload
    run systemctl --user enable bearwsl-stack
    run systemctl --user start bearwsl-stack
fi

# ============================================================
#  13) LEVANTAR SERVICIOS
# ============================================================
if [ "$NO_START" = "1" ]; then
    echo; warn "NO_START activo: no se levantan servicios. Usa luego: panel.sh --up"
fi

# --- contenedores (solo familias en modo container + utilidades) ---
if [ "$DO_DOCKER" = "1" ] && [ "$NO_START" = "0" ]; then
    echo; info "Validando docker-compose.yml…"
    if docker compose config -q >/dev/null 2>&1; then
        ok "compose válido."
    else
        fail "docker-compose.yml inválido: $(docker compose config 2>&1 | head -5)"
    fi

    SELECTED=""
    if [ "$PHP_MODE" = "container" ]; then for v in $PHP_CHOICES; do SELECTED="$SELECTED $(map_service "$v")"; done; fi
    if [ "$DB_MODE" = "container" ]; then for v in $DB_CHOICES; do SELECTED="$SELECTED $(map_service "$v")"; done; fi
    if [ "$PG_MODE" = "container" ]; then for v in $PG_CHOICES; do SELECTED="$SELECTED $(map_service "$v")"; done; fi
    [ "$DO_UTILS" = "1" ] && SELECTED="$SELECTED redis mailpit"
    [ "$DO_RR" = "1" ] && SELECTED="$SELECTED roadrunner"

    if [ -n "${SELECTED// }" ]; then
        if [ "$DO_RR" = "1" ]; then
            info "Construyendo imagen de RoadRunner (primera vez)…"
            rbuild=0
            while [ "$rbuild" -lt 2 ] && ! docker compose build roadrunner 2>&1 | tee /tmp/bearwsl-rr-build.log | tail -n 15; do
                rbuild=$((rbuild+1))
                warn "Falló la construcción de RoadRunner (intento $rbuild/2); reintentando con --no-cache…"
                docker compose build --no-cache roadrunner 2>&1 | tee /tmp/bearwsl-rr-build.log | tail -n 15
            done
            if [ "$rbuild" -ge 2 ] && ! docker image inspect "bearwsl/roadrunner:${RR_VERSION}" >/dev/null 2>&1; then
                warn "La imagen de RoadRunner no se construyó. Log: /tmp/bearwsl-rr-build.log — reintenta: docker compose build roadrunner --no-cache"
            fi
        fi
        RUNNING_N=$(docker compose ps -q 2>/dev/null | wc -l)
        if [ "$RUNNING_N" -gt 0 ]; then
            echo "⚠ Hay $RUNNING_N contenedores corriendo. La nueva config añade healthchecks/restart,"
            echo "  así que 'up' los RECREARÁ una vez (los datos en /var/lib/bearwsl se conservan)."
            if ask_yes "¿Recrear los contenedores ahora? (si dices no, quedan intactos)" "s"; then
                run docker compose up -d --build $SELECTED
            else
                warn "Contenedores actuales intactos. Usa después: panel.sh --up"
            fi
        else
            echo; info "Levantando el stack (primera vez descarga imágenes, puede tardar)…"
            # shellcheck disable=SC2086
            run docker compose up -d --build $SELECTED
        fi
    else
        warn "Sin contenedores que levantar (todas las familias en modo nativo)."
    fi
fi

# --- servicios nativos (según modo) ---
if [ "$NO_START" = "0" ]; then
    svc_start "$PHP_CURRENT" 2>/dev/null || true
    svc_start "$DB_CURRENT" 2>/dev/null || true
    svc_start "$PG_CURRENT" 2>/dev/null || true
fi

echo; info "Resumen del estado…"
compose_ps | awk -F'\t' '{printf "  %-12s %s\n", $1, $2}'
for s in php74 php84 php85 mariadb10 mariadb11 postgres15 postgres17; do
    mode=$(svc_mode "$s")
    if [ "$mode" = "native" ]; then
        ns=$(native_service_of "$s")
        if systemctl is-active --quiet "$ns" 2>/dev/null; then printf '  %-12s %s (nativo)\n' "$ns" "activo"; fi
    fi
done

# ============================================================
#  14) RESUMEN
# ============================================================
WSL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo; hr
printf '   %s✅  INSTALACIÓN COMPLETADA%s\n' "$BOLD" "$RESET"
hr
printf '  Modos         : PHP=%s  MariaDB=%s  Postgres=%s\n' "$PHP_MODE" "$DB_MODE" "$PG_MODE"
printf '  Migrar        : %spanel.sh --mode php|db|pg container|native%s\n' "$GREEN" "$RESET"
printf '  Panel web     : %shttp://panel.bearwsl.test%s  (o http://127.0.0.1:8088)\n' "$GREEN" "$RESET"
[ -n "$PANEL_TOKEN" ] && printf '  Token panel   : %s%s%s  (también en ~/.config/bearwsl/panel_token)\n' "$GREEN" "$PANEL_TOKEN" "$RESET"
printf '  Proyectos     : %shttp://bearwsl.test%s (autoindex de /var/www)\n' "$GREEN" "$RESET"
printf '  Versiones     : PHP %s · MariaDB %s · Postgres %s · Node %s\n' "$PHP_CURRENT" "$DB_CURRENT" "$PG_CURRENT" "${NODE_CURRENT:-—}"
printf '  RoadRunner    : %srr --version%s (CLI) · ruta nginx → 127.0.0.1:8080\n' "$GREEN" "$RESET"
printf '  Comandos      : %spanel.sh%s (panel) · %svhost.sh%s (vhosts)\n' "$GREEN" "$RESET" "$GREEN" "$RESET"
if [ "$WSL" = "1" ] && [ -n "$WSL_IP" ]; then
    printf '  Hosts Windows : añade a C:\\Windows\\System32\\drivers\\etc\\hosts:\n'
    printf '                  %s %s%s\n' "$YELLOW" "$WSL_IP" "$RESET"
    printf '                  %s bearwsl.test panel.bearwsl.test tus-dominios.test%s\n' "$YELLOW" "$RESET"
elif [ "$WSL" = "0" ] && [ "$DO_NGINX" = "1" ]; then
    printf '  Hosts Linux   : dominios .test registrados en /etc/hosts (127.0.0.1)\n'
fi
printf '  Para ver estado: %spanel.sh --status%s\n' "$GREEN" "$RESET"
hr
echo
