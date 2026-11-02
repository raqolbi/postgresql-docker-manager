#!/usr/bin/env bash
# PostgreSQL Docker Manager
# First-run setup + interactive database administration.
set -Euo pipefail
umask 077   # semua file baru (backup, .env, sertifikat) default hanya bisa dibaca root

# Semua file runtime (.env, compose.yaml, data/, certs/, backups/, ...) dibuat di
# folder tempat script ini berada. Scheduler menjalankan salinan di
# /usr/local/sbin dan memberi tahu foldernya lewat PGM_BASE_DIR.
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
INSTALLED_BIN="/usr/local/sbin/postgres-manager"
if [[ -n "${PGM_BASE_DIR:-}" ]]; then
  BASE_DIR=$(readlink -f "$PGM_BASE_DIR")
elif [[ "$SCRIPT_PATH" == "$INSTALLED_BIN" ]]; then
  echo "Ini salinan untuk scheduler. Jalankan script dari folder proyeknya, atau set PGM_BASE_DIR=<folder>." >&2
  exit 1
else
  BASE_DIR=$(dirname "$SCRIPT_PATH")
fi
if [[ ! -d "$BASE_DIR" || ! "$BASE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Folder kerja tidak valid: '$BASE_DIR' (hanya huruf, angka, . _ - / dan harus sudah ada)." >&2
  exit 1
fi
case "$BASE_DIR" in
  /|/bin|/sbin|/usr|/usr/*bin|/etc|/var|/tmp|/root|/home) echo "Folder kerja '$BASE_DIR' tidak boleh dipakai. Taruh script di folder sendiri, mis. /opt/postgres." >&2; exit 1 ;;
esac
ENV_FILE="$BASE_DIR/.env"
COMPOSE_FILE="$BASE_DIR/compose.yaml"
CERT_DIR="$BASE_DIR/certs"
CONF_DIR="$BASE_DIR/config"
HBA_FILE="$CONF_DIR/pg_hba.conf"
BACKUP_DIR="$BASE_DIR/backups"

# Harus root agar bisa mengelola Docker, owner file data, dan scheduler.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Jalankan dengan sudo: sudo $0"
  exit 1
fi

err() { echo "ERROR: $*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Perintah '$1' belum tersedia."; return 1; }; }

pause() { echo; read -r -p "Tekan Enter untuk kembali ke menu..." _ || true; }

# Baca .env tanpa `source`, supaya isi file tidak pernah dieksekusi sebagai kode
# (mencegah eskalasi ke root jika .env pernah dimiliki/ditulis user biasa).
load_config() {
  [[ -f "$ENV_FILE" ]] || { err "File $ENV_FILE tidak ditemukan. Jalankan setup (menu 1) terlebih dahulu."; return 1; }
  POSTGRES_IMAGE="" POSTGRES_DB="" POSTGRES_USER="" POSTGRES_PASSWORD=""
  POSTGRES_PORT="" POSTGRES_BIND="" POSTGRES_CONTAINER="" POSTGRES_DATA_TARGET=""
  POSTGRES_UID="" POSTGRES_GID=""
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//$'\r'/}; value=${value//$'\r'/}
    key=${key#"${key%%[![:space:]]*}"}; key=${key%"${key##*[![:space:]]}"}
    [[ -z "$key" || "$key" == \#* ]] && continue
    key=${key#export }
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
    case "$key" in
      POSTGRES_IMAGE|POSTGRES_DB|POSTGRES_USER|POSTGRES_PASSWORD|POSTGRES_PORT|POSTGRES_BIND|POSTGRES_CONTAINER|POSTGRES_DATA_TARGET)
        printf -v "$key" '%s' "$value" ;;
      POSTGRES_UID|POSTGRES_GID)
        if [[ "$value" =~ ^[0-9]+$ ]]; then printf -v "$key" '%s' "$value"; fi ;;
    esac
  done < "$ENV_FILE"
  : "${POSTGRES_IMAGE:=postgres:18}"
  : "${POSTGRES_DB:=postgres}"
  : "${POSTGRES_USER:=postgres_admin}"
  : "${POSTGRES_PORT:=5434}"
  : "${POSTGRES_BIND:=127.0.0.1}"
  : "${POSTGRES_CONTAINER:=qolcore-postgres}"
  if ! valid_identifier "$POSTGRES_USER" || ! valid_identifier "$POSTGRES_DB" \
     || [[ ! "$POSTGRES_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    err "Nilai POSTGRES_USER/POSTGRES_DB/POSTGRES_CONTAINER di $ENV_FILE tidak valid."
    return 1
  fi
}

# Folder proyek & backups dipakai proses root (scheduler). Jika bisa diubah user
# non-root, user itu bisa membelokkan file lewat symlink / mengganti konfigurasi.
base_dir_safe() {
  local d owner mode
  for d in "$BASE_DIR" "$BACKUP_DIR"; do
    [[ -e "$d" ]] || continue
    if [[ -L "$d" ]]; then err "$d adalah symlink; ditolak demi keamanan."; return 1; fi
    owner=$(stat -c '%u' "$d"); mode=$(stat -c '%a' "$d")
    if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
      err "$d dimiliki uid $owner (mode $mode). Proses root tidak boleh bekerja di folder yang bisa diubah user lain."
      err "Perbaiki: sudo chown root:root $d && sudo chmod go-w $d"
      return 1
    fi
  done
}

# File yang dipakai perintah root tidak boleh bisa ditulis user lain.
check_ownership() {
  local f owner mode
  owner=$(stat -c '%u' "$BASE_DIR"); mode=$(stat -c '%a' "$BASE_DIR")
  if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
    echo "PERINGATAN: folder $BASE_DIR dimiliki uid $owner (mode $mode); auto backup menolak berjalan di folder"
    echo "           yang bisa diubah user non-root. Perbaiki: sudo chown root:root $BASE_DIR && sudo chmod go-w $BASE_DIR"
  fi
  for f in "$ENV_FILE" "$COMPOSE_FILE"; do
    [[ -e "$f" ]] || continue
    owner=$(stat -c '%u' "$f"); mode=$(stat -c '%a' "$f")
    if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
      echo "PERINGATAN: $f dimiliki uid $owner / mode $mode. Sebaiknya milik root dan tidak writable oleh user lain:"
      echo "           sudo chown root:root $f && sudo chmod go-w $f"
    fi
  done
  return 0
}

check_docker() {
  need_cmd docker || return 1
  docker compose version >/dev/null 2>&1 || {
    err "Docker Compose plugin tidak ditemukan. Pasang Docker Engine + Docker Compose plugin terlebih dahulu."
    return 1
  }
  docker info >/dev/null 2>&1 || { err "Docker daemon tidak dapat diakses."; return 1; }
}

# Nama database yang SUDAH ADA (bisa dibuat aplikasi lain, mis. "my-app"): lebih longgar
# dari aturan pembuatan, tetap aman untuk nama file dan SQL ber-quote.
valid_dbname() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_\$-]{0,62}$ ]]; }

valid_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]]
}

valid_ipv4() {
  local ip=$1 o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

sql_ident() {
  # Identifier is validated before use; double-quote it for SQL.
  printf '"%s"' "$1"
}

sql_literal() {
  local value=${1//\'/\'\'}
  printf "'%s'" "$value"
}

psql_admin() {
  docker exec -i "$POSTGRES_CONTAINER" psql -X -P pager=off -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$POSTGRES_CONTAINER" 2>/dev/null | grep -qx true
}

require_running() {
  load_config || return 1
  container_running || { err "Container '$POSTGRES_CONTAINER' tidak berjalan. Jalankan menu 2 (Start)."; return 1; }
}

# Tunggu server final siap via TCP. Saat inisialisasi pertama, entrypoint image
# menjalankan server sementara tanpa TCP (listen_addresses=''), sehingga cek via
# socket saja bisa "siap" terlalu cepat.
wait_ready() {
  local container=$1 user=$2 db=$3 i
  for i in {1..60}; do
    if docker exec "$container" pg_isready -h 127.0.0.1 -p 5432 -U "$user" -d "$db" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

expand_path() {
  local p=$1 home=$HOME
  if [[ -n "${SUDO_USER:-}" ]]; then home=$(getent passwd "$SUDO_USER" | cut -d: -f6); fi
  [[ "$p" == "~" ]] && p=$home
  [[ "$p" == "~/"* ]] && p="$home/${p#\~/}"
  printf '%s' "$p"
}

setup_stack() {
  echo "=== Setup PostgreSQL Docker ==="
  check_docker || return 1
  need_cmd openssl || return 1
  if [[ -e "$COMPOSE_FILE" || -e "$ENV_FILE" ]]; then
    err "Konfigurasi sudah ada di $BASE_DIR (.env / compose.yaml). Setup dibatalkan agar data tidak tertimpa."
    return 1
  fi
  if [[ -d "$BASE_DIR/data" ]] && [[ -n "$(ls -A "$BASE_DIR/data" 2>/dev/null)" ]]; then
    err "$BASE_DIR/data tidak kosong. Cluster lama tidak akan diinisialisasi ulang, sehingga"
    err "user/password baru dari setup ini tidak akan berlaku. Pindahkan/hapus isi folder itu dulu."
    return 1
  fi

  local image db admin password port bind container confirm major pg_uid data_target force_ssl admin_tcp
  read -r -p "Image PostgreSQL [postgres:18]: " image
  image=${image:-postgres:18}
  [[ "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { err "Nama image tidak valid."; return 1; }
  read -r -p "Database awal [qolcore]: " db
  db=${db:-qolcore}
  read -r -p "Admin username [qolcore_owner]: " admin
  admin=${admin:-qolcore_owner}
  if ! valid_identifier "$db" || ! valid_identifier "$admin"; then
    err "Nama database/user tidak valid. Gunakan huruf, angka, underscore; karakter pertama harus huruf atau underscore; maksimal 63 karakter."
    return 1
  fi
  read -r -p "Port host [5434]: " port
  port=${port:-5434}
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { err "Port tidak valid."; return 1; }
  port=$((10#$port))
  echo "Bind address:"
  echo "  127.0.0.1 = hanya bisa diakses dari server ini (paling aman, default)"
  echo "  0.0.0.0   = semua interface; WAJIB dibatasi firewall (lihat peringatan setelah setup)"
  read -r -p "Bind address [127.0.0.1]: " bind
  bind=${bind:-127.0.0.1}
  valid_ipv4 "$bind" || { err "Bind address harus berupa IPv4 yang valid."; return 1; }
  read -r -p "Nama container [qolcore-postgres]: " container
  container=${container:-qolcore-postgres}
  [[ "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { err "Nama container tidak valid."; return 1; }
  if docker inspect "$container" >/dev/null 2>&1; then
    err "Container bernama '$container' sudah ada. Gunakan nama lain atau hapus container tersebut."
    return 1
  fi
  read -r -p "Wajibkan SSL untuk semua koneksi TCP (tolak koneksi non-SSL)? [Y/n]: " force_ssl
  force_ssl=${force_ssl:-Y}
  echo "Admin '$admin' adalah superuser. Script selalu memakai socket lokal di dalam container."
  echo "Aplikasi sebaiknya memakai user per database (menu 5), bukan superuser."
  read -r -p "Izinkan admin login dari luar container (TCP, mis. dari DBeaver)? [y/N]: " admin_tcp
  admin_tcp=${admin_tcp:-N}

  echo ""
  echo "Pilih password admin:"
  echo "  1. Generate otomatis"
  echo "  2. Input sendiri"
  read -r -p "Pilihan [1]: " confirm
  confirm=${confirm:-1}
  if [[ "$confirm" == "2" ]]; then
    read -r -s -p "Password admin: " password; echo
    read -r -s -p "Ulangi password: " confirm; echo
    [[ -n "$password" && "$password" == "$confirm" ]] || { err "Password kosong atau tidak cocok."; return 1; }
    [[ "$password" =~ ^[A-Za-z0-9@#%+=._-]{16,}$ ]] || { err "Password minimal 16 karakter; gunakan huruf, angka, dan karakter @ # % + = . _ - agar aman disimpan di .env."; return 1; }
  else
    password=$(openssl rand -hex 24)
  fi

  echo "Mengunduh/memeriksa image $image ..."
  docker pull "$image" || { err "Gagal pull image $image."; return 1; }

  # Versi mayor menentukan lokasi PGDATA. PG 18+ memakai /var/lib/postgresql/<versi>/docker;
  # versi lama memakai /var/lib/postgresql/data (jika salah, data jatuh ke volume anonim).
  major=$(docker run --rm --entrypoint postgres "$image" --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
  [[ "$major" =~ ^[0-9]+$ ]] || { err "Tidak bisa membaca versi PostgreSQL dari image $image."; return 1; }
  if (( major >= 18 )); then data_target=/var/lib/postgresql; else data_target=/var/lib/postgresql/data; fi
  # UID user postgres berbeda antar varian image (Debian 999, Alpine 70).
  pg_uid=$(docker run --rm --entrypoint id "$image" -u postgres 2>/dev/null || true)
  [[ "$pg_uid" =~ ^[0-9]+$ ]] || { err "Tidak bisa membaca UID user postgres di image $image."; return 1; }
  local pg_gid
  pg_gid=$(docker run --rm --entrypoint id "$image" -g postgres 2>/dev/null || true)
  [[ "$pg_gid" =~ ^[0-9]+$ ]] || pg_gid=$pg_uid
  echo "PostgreSQL versi $major, uid postgres $pg_uid, PGDATA mount $data_target"

  mkdir -p "$BASE_DIR/data" "$BACKUP_DIR" "$CERT_DIR" "$CONF_DIR"
  # Folder proyek sendiri tidak diubah owner/mode-nya (bisa jadi repo git milik user).
  chown root:root "$BACKUP_DIR" "$CERT_DIR" "$CONF_DIR"
  chmod 700 "$BACKUP_DIR" "$CERT_DIR"
  chmod 755 "$CONF_DIR"
  # Folder data di-mount ke /var/lib/postgresql. Entrypoint image hanya meng-chown
  # subfolder PGDATA, lalu berjalan sebagai user postgres, jadi folder induk ini
  # harus milik user postgres di container (bukan root 700).
  chown "$pg_uid:$pg_gid" "$BASE_DIR/data"
  chmod 700 "$BASE_DIR/data"

  echo "Membuat self-signed SSL certificate..."
  openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
    -out "$CERT_DIR/server.crt" \
    -keyout "$CERT_DIR/server.key" \
    -subj "/CN=$container" >/dev/null 2>&1 || { err "Gagal membuat sertifikat SSL."; return 1; }
  chown "$pg_uid:$pg_gid" "$CERT_DIR/server.key" "$CERT_DIR/server.crt"
  chmod 600 "$CERT_DIR/server.key"
  chmod 644 "$CERT_DIR/server.crt"

  # pg_hba: socket lokal (docker exec) trust, TCP selalu scram-sha-256.
  {
    echo "# Dibuat oleh postgres-manager.sh"
    echo "# TYPE     DATABASE  USER  ADDRESS     METHOD"
    echo "local      all       all               trust"
    if [[ "${admin_tcp,,}" != "y" ]]; then
      echo "# Superuser admin hanya boleh lewat socket lokal (docker exec)."
      echo "host       all       $admin   0.0.0.0/0   reject"
      echo "host       all       $admin   ::/0        reject"
    fi
    if [[ "${force_ssl,,}" == "n" ]]; then
      echo "host       all       all   0.0.0.0/0   scram-sha-256"
      echo "host       all       all   ::/0        scram-sha-256"
    else
      echo "hostssl    all       all   0.0.0.0/0   scram-sha-256"
      echo "hostssl    all       all   ::/0        scram-sha-256"
      echo "hostnossl  all       all   0.0.0.0/0   reject"
      echo "hostnossl  all       all   ::/0        reject"
    fi
  } > "$HBA_FILE"
  chown "$pg_uid:$pg_gid" "$HBA_FILE"
  chmod 640 "$HBA_FILE"

  cat > "$ENV_FILE" <<EOF
POSTGRES_IMAGE=$image
POSTGRES_DB=$db
POSTGRES_USER=$admin
POSTGRES_PASSWORD=$password
POSTGRES_PORT=$port
POSTGRES_BIND=$bind
POSTGRES_CONTAINER=$container
POSTGRES_DATA_TARGET=$data_target
POSTGRES_UID=$pg_uid
POSTGRES_GID=$pg_gid
COMPOSE_PROJECT_NAME=pgm-${SCHED_ID}
EOF
  chmod 600 "$ENV_FILE"

  cat > "$COMPOSE_FILE" <<'YAML'
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: ${POSTGRES_CONTAINER}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${POSTGRES_BIND}:${POSTGRES_PORT}:5432"
    volumes:
      - ./data:${POSTGRES_DATA_TARGET}
      - ./certs/server.crt:/etc/postgresql/server.crt:ro
      - ./certs/server.key:/etc/postgresql/server.key:ro
      - ./config/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
    command:
      - postgres
      - -c
      - ssl=on
      - -c
      - ssl_cert_file=/etc/postgresql/server.crt
      - -c
      - ssl_key_file=/etc/postgresql/server.key
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
      - -c
      - password_encryption=scram-sha-256
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\""]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
YAML
  chmod 600 "$COMPOSE_FILE"

  echo "Menjalankan PostgreSQL..."
  if ! (cd "$BASE_DIR" && docker compose up -d); then
    err "docker compose up gagal. Periksa pesan di atas. Konfigurasi tetap di $BASE_DIR;"
    err "setelah diperbaiki jalankan menu 2 (Start)."
    return 1
  fi
  echo "Menunggu PostgreSQL siap (maks. 2 menit)..."
  if ! wait_ready "$container" "$admin" "$db"; then
    err "PostgreSQL belum siap. Periksa menu 12 (Logs)."
    return 1
  fi

  # Default PostgreSQL memberi CONNECT ke PUBLIC di setiap database. Cabut supaya
  # user aplikasi hanya bisa masuk ke database miliknya sendiri.
  POSTGRES_CONTAINER=$container POSTGRES_USER=$admin POSTGRES_DB=$db psql_admin -q <<SQL || err "Gagal mencabut CONNECT dari PUBLIC (lanjut)."
REVOKE CONNECT ON DATABASE $(sql_ident "$db") FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
SQL

  echo ""
  echo "Setup selesai."
  echo "Container : $container"
  echo "Database  : $db"
  echo "Admin     : $admin"
  echo "Port      : $bind:$port"
  echo "SSL       : aktif (self-signed certificate)$([[ "${force_ssl,,}" == "n" ]] || echo ", koneksi non-SSL ditolak")"
  echo "Password  : tersimpan di $ENV_FILE (permission 600)"
  echo ""
  if [[ "${admin_tcp,,}" == "y" ]]; then
    echo "Connection string admin (sesuaikan host):"
    echo "postgresql://$admin:<PASSWORD>@<HOST>:$port/$db?sslmode=require"
  else
    echo "Admin hanya bisa login dari dalam container (TCP ditolak)."
    echo "Buat database + user untuk aplikasi lewat menu 5; connection string-nya ditampilkan di sana."
  fi
  firewall_notice "$bind" "$port"
}

firewall_notice() {
  local bind=$1 port=$2
  [[ "$bind" == "127.0.0.1" ]] && return 0
  cat <<EOF

================== PERINGATAN FIREWALL ==================
Port $port dipublikasikan oleh Docker di $bind. Docker menulis aturan iptables
sendiri sehingga aturan UFW / INPUT chain TIDAK berlaku untuk port ini.
Batasi akses dengan:
  1. Oracle Cloud Security List / NSG: izinkan TCP $port hanya dari IP tertentu.
  2. Chain DOCKER-USER di host, contoh (ganti 10.0.0.0/24 dengan IP/subnet klien):
     sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j DROP
     sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -s 10.0.0.0/24 -j ACCEPT
     (simpan permanen, mis. dengan paket iptables-persistent)
=========================================================
EOF
}

create_database() {
  require_running || return 1
  local db user password password2 role_exists db_exists
  read -r -p "Nama database baru: " db
  read -r -p "Username pemilik database: " user
  if ! valid_identifier "$db" || ! valid_identifier "$user"; then
    err "Nama database/user tidak valid."; return 1
  fi
  db_exists=$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname=$(sql_literal "$db")" | tr -d '[:space:]') || return 1
  role_exists=$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname=$(sql_literal "$user")" | tr -d '[:space:]') || return 1
  [[ "$db_exists" != "1" ]] || { err "Database '$db' sudah ada."; return 1; }
  [[ "$role_exists" != "1" ]] || { err "Role '$user' sudah ada. Gunakan username lain atau kelola role tersebut secara manual."; return 1; }
  read -r -s -p "Password user baru (kosong = generate otomatis): " password; echo
  if [[ -z "$password" ]]; then
    password=$(openssl rand -hex 24)
  else
    read -r -s -p "Ulangi password: " password2; echo
    [[ "$password" == "$password2" ]] || { err "Password tidak cocok."; return 1; }
    (( ${#password} >= 12 )) || { err "Password minimal 12 karakter."; return 1; }
  fi

  # Password dikirim lewat stdin (bukan argumen proses) dan disembunyikan dari log.
  if ! psql_admin -q <<SQL
SET log_statement = 'none';
CREATE ROLE $(sql_ident "$user") LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD $(sql_literal "$password");
SQL
  then
    err "Gagal membuat role '$user'."; return 1
  fi
  if ! psql_admin -q <<SQL
CREATE DATABASE $(sql_ident "$db") OWNER $(sql_ident "$user") ENCODING 'UTF8' TEMPLATE template0;
REVOKE CONNECT, TEMPORARY ON DATABASE $(sql_ident "$db") FROM PUBLIC;
SQL
  then
    err "Gagal membuat database '$db'. Role '$user' dihapus kembali agar tidak menggantung."
    psql_admin -q -c "DROP DATABASE IF EXISTS $(sql_ident "$db");" >/dev/null 2>&1 || true
    psql_admin -q -c "DROP ROLE IF EXISTS $(sql_ident "$user");" >/dev/null 2>&1 || true
    return 1
  fi
  echo "Database berhasil dibuat."
  echo "Database : $db"
  echo "Username : $user"
  echo "Password : $password"
  echo "DSN      : postgresql://$user:<PASSWORD>@<HOST>:$POSTGRES_PORT/$db?sslmode=require"
  echo "Simpan password ini sekarang; password tidak disimpan ke file mana pun."
}

# ---------------------------------------------------------------------------
# BACKUP
# ---------------------------------------------------------------------------
BACKUP_CONF="$BASE_DIR/backup.conf"
R2_CONF="$BASE_DIR/r2.conf"
AUTO_DIR="$BACKUP_DIR/auto"
DOWNLOAD_DIR="$BACKUP_DIR/downloaded"
# Nama unit/cron unik per folder proyek, mis. /opt/postgres -> pgm-backup-opt-postgres
SCHED_ID=$(printf '%s' "${BASE_DIR#/}" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g')
SYSTEMD_UNIT="pgm-backup-${SCHED_ID}"
CRON_FILE="/etc/cron.d/pgm-backup-${SCHED_ID}"
RCLONE_IMAGE_DEFAULT="rclone/rclone:1.68.2"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Ruang kosong (byte) di filesystem tempat folder berada.
free_bytes() { df -PB1 "$1" | awk 'NR==2 {print $4}'; }

db_size_bytes() {
  psql_admin -tAc "SELECT pg_database_size($(sql_literal "$1"))" | tr -d '[:space:]'
}

# Backup satu database ke folder tujuan (default $BACKUP_DIR). Mencetak path file ke stdout.
do_backup() {
  local db=$1 dir=${2:-$BACKUP_DIR} ts file tmp size free
  mkdir -p "$dir"; chmod 700 "$dir"
  # Dump biasanya jauh lebih kecil dari ukuran database (terkompresi), tapi kalau
  # disk penuh, PostgreSQL di disk yang sama ikut bermasalah. Jadi cek dulu.
  size=$(db_size_bytes "$db") || return 1
  free=$(free_bytes "$dir")
  if [[ "$size" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] && (( free < size + 1073741824 )); then
    err "Ruang disk tidak cukup untuk backup '$db': sisa $(numfmt --to=iec "$free"), ukuran database $(numfmt --to=iec "$size") (+1GiB cadangan)."
    return 1
  fi
  ts=$(date +%Y%m%d-%H%M%S)
  file="$dir/${db}-${ts}.dump"
  [[ -e "$file" ]] && file="$dir/${db}-${ts}-$$.dump"
  tmp="$file.partial"
  log "Backup '$db' -> $file"
  if ! docker exec "$POSTGRES_CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$db" -Fc > "$tmp"; then
    rm -f -- "$tmp"; err "pg_dump '$db' gagal; file parsial dihapus."; return 1
  fi
  if ! docker exec -i "$POSTGRES_CONTAINER" pg_restore -l < "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"; err "File backup '$db' tidak valid; dihapus."; return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f -- "$tmp"; err "Gagal menyimpan $file"; return 1; }
  printf '%s\n' "$file"
}

# Role & atribut global (tidak ikut di pg_dump per database). Mencetak path file.
do_globals() {
  local dir=${1:-$BACKUP_DIR} gfile
  gfile="$dir/globals-$(date +%Y%m%d-%H%M%S).sql"
  if docker exec "$POSTGRES_CONTAINER" pg_dumpall -U "$POSTGRES_USER" --globals-only > "$gfile.partial" 2>/dev/null; then
    chmod 600 "$gfile.partial"; mv -f "$gfile.partial" "$gfile"
    log "Roles/globals -> $gfile"
    printf '%s\n' "$gfile"
  else
    rm -f -- "$gfile.partial"; err "Backup roles/globals gagal."; return 1
  fi
}

db_exists() {
  [[ "$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname=$(sql_literal "$1")" | tr -d '[:space:]')" == "1" ]]
}

# Database aplikasi: semua kecuali template & database sistem 'postgres'.
list_app_databases() {
  psql_admin -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres' ORDER BY datname"
}

backup_database() {
  require_running || return 1
  local db file failed=0 files=() up
  read -r -p "Nama database yang akan di-backup (kosong = semua database aplikasi): " db
  if [[ -z "$db" ]]; then
    local d dbs=()
    mapfile -t dbs < <(list_app_databases)
    for d in "${dbs[@]}"; do
      [[ -n "$d" ]] || continue
      if file=$(do_backup "$d"); then echo "OK    $file ($(du -h "$file" | cut -f1))"; files+=("$file"); else echo "GAGAL $d"; failed=1; fi
    done
  else
    valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
    db_exists "$db" || { err "Database '$db' tidak ditemukan."; return 1; }
    file=$(do_backup "$db") || return 1
    files+=("$file")
    echo "Backup selesai: $file ($(du -h "$file" | cut -f1))"
  fi
  if file=$(do_globals); then files+=("$file"); fi
  if (( ${#files[@]} > 0 )) && r2_configured; then
    read -r -p "Upload juga ke R2 (folder manual/)? [y/N]: " up
    if [[ "${up,,}" == "y" ]]; then
      r2_upload_files manual "${files[@]}" && echo "Upload ke R2 selesai." || { err "Upload ke R2 gagal; file lokal tetap ada."; failed=1; }
    fi
  elif ! r2_configured; then
    echo "Ingat: salin backup ke luar server secara berkala (atau atur R2 di menu 14)."
  fi
  (( failed == 0 ))
}

# ---------------------------------------------------------------------------
# CLOUDFLARE R2 (via rclone, default dijalankan sebagai container Docker)
# ---------------------------------------------------------------------------
load_r2_conf() {
  R2_ACCOUNT_ID="" R2_ACCESS_KEY_ID="" R2_SECRET_ACCESS_KEY="" R2_BUCKET=""
  R2_PREFIX="" R2_ENDPOINT="" R2_RETENTION_DAYS=30 R2_RCLONE="docker" R2_RCLONE_IMAGE=$RCLONE_IMAGE_DEFAULT
  [[ -f "$R2_CONF" ]] || return 1
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//[[:space:]]/}; value=${value//$'\r'/}
    case "$key" in
      R2_ACCOUNT_ID)        if [[ "$value" =~ ^[A-Za-z0-9]+$ ]]; then R2_ACCOUNT_ID=$value; fi ;;
      R2_ACCESS_KEY_ID)     if [[ "$value" =~ ^[A-Za-z0-9]+$ ]]; then R2_ACCESS_KEY_ID=$value; fi ;;
      R2_SECRET_ACCESS_KEY) if [[ "$value" =~ ^[A-Za-z0-9+/=]+$ ]]; then R2_SECRET_ACCESS_KEY=$value; fi ;;
      R2_BUCKET)            if [[ "$value" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]]; then R2_BUCKET=$value; fi ;;
      R2_PREFIX)            if [[ "$value" =~ ^[A-Za-z0-9._/-]*$ ]]; then R2_PREFIX=${value%/}; fi ;;
      R2_ENDPOINT)          if [[ "$value" =~ ^https?://[A-Za-z0-9.:-]+/?$ ]]; then R2_ENDPOINT=${value%/}; fi ;;
      R2_RETENTION_DAYS)    if [[ "$value" =~ ^[0-9]+$ ]]; then R2_RETENTION_DAYS=$value; fi ;;
      R2_RCLONE)            if [[ "$value" == "docker" || "$value" == "host" ]]; then R2_RCLONE=$value; fi ;;
      R2_RCLONE_IMAGE)      if [[ "$value" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then R2_RCLONE_IMAGE=$value; fi ;;
    esac
  done < "$R2_CONF"
  [[ -n "$R2_ENDPOINT" || -z "$R2_ACCOUNT_ID" ]] || R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  [[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" && -n "$R2_BUCKET" && -n "$R2_ENDPOINT" ]]
}

r2_configured() { load_r2_conf 2>/dev/null; }

# Lokasi tujuan di R2: r2:<bucket>/<prefix>/<sub>
r2_path() {
  local sub=$1 p=$R2_BUCKET
  [[ -n "$R2_PREFIX" ]] && p="$p/$R2_PREFIX"
  [[ -n "$sub" ]] && p="$p/$sub"
  printf 'r2:%s' "$p"
}

# Jalankan rclone dengan kredensial dari r2.conf. Kredensial tidak pernah masuk ke
# argumen proses: lewat env-file (Docker) atau environment subshell (host).
# Folder backup di-mount di path yang sama, jadi path lokal tidak perlu diterjemahkan.
rclone_run() {
  load_r2_conf || { err "Konfigurasi R2 belum lengkap ($R2_CONF)."; return 1; }
  local envf rc
  envf=$(mktemp "$BASE_DIR/.rclone-env.XXXXXX")
  chmod 600 "$envf"
  cat > "$envf" <<EOF
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
RCLONE_CONFIG_R2_ENDPOINT=$R2_ENDPOINT
RCLONE_CONFIG_R2_REGION=auto
RCLONE_CONFIG_R2_ACL=private
RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
RCLONE_CONFIG=/dev/null
EOF
  mkdir -p "$BACKUP_DIR"
  if [[ "$R2_RCLONE" == "host" ]]; then
    need_cmd rclone || { rm -f -- "$envf"; return 1; }
    ( set -a; while IFS='=' read -r k v; do printf -v "$k" '%s' "$v"; export "${k?}"; done < "$envf"; set +a
      rclone --retries 3 --low-level-retries 10 --stats 0 "$@" )
    rc=$?
  else
    docker run --rm --env-file "$envf" -v "$BACKUP_DIR:$BACKUP_DIR" "$R2_RCLONE_IMAGE" \
      --retries 3 --low-level-retries 10 --stats 0 "$@"
    rc=$?
  fi
  rm -f -- "$envf"
  return "$rc"
}

# Upload file tertentu ke r2:<bucket>/<prefix>/<sub>/
r2_upload_files() {
  local sub=$1 f rc=0; shift
  for f in "$@"; do
    log "Upload $(basename "$f") -> $(r2_path "$sub")/"
    rclone_run copyto "$f" "$(r2_path "$sub")/$(basename "$f")" || rc=1
  done
  return "$rc"
}

# Sinkronkan isi folder auto/ ke R2. mode=copy (lokal tetap) atau move (lokal dihapus
# SETELAH upload terverifikasi). File yang gagal di-upload tetap di lokal dan dicoba
# lagi pada run berikutnya.
r2_sync_auto() {
  local mode=$1
  [[ -d "$AUTO_DIR" ]] || return 0
  log "R2 $mode: $AUTO_DIR -> $(r2_path auto)"
  rclone_run "$mode" "$AUTO_DIR" "$(r2_path auto)" \
    --include '*.dump' --include 'globals-*.sql' --max-depth 1
}

# Retensi di R2: hapus objek di auto/ yang lebih tua dari N hari, tapi selalu sisakan
# objek terbaru per database dan file globals terbaru.
r2_prune() {
  local days=${1:-0} listing cutoff list_file name ts epoch key
  (( days > 0 )) || return 0
  listing=$(rclone_run lsf "$(r2_path auto)" --files-only --format "tp" --separator ";" 2>/dev/null) || { err "Gagal membaca daftar objek R2."; return 1; }
  [[ -n "$listing" ]] || return 0
  cutoff=$(( $(date +%s) - days * 86400 ))
  declare -A newest_ts=() newest_name=()
  local -a rows=()
  while IFS=';' read -r ts name; do
    [[ -n "$name" ]] || continue
    case "$name" in *.dump) key=$(sed -E 's/-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.dump$//' <<< "$name") ;; globals-*.sql) key="__globals__" ;; *) continue ;; esac
    epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
    rows+=("$epoch;$key;$name")
    if [[ -z "${newest_ts[$key]:-}" ]] || (( epoch > ${newest_ts[$key]} )); then
      newest_ts[$key]=$epoch; newest_name[$key]=$name
    fi
  done <<< "$listing"
  list_file=$(mktemp "$BACKUP_DIR/.r2-delete.XXXXXX")
  local r e k n count=0
  for r in "${rows[@]}"; do
    IFS=';' read -r e k n <<< "$r"
    (( e < cutoff )) || continue
    [[ "$n" == "${newest_name[$k]}" ]] && continue
    printf '%s\n' "$n" >> "$list_file"; count=$((count+1))
  done
  if (( count > 0 )); then
    log "R2: hapus $count backup lama (> $days hari)"
    rclone_run delete "$(r2_path auto)" --files-from-raw "$list_file" --max-depth 1 || { rm -f -- "$list_file"; return 1; }
  fi
  rm -f -- "$list_file"
}

r2_configure() {
  load_config || return 1
  load_r2_conf || true
  local acc key secret bucket prefix endpoint ret ret2="" engine
  cat <<'EOF'
=== Cloudflare R2 ===

LANGKAH 1 - Buat bucket
  Dashboard Cloudflare -> R2 Object Storage -> Create bucket.
  Isi nama (huruf kecil/angka/'-', mis. db-backup). Biarkan PRIVATE: jangan aktifkan
  "Public access" / r2.dev.

LANGKAH 2 - Catat Account ID
  Di halaman R2 Object Storage (Overview), bagian "Account Details" -> Account ID
  (32 karakter heksadesimal). Account ID juga terlihat di URL dashboard
  (dash.cloudflare.com/<ACCOUNT_ID>/...).

LANGKAH 3 - Buat API token
  R2 Object Storage -> "Manage API tokens" -> Create API Token
  ("Account API token" disarankan; "User API token" juga bisa):
    - Permissions      : Object Read & Write
    - Specify bucket(s): Apply to specific buckets only -> pilih bucket langkah 1
    - TTL              : Forever (atau sesuai kebijakan Anda)
  Klik Create, lalu salin "Access Key ID" dan "Secret Access Key".
  Secret hanya ditampilkan SEKALI; simpan sebelum menutup halaman.
  (Bagian "Token value" tidak dipakai di sini.)

Kosongkan isian untuk memakai nilai lama (jika ada).
EOF
  read -r -p "Account ID [${R2_ACCOUNT_ID:-}]: " acc; acc=${acc:-$R2_ACCOUNT_ID}
  [[ "$acc" =~ ^[A-Za-z0-9]+$ ]] || { err "Account ID tidak valid."; return 1; }
  read -r -p "Access Key ID [${R2_ACCESS_KEY_ID:+(tersimpan)}]: " key; key=${key:-$R2_ACCESS_KEY_ID}
  [[ "$key" =~ ^[A-Za-z0-9]+$ ]] || { err "Access Key ID tidak valid."; return 1; }
  read -r -s -p "Secret Access Key [${R2_SECRET_ACCESS_KEY:+(tersimpan)}]: " secret; echo; secret=${secret:-$R2_SECRET_ACCESS_KEY}
  [[ "$secret" =~ ^[A-Za-z0-9+/=]+$ ]] || { err "Secret Access Key tidak valid."; return 1; }
  read -r -p "Nama bucket [${R2_BUCKET:-}]: " bucket; bucket=${bucket:-$R2_BUCKET}
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { err "Nama bucket tidak valid (huruf kecil, angka, '-')."; return 1; }
  local def_prefix=${R2_PREFIX:-postgres/$(hostname -s 2>/dev/null || echo server)}
  read -r -p "Prefix/folder di bucket [$def_prefix]: " prefix; prefix=${prefix:-$def_prefix}; prefix=${prefix%/}; prefix=${prefix#/}
  [[ "$prefix" =~ ^[A-Za-z0-9._/-]*$ ]] || { err "Prefix tidak valid."; return 1; }
  local def_ep=${R2_ENDPOINT:-https://${acc}.r2.cloudflarestorage.com}
  echo "Endpoint (bucket jurisdiction EU: https://${acc}.eu.r2.cloudflarestorage.com)"
  read -r -p "Endpoint [$def_ep]: " endpoint; endpoint=${endpoint:-$def_ep}; endpoint=${endpoint%/}
  [[ "$endpoint" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || { err "Endpoint tidak valid."; return 1; }
  read -r -p "Retensi di R2, hari [${R2_RETENTION_DAYS:-30}] (0 = tidak pernah hapus): " ret; ret=${ret:-${R2_RETENTION_DAYS:-30}}
  [[ "$ret" =~ ^[0-9]+$ ]] || { err "Retensi harus angka."; return 1; }
  engine=${R2_RCLONE:-docker}
  if [[ "$engine" == "docker" ]] && command -v rclone >/dev/null 2>&1; then
    local rv rmaj rmin
    rv=$(rclone version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
    rmaj=${rv%%.*}; rmin=${rv#*.}
    if [[ "$rv" =~ ^[0-9]+\.[0-9]+$ ]] && (( rmaj > 1 || (rmaj == 1 && rmin >= 59) )); then
      read -r -p "rclone $rv terpasang di host. Pakai rclone host, bukan container? [y/N]: " ret2
      [[ "${ret2,,}" == "y" ]] && engine=host
    else
      echo "Catatan: rclone di host (versi ${rv:-?}) terlalu lama untuk R2 (butuh 1.59+); dipakai container rclone."
    fi
  fi

  local tmp; tmp=$(mktemp "$BASE_DIR/.r2conf.XXXXXX")
  cat > "$tmp" <<EOF
R2_ACCOUNT_ID=$acc
R2_ACCESS_KEY_ID=$key
R2_SECRET_ACCESS_KEY=$secret
R2_BUCKET=$bucket
R2_PREFIX=$prefix
R2_ENDPOINT=$endpoint
R2_RETENTION_DAYS=$ret
R2_RCLONE=$engine
R2_RCLONE_IMAGE=${R2_RCLONE_IMAGE:-$RCLONE_IMAGE_DEFAULT}
EOF
  chmod 600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$R2_CONF"
  echo "Tersimpan di $R2_CONF (permission 600)."
  r2_test
}

# Tes tulis -> baca -> hapus satu objek kecil.
r2_test() {
  load_r2_conf || { err "R2 belum dikonfigurasi."; return 1; }
  local probe
  mkdir -p "$BACKUP_DIR"
  probe=$(mktemp "$BACKUP_DIR/.r2-test.XXXXXX")
  echo "qolcore r2 test $(date -u +%FT%TZ)" > "$probe"
  echo "Tes koneksi ke $(r2_path "") ..."
  if rclone_run copyto "$probe" "$(r2_path "")/.r2-test" \
     && rclone_run lsf "$(r2_path "")" --files-only --include .r2-test | grep -qx '.r2-test' \
     && rclone_run deletefile "$(r2_path "")/.r2-test"; then
    rm -f -- "$probe"; echo "Koneksi R2 OK (tulis, baca, hapus berhasil)."
  else
    rm -f -- "$probe"; err "Tes R2 gagal. Periksa Account ID, key, bucket, dan izin token."; return 1
  fi
}

r2_browse_download() {
  load_r2_conf || { err "R2 belum dikonfigurasi."; return 1; }
  local sub listing pick name i=0 files=()
  read -r -p "Folder di R2: 1) auto  2) manual [1]: " sub
  [[ "$sub" == "2" ]] && sub=manual || sub=auto
  listing=$(rclone_run lsf "$(r2_path "$sub")" --files-only --format "tsp" --separator ";" | sort -r | head -n 30) || return 1
  [[ -n "$listing" ]] || { echo "Tidak ada file di $(r2_path "$sub")."; return 0; }
  echo "30 file terbaru di $(r2_path "$sub"):"
  while IFS=';' read -r ts size name; do
    i=$((i+1)); files+=("$name")
    printf '  %2d. %s  %10s  %s\n' "$i" "$ts" "$(numfmt --to=iec "$size" 2>/dev/null || echo "$size")" "$name"
  done <<< "$listing"
  read -r -p "Nomor file yang di-download (kosong = batal): " pick
  [[ -n "$pick" ]] || return 0
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#files[@]} )) || { err "Pilihan tidak valid."; return 1; }
  name=${files[$((pick-1))]}
  mkdir -p "$DOWNLOAD_DIR"; chmod 700 "$DOWNLOAD_DIR"
  rclone_run copyto "$(r2_path "$sub")/$name" "$DOWNLOAD_DIR/$name" || { err "Download gagal."; return 1; }
  chmod 600 "$DOWNLOAD_DIR/$name"
  echo "Tersimpan: $DOWNLOAD_DIR/$name"
  [[ "$name" == *.dump ]] && echo "Untuk restore: menu 7, masukkan path di atas."
  return 0
}

# --- Konfigurasi auto backup (dibaca sebagai data, bukan di-source) ---------
load_backup_conf() {
  BACKUP_DATABASES="all"; BACKUP_RETENTION_DAYS=14; BACKUP_TIME="02:30"; BACKUP_TARGET="local"
  [[ -f "$BACKUP_CONF" ]] || return 0
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//[[:space:]]/}; value=${value//$'\r'/}
    case "$key" in
      BACKUP_DATABASES)      if [[ "$value" =~ ^[A-Za-z0-9_,]+$ ]]; then BACKUP_DATABASES=$value; fi ;;
      BACKUP_RETENTION_DAYS) if [[ "$value" =~ ^[0-9]+$ ]]; then BACKUP_RETENTION_DAYS=$value; fi ;;
      BACKUP_TIME)           if [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then BACKUP_TIME=$value; fi ;;
      BACKUP_TARGET)         if [[ "$value" =~ ^(local|r2|both)$ ]]; then BACKUP_TARGET=$value; fi ;;
    esac
  done < "$BACKUP_CONF"
}

target_label() {
  case "$1" in
    local) echo "lokal saja" ;;
    r2)    echo "R2 saja (file lokal dihapus setelah upload berhasil)" ;;
    both)  echo "lokal + R2" ;;
  esac
}

# Hapus backup otomatis lokal yang lebih tua dari N hari, tapi SELALU sisakan file
# terbaru tiap database (supaya tidak pernah habis walau backup sempat gagal lama).
prune_backups() {
  local days=$1 db f newest dbs=()
  (( days > 0 )) || return 0
  [[ -d "${AUTO_DIR:?}" ]] || return 0
  find "${AUTO_DIR:?}" -maxdepth 1 -type f -name '*.partial' -mmin +360 -delete 2>/dev/null || true
  mapfile -t dbs < <(find "${AUTO_DIR:?}" -maxdepth 1 -type f -name '*.dump' -printf '%f\n' \
                     | sed -E 's/-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.dump$//' | sort -u)
  for db in "${dbs[@]}"; do
    valid_dbname "$db" || continue
    newest=$(find "${AUTO_DIR:?}" -maxdepth 1 -type f -name "${db}-*.dump" -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
    while IFS= read -r f; do
      [[ -n "$f" && "$f" != "$newest" ]] || continue
      rm -f -- "$f" && log "Hapus backup lama: $f"
    done < <(find "${AUTO_DIR:?}" -maxdepth 1 -type f -name "${db}-*.dump" -mmin +"$((days * 1440))")
  done
  newest=$(find "${AUTO_DIR:?}" -maxdepth 1 -type f -name 'globals-*.sql' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != "$newest" ]] || continue
    rm -f -- "$f"
  done < <(find "${AUTO_DIR:?}" -maxdepth 1 -type f -name 'globals-*.sql' -mmin +"$((days * 1440))")
}

# Dipanggil oleh scheduler: `postgres-manager backup-auto`. Non-interaktif.
backup_auto() {
  local db failed=0 ok=0 dbs=() upload_ok=1
  # Kunci pada folder itu sendiri (dibuka read-only): tidak ada file lock yang bisa
  # dibelokkan lewat symlink untuk menimpa file lain sebagai root.
  exec 9<"$BASE_DIR"
  flock -n 9 || { err "Backup lain sedang berjalan; dilewati."; return 1; }
  base_dir_safe || return 1
  load_config || return 1
  container_running || { err "Container '$POSTGRES_CONTAINER' tidak berjalan."; return 1; }
  load_backup_conf
  if [[ "$BACKUP_TARGET" != "local" ]] && ! r2_configured; then
    err "Target '$BACKUP_TARGET' butuh R2, tetapi $R2_CONF belum lengkap. Backup tetap disimpan lokal."
    failed=1; upload_ok=0
  fi
  if [[ "$BACKUP_DATABASES" == "all" ]]; then
    mapfile -t dbs < <(list_app_databases)
  else
    IFS=',' read -r -a dbs <<< "$BACKUP_DATABASES"
  fi
  (( ${#dbs[@]} > 0 )) || { err "Tidak ada database untuk di-backup (atau gagal membaca daftar database)."; return 1; }
  log "Auto backup mulai: ${dbs[*]} (target: $(target_label "$BACKUP_TARGET"))"
  for db in "${dbs[@]}"; do
    [[ -n "$db" ]] || continue
    if ! valid_dbname "$db" || ! db_exists "$db"; then
      err "Database '$db' tidak ditemukan; dilewati."; failed=1; continue
    fi
    if do_backup "$db" "$AUTO_DIR" >/dev/null; then ok=$((ok+1)); else failed=1; fi
  done
  do_globals "$AUTO_DIR" >/dev/null || failed=1

  # Upload dulu, baru retensi lokal: file yang belum ter-upload tidak dihapus duluan.
  if [[ "$BACKUP_TARGET" != "local" ]] && r2_configured; then
    upload_ok=0
    local mode=copy
    [[ "$BACKUP_TARGET" == "r2" ]] && mode=move
    if r2_sync_auto "$mode"; then
      upload_ok=1
      log "Upload R2 berhasil."
      r2_prune "$R2_RETENTION_DAYS" || failed=1
    else
      err "Upload ke R2 gagal; file tetap disimpan lokal dan akan dicoba lagi pada run berikutnya."
      failed=1
    fi
  fi
  # Retensi lokal hanya kalau ada backup baru yang berhasil.
  if (( ok > 0 )) && (( upload_ok )); then
    prune_backups "$BACKUP_RETENTION_DAYS"
  elif (( ok > 0 )); then
    log "Retensi lokal dilewati: upload R2 gagal, backup lokal lama disimpan sampai berhasil ter-upload."
  fi
  if (( failed == 0 )); then
    log "Auto backup selesai: $ok database OK"
  else
    log "Auto backup selesai: $ok database di-dump, ADA YANG GAGAL"
  fi
  return "$failed"
}

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

schedule_status() {
  load_backup_conf
  echo "Konfigurasi : database=$BACKUP_DATABASES, jam=$BACKUP_TIME, retensi lokal=$BACKUP_RETENTION_DAYS hari"
  echo "Target      : $(target_label "$BACKUP_TARGET")"
  if r2_configured; then
    echo "R2          : $(r2_path "") (retensi $R2_RETENTION_DAYS hari, rclone: $R2_RCLONE)"
  else
    echo "R2          : belum dikonfigurasi"
  fi
  if tg_configured; then
    echo "Telegram    : aktif (kirim saat: $([[ "$TG_NOTIFY" == always ]] && echo 'setiap backup' || echo 'gagal saja'))"
  else
    echo "Telegram    : belum dikonfigurasi"
  fi
  echo "Folder lokal: $AUTO_DIR"
  if has_systemd && systemctl is-enabled "$SYSTEMD_UNIT.timer" >/dev/null 2>&1; then
    echo "Scheduler   : systemd timer AKTIF"
    systemctl list-timers "$SYSTEMD_UNIT.timer" --no-pager 2>/dev/null | head -n2 || true
    echo "Hasil terakhir: $(systemctl show -p Result --value "$SYSTEMD_UNIT.service" 2>/dev/null || true)"
  elif [[ -f "$CRON_FILE" ]]; then
    echo "Scheduler   : cron AKTIF ($CRON_FILE)"
  else
    echo "Scheduler   : TIDAK AKTIF"
  fi
  if [[ -d "$AUTO_DIR" ]]; then
    echo "Backup lokal terbaru:"
    find "$AUTO_DIR" -maxdepth 1 -type f -name '*.dump' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' | sort -r | head -n 5 | sed 's/^/  /'
  fi
}

schedule_enable() {
  load_config || return 1
  load_backup_conf
  local t r d hh mm tg
  read -r -p "Jam backup harian (HH:MM, zona waktu server) [$BACKUP_TIME]: " t; t=${t:-$BACKUP_TIME}
  [[ "$t" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { err "Format jam harus HH:MM."; return 1; }
  hh=${BASH_REMATCH[1]}; mm=${BASH_REMATCH[2]}
  echo "Database: 'all' = semua database aplikasi (termasuk yang dibuat nanti), atau daftar dipisah koma."
  read -r -p "Database [$BACKUP_DATABASES]: " d; d=${d:-$BACKUP_DATABASES}
  d=${d// /}
  [[ "$d" == "all" || "$d" =~ ^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$ ]] || { err "Daftar database tidak valid."; return 1; }
  echo "Tujuan backup:"
  echo "  1. Lokal saja"
  echo "  2. R2 saja   (dump dibuat lokal sementara, dihapus setelah upload berhasil)"
  echo "  3. Lokal + R2"
  local cur=1; [[ "$BACKUP_TARGET" == "r2" ]] && cur=2; [[ "$BACKUP_TARGET" == "both" ]] && cur=3
  read -r -p "Pilihan [$cur]: " tg; tg=${tg:-$cur}
  case "$tg" in 1) tg=local ;; 2) tg=r2 ;; 3) tg=both ;; *) err "Pilihan tidak valid."; return 1 ;; esac
  if [[ "$tg" != "local" ]] && ! r2_configured; then
    echo "R2 belum dikonfigurasi. Isi kredensial R2 sekarang:"
    r2_configure || { err "Konfigurasi R2 gagal; jadwal tidak diubah."; return 1; }
  fi
  if [[ "$tg" == "r2" ]]; then
    r=$BACKUP_RETENTION_DAYS
  else
    read -r -p "Simpan backup lokal berapa hari [$BACKUP_RETENTION_DAYS] (0 = tidak pernah hapus): " r; r=${r:-$BACKUP_RETENTION_DAYS}
    [[ "$r" =~ ^[0-9]+$ ]] || { err "Retensi harus angka."; return 1; }
  fi

  printf 'BACKUP_DATABASES=%s\nBACKUP_RETENTION_DAYS=%s\nBACKUP_TIME=%s\nBACKUP_TARGET=%s\n' "$d" "$r" "$t" "$tg" > "$BACKUP_CONF"
  chmod 600 "$BACKUP_CONF"; chown root:root "$BACKUP_CONF"
  mkdir -p "$AUTO_DIR"; chmod 700 "$AUTO_DIR"

  # Scheduler menjalankan SALINAN script milik root, bukan file di folder user,
  # supaya file yang bisa diedit user biasa tidak pernah dieksekusi sebagai root.
  install -o root -g root -m 0755 "$SCRIPT_PATH" "$INSTALLED_BIN"
  echo "Script dipasang ke $INSTALLED_BIN"

  if has_systemd; then
    rm -f -- "$CRON_FILE"
    cat > "/etc/systemd/system/$SYSTEMD_UNIT.service" <<EOF
[Unit]
Description=PostgreSQL auto backup ($BASE_DIR)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
Environment=PGM_BASE_DIR=$BASE_DIR
ExecStart=$INSTALLED_BIN backup-auto
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
    cat > "/etc/systemd/system/$SYSTEMD_UNIT.timer" <<EOF
[Unit]
Description=Jadwal PostgreSQL auto backup ($BASE_DIR)

[Timer]
OnCalendar=*-*-* $hh:$mm:00
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/$SYSTEMD_UNIT.service" "/etc/systemd/system/$SYSTEMD_UNIT.timer"
    systemctl daemon-reload
    systemctl enable --now "$SYSTEMD_UNIT.timer"
    echo "Systemd timer aktif setiap hari jam $t, tujuan: $(target_label "$tg")."
    echo "Jika server mati saat jadwal, backup dijalankan begitu server hidup lagi."
  else
    cat > "$CRON_FILE" <<EOF
# Dibuat oleh postgres-manager
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$((10#$mm)) $((10#$hh)) * * * root PGM_BASE_DIR=$BASE_DIR $INSTALLED_BIN backup-auto >> $AUTO_DIR/backup.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo "Cron aktif setiap hari jam $t, tujuan: $(target_label "$tg") (log: $AUTO_DIR/backup.log)"
  fi
  echo
  echo "Catatan: jika postgres-manager.sh diperbarui, jalankan menu ini lagi agar salinan"
  echo "di $INSTALLED_BIN ikut diperbarui."
}

schedule_disable() {
  if has_systemd; then
    systemctl disable --now "$SYSTEMD_UNIT.timer" 2>/dev/null || true
    rm -f -- "/etc/systemd/system/$SYSTEMD_UNIT.timer" "/etc/systemd/system/$SYSTEMD_UNIT.service"
    systemctl daemon-reload
  fi
  rm -f -- "$CRON_FILE"
  echo "Auto backup dinonaktifkan. File backup yang sudah ada (lokal & R2) tidak dihapus."
}

schedule_logs() {
  if has_systemd; then
    journalctl -u "$SYSTEMD_UNIT.service" -n 50 --no-pager
  elif [[ -f "$AUTO_DIR/backup.log" ]]; then
    tail -n 50 "$AUTO_DIR/backup.log"
  else
    echo "Belum ada log."
  fi
}

schedule_menu() {
  local c
  schedule_status
  echo
  echo "  1. Aktifkan / ubah jadwal & tujuan (lokal / R2 / lokal + R2)"
  echo "  2. Nonaktifkan jadwal"
  echo "  3. Jalankan auto backup sekarang (tes)"
  echo "  4. Lihat log auto backup"
  echo "  5. Atur kredensial Cloudflare R2"
  echo "  6. Tes koneksi R2"
  echo "  7. Lihat & download backup dari R2"
  echo "  8. Atur notifikasi Telegram"
  echo "  9. Tes notifikasi Telegram"
  echo " 10. Matikan notifikasi Telegram"
  echo "  0. Kembali"
  read -r -p "Pilihan: " c
  case "$c" in
    1) schedule_enable ;;
    2) schedule_disable ;;
    3) backup_auto_notify ;;
    4) schedule_logs ;;
    5) r2_configure ;;
    6) r2_test ;;
    7) r2_browse_download ;;
    8) tg_configure ;;
    9) tg_test ;;
    10) tg_disable ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# NOTIFIKASI TELEGRAM
# ---------------------------------------------------------------------------
TG_CONF="$BASE_DIR/telegram.conf"
TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"

load_tg_conf() {
  TG_BOT_TOKEN="" TG_CHAT_ID="" TG_NOTIFY="fail"
  [[ -f "$TG_CONF" ]] || return 1
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//[[:space:]]/}; value=${value//$'\r'/}
    case "$key" in
      TG_BOT_TOKEN) if [[ "$value" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then TG_BOT_TOKEN=$value; fi ;;
      TG_CHAT_ID)   if [[ "$value" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]]; then TG_CHAT_ID=$value; fi ;;
      TG_NOTIFY)    if [[ "$value" == "fail" || "$value" == "always" ]]; then TG_NOTIFY=$value; fi ;;
    esac
  done < "$TG_CONF"
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]
}

tg_configured() { load_tg_conf 2>/dev/null; }

# Kirim pesan. Token hanya lewat stdin curl (-K -), tidak muncul di daftar proses.
tg_send() {
  local text=$1
  load_tg_conf || { err "Telegram belum dikonfigurasi."; return 1; }
  command -v curl >/dev/null 2>&1 || { err "curl tidak tersedia; notifikasi Telegram tidak bisa dikirim."; return 1; }
  (( ${#text} <= 4000 )) || text="${text:0:3990}…"
  local resp
  resp=$(printf 'url = "%s/bot%s/sendMessage"\n' "$TG_API_BASE" "$TG_BOT_TOKEN" \
    | curl -sS --max-time 20 -K - \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$text" \
        --data-urlencode "disable_web_page_preview=true" 2>&1) || { err "Gagal menghubungi Telegram: $resp"; return 1; }
  if ! grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$resp"; then
    err "Telegram menolak pesan: $(sed -nE 's/.*"description"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$resp" | head -n1)"
    return 1
  fi
}

# Panggil Bot API. Token hanya lewat stdin curl (-K -), tidak muncul di daftar proses.
tg_call() {
  local token=$1 method=$2; shift 2
  command -v curl >/dev/null 2>&1 || { echo '{"ok":false,"description":"curl tidak tersedia di server"}'; return 0; }
  printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$token" "$method" \
    | curl -sS --max-time 20 -K - "$@" 2>&1 || true
}

tg_ok() { grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$1"; }
tg_desc() { sed -nE 's/.*"description"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$1" | head -n1; }

# Daftar chat yang pernah mengirim pesan ke bot: "<chat_id><TAB><jenis><TAB><nama>".
tg_find_chats() {
  local token=$1 resp
  resp=$(tg_call "$token" getUpdates --data-urlencode "allowed_updates=[\"message\",\"channel_post\",\"my_chat_member\"]")
  if ! tg_ok "$resp"; then
    echo "ERR	$(tg_desc "$resp")"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { echo "ERR	python3 tidak tersedia untuk membaca daftar chat"; return 0; }
  python3 -c '
import json, sys
d = json.load(sys.stdin)
seen = {}
for u in d.get("result", []):
    for k in ("message", "edited_message", "channel_post", "edited_channel_post", "my_chat_member"):
        m = u.get(k)
        if m and "chat" in m:
            c = m["chat"]
            name = c.get("title") or " ".join(x for x in (c.get("first_name"), c.get("last_name")) if x) or c.get("username") or "-"
            if c.get("username") and c.get("type") != "private":
                name += " (@" + c["username"] + ")"
            seen[c["id"]] = (c.get("type", "?"), name)
for cid, (t, n) in seen.items():
    print("%s\t%s\t%s" % (cid, t, n.replace("\t", " ")))
' <<< "$resp"
}

tg_configure() {
  load_tg_conf || true
  command -v curl >/dev/null 2>&1 || { err "curl belum terpasang di server. Pasang dulu (mis. sudo apt install curl), lalu ulangi."; return 1; }
  local token chat mode resp botname rows=() r i pick
  cat <<'EOF'
=== Notifikasi Telegram ===

LANGKAH 1 - Buat bot & ambil token
  1. Buka Telegram, cari @BotFather (akun resmi, ada centang biru), tekan Start.
  2. Kirim perintah:  /newbot
  3. Isi nama bot (bebas, mis. "Backup Server DB").
  4. Isi username bot, harus diakhiri "bot" (mis. qolcore_backup_bot).
  5. BotFather membalas dengan token seperti:
        123456789:AAH4xYz...panjang...
     Salin token itu. RAHASIAKAN: siapa pun yang punya token bisa memakai bot Anda.
     Jika token bocor, kirim /revoke ke @BotFather untuk membuat token baru.

LANGKAH 2 - Ke mana notifikasi dikirim (pilih salah satu)
  - Chat pribadi : buka bot Anda (link t.me/<username_bot> dari BotFather),
                   tekan Start atau kirim pesan apa saja.
  - Grup         : tambahkan bot ke grup, lalu kirim di grup:  /start@<username_bot>
  - Channel      : jadikan bot ADMIN channel (izin "Post messages"),
                   lalu buat satu postingan di channel.
  Bot tidak bisa mengirim pesan ke Anda sebelum langkah 2 dilakukan.

LANGKAH 3 - Script mencari chat ID otomatis dari pesan di langkah 2.
EOF
  echo
  read -r -s -p "Tempel bot token${TG_BOT_TOKEN:+ (kosong = pakai yang tersimpan)}: " token; echo
  token=${token:-$TG_BOT_TOKEN}
  token=${token//[[:space:]]/}
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { err "Format token tidak valid. Contoh: 123456789:AAH4xYz... (angka, titik dua, lalu huruf/angka)."; return 1; }
  resp=$(tg_call "$token" getMe)
  if ! tg_ok "$resp"; then
    err "Token ditolak Telegram: $(tg_desc "$resp")"
    err "Periksa token (salin ulang dari @BotFather) dan pastikan server bisa mengakses api.telegram.org."
    return 1
  fi
  botname=$(sed -nE 's/.*"username"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$resp" | head -n1)
  echo "Token valid. Bot: @${botname:-?}"

  while true; do
    echo
    echo "Pastikan langkah 2 sudah dilakukan (kirim pesan ke @${botname:-bot} / /start@${botname:-bot} di grup)."
    if [[ -n "$TG_CHAT_ID" ]]; then
      read -r -p "Enter = cari chat otomatis | ketik chat ID manual | '-' = pakai yang tersimpan ($TG_CHAT_ID): " chat
    else
      read -r -p "Enter = cari chat otomatis | atau ketik chat ID manual: " chat
    fi
    [[ -z "$chat" ]] || break
    mapfile -t rows < <(tg_find_chats "$token")
    if (( ${#rows[@]} > 0 )) && [[ "${rows[0]}" == ERR* ]]; then
      local why=${rows[0]#ERR	}
      err "Tidak bisa membaca pesan bot: $why"
      [[ "$why" == *webhook* ]] && err "Bot ini memakai webhook (dipakai aplikasi lain). Ketik chat ID manual, atau pakai bot terpisah khusus notifikasi."
      rows=()
    fi
    if (( ${#rows[@]} == 0 )); then
      echo "Belum ada chat yang ditemukan. Kirim pesan ke bot dulu (langkah 2), lalu coba lagi."
      echo "Catatan: Telegram hanya menyimpan pesan bot selama 24 jam terakhir."
      continue
    fi
    echo "Chat yang ditemukan:"
    i=0
    for r in "${rows[@]}"; do
      i=$((i+1)); IFS=$'\t' read -r cid ctype cname <<< "$r"
      printf '  %d. %-16s %-10s %s\n' "$i" "$cid" "$ctype" "$cname"
    done
    read -r -p "Pilih nomor chat (kosong = cari ulang): " pick
    [[ -n "$pick" ]] || continue
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#rows[@]} )); then
      chat=$(cut -f1 <<< "${rows[$((pick-1))]}")
      break
    fi
    echo "Pilihan tidak valid."
  done
  if [[ "$chat" == "-" ]]; then chat=$TG_CHAT_ID; fi
  [[ "$chat" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]] || { err "Chat ID tidak valid (angka; grup/channel diawali -100; atau @namachannel)."; return 1; }

  echo
  echo "Kirim notifikasi kapan?"
  echo "  1. Hanya jika auto backup gagal"
  echo "  2. Setiap auto backup (berhasil maupun gagal)"
  local cur=1; [[ "$TG_NOTIFY" == "always" ]] && cur=2
  read -r -p "Pilihan [$cur]: " mode; mode=${mode:-$cur}
  case "$mode" in 1) mode=fail ;; 2) mode=always ;; *) err "Pilihan tidak valid."; return 1 ;; esac
  local tmp; tmp=$(mktemp "$BASE_DIR/.tgconf.XXXXXX")
  printf 'TG_BOT_TOKEN=%s\nTG_CHAT_ID=%s\nTG_NOTIFY=%s\n' "$token" "$chat" "$mode" > "$tmp"
  chmod 600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$TG_CONF"
  echo "Tersimpan di $TG_CONF (permission 600)."
  tg_test
}

tg_test() {
  tg_send "✅ Tes notifikasi PostgreSQL manager
Host: $(hostname -s 2>/dev/null || echo '?')
Folder: $BASE_DIR" && echo "Pesan tes terkirim. Cek Telegram Anda."
}

tg_disable() {
  if [[ -f "$TG_CONF" ]]; then
    rm -f -- "$TG_CONF"
    echo "Notifikasi Telegram dimatikan ($TG_CONF dihapus)."
  else
    echo "Notifikasi Telegram belum aktif."
  fi
}

# Jalankan auto backup, simpan log-nya, lalu kirim ringkasan ke Telegram sesuai pengaturan.
backup_auto_notify() {
  local logf rc
  logf=$(mktemp)
  set +e
  ( set -e; backup_auto ) 2>&1 | tee "$logf"
  rc=${PIPESTATUS[0]}
  set -e
  # backup_auto berjalan di subshell; muat ulang konfigurasi untuk isi pesan.
  load_config >/dev/null 2>&1 || true
  if tg_configured && { (( rc != 0 )) || [[ "$TG_NOTIFY" == "always" ]]; }; then
    local status icon body cert_warn
    if (( rc == 0 )); then icon="✅"; status="BERHASIL"; else icon="❌"; status="GAGAL"; fi
    body=$(grep -E 'Backup |GAGAL|ERROR|gagal|selesai|R2|Hapus' "$logf" | sed -E 's/^\[[0-9-]+ ([0-9:]+)\] /\1 /' | tail -n 25)
    cert_warn=$(cert_expiry_warning 2>/dev/null || true)
    tg_send "$icon Auto backup PostgreSQL $status
Host: $(hostname -s 2>/dev/null || echo '?')
Folder: $BASE_DIR
Container: ${POSTGRES_CONTAINER:-?}
${cert_warn:+⚠️ $cert_warn
}
$body" >/dev/null || echo "Peringatan: notifikasi Telegram gagal dikirim." >&2
  fi
  rm -f -- "$logf"
  return "$rc"
}

# ---------------------------------------------------------------------------
# UNINSTALL INSTANCE
# ---------------------------------------------------------------------------
# Hapus path di dalam folder proyek saja (pengaman tambahan untuk rm -rf).
safe_rm_in_base() {
  local p
  for p in "$@"; do
    [[ -n "$p" && "$p" == "$BASE_DIR"/* && "$p" != *"/../"* && "$p" != *"/.." ]] || { err "Menolak menghapus path di luar folder proyek: '$p'"; return 1; }
    [[ -e "$p" || -L "$p" ]] || continue
    rm -rf -- "${p:?}"
  done
}

uninstall_instance() {
  load_config || return 1
  local final_bk="" del_data="" del_backups="" confirm="" others=""
  local -a cfg_files=(.env compose.yaml certs config backup.conf r2.conf telegram.conf)
  echo "=== Uninstall instance PostgreSQL ==="
  echo "Folder    : $BASE_DIR"
  echo "Container : $POSTGRES_CONTAINER"
  echo
  echo "Yang SELALU dilakukan:"
  echo "  - Menghentikan & menghapus container (docker compose down)"
  echo "  - Mematikan jadwal auto backup instance ini"
  echo "Yang opsional (ditanya satu per satu):"
  echo "  - Backup terakhir semua database sebelum uninstall"
  echo "  - Menghapus data database (data/) beserta konfigurasi (.env, compose.yaml, dll.)"
  echo "  - Menghapus folder backups/"
  echo "Script ini sendiri ($(basename "$SCRIPT_PATH")) tidak dihapus. Backup di R2 tidak disentuh."
  echo

  if container_running; then
    read -r -p "Buat backup terakhir semua database dulu? [Y/n]: " final_bk
    if [[ "${final_bk,,}" != "n" ]]; then
      local d f failed=0 dbs=()
      mapfile -t dbs < <(list_app_databases)
      for d in "${dbs[@]}"; do
        [[ -n "$d" ]] || continue
        if f=$(do_backup "$d"); then echo "OK    $f"; else echo "GAGAL $d"; failed=1; fi
      done
      do_globals >/dev/null || failed=1
      if (( failed )); then
        read -r -p "Sebagian backup gagal. Tetap lanjut uninstall? [y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] || { echo "Dibatalkan."; return 0; }
      fi
    fi
  else
    echo "Catatan: container tidak berjalan, backup terakhir tidak bisa dibuat."
  fi

  read -r -p "Hapus juga DATA database (data/) dan konfigurasinya? Tidak bisa dibatalkan. [y/N]: " del_data
  if [[ "${del_data,,}" == "y" ]]; then
    read -r -p "Hapus juga folder backups/ (termasuk semua backup lokal)? [y/N]: " del_backups
  fi

  echo
  echo "Ringkasan:"
  echo "  - Container $POSTGRES_CONTAINER dihentikan & dihapus"
  echo "  - Jadwal auto backup dimatikan"
  if [[ "${del_data,,}" == "y" ]]; then
    echo "  - DIHAPUS: data/ dan ${cfg_files[*]}"
  else
    echo "  - Data & konfigurasi DISIMPAN (bisa dijalankan lagi dengan menu 2)"
  fi
  [[ "${del_backups,,}" == "y" ]] && echo "  - DIHAPUS: backups/"
  read -r -p "Ketik nama container ($POSTGRES_CONTAINER) untuk melanjutkan: " confirm
  [[ "$confirm" == "$POSTGRES_CONTAINER" ]] || { echo "Dibatalkan."; return 0; }
  if [[ "${del_data,,}" == "y" ]]; then
    read -r -p "Ketik HAPUS DATA untuk konfirmasi penghapusan data: " confirm
    [[ "$confirm" == "HAPUS DATA" ]] || { echo "Dibatalkan (tidak ada yang diubah)."; return 0; }
  fi

  log "Mematikan jadwal auto backup"
  schedule_disable >/dev/null 2>&1 || true
  log "docker compose down"
  (cd "$BASE_DIR" && docker compose down --remove-orphans) || { err "docker compose down gagal; tidak ada data yang dihapus."; return 1; }

  # Salinan script untuk scheduler dihapus hanya jika tidak ada instance lain yang memakainya.
  others=$(ls /etc/systemd/system/pgm-backup-*.timer /etc/cron.d/pgm-backup-* 2>/dev/null || true)
  if [[ -z "$others" && -f "$INSTALLED_BIN" ]]; then
    rm -f -- "$INSTALLED_BIN" && log "Hapus $INSTALLED_BIN (tidak dipakai instance lain)"
  fi

  if [[ "${del_data,,}" == "y" ]]; then
    local -a targets=("$BASE_DIR/data")
    local c
    for c in "${cfg_files[@]}"; do targets+=("$BASE_DIR/$c"); done
    log "Menghapus data & konfigurasi"
    safe_rm_in_base "${targets[@]}" || return 1
    rm -f -- "$BASE_DIR"/.backup.lock
  fi
  if [[ "${del_backups,,}" == "y" ]]; then
    log "Menghapus backups/"
    safe_rm_in_base "$BACKUP_DIR" || return 1
  fi
  echo
  echo "Uninstall selesai."
  if [[ "${del_data,,}" == "y" ]]; then
    echo "Folder $BASE_DIR siap dipakai untuk setup baru (menu 1)."
  else
    echo "Data tetap di $BASE_DIR/data. Jalankan menu 2 untuk menyalakan lagi."
  fi
  [[ "${del_backups,,}" == "y" ]] || echo "Backup lokal tetap di $BACKUP_DIR."
  echo "Image Docker tidak dihapus; hapus manual jika perlu: docker image rm <image>"
}

# ---------------------------------------------------------------------------
# HAPUS DATABASE + ROLE
# ---------------------------------------------------------------------------
drop_database() {
  require_running || return 1
  local db owner conns force="" pre confirm drop_role="" others super kill
  echo "Database aplikasi:"
  list_app_databases | sed 's/^/  - /'
  read -r -p "Nama database yang akan DIHAPUS: " db
  valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
  db_exists "$db" || { err "Database '$db' tidak ditemukan."; return 1; }
  case "$db" in postgres|template0|template1) err "Database sistem tidak boleh dihapus."; return 1 ;; esac
  [[ "$db" != "$POSTGRES_DB" ]] || { err "'$db' adalah database utama admin (POSTGRES_DB) yang dipakai script untuk koneksi; tidak bisa dihapus dari menu ini."; return 1; }

  owner=$(psql_admin -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=$(sql_literal "$db")" | tr -d '[:space:]')
  conns=$(psql_admin -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname=$(sql_literal "$db")" | tr -d '[:space:]')
  echo "Owner           : $owner"
  echo "Koneksi aktif   : $conns"
  if [[ "$conns" =~ ^[0-9]+$ ]] && (( conns > 0 )); then
    read -r -p "Ada $conns koneksi aktif. Putuskan semuanya saat menghapus? [y/N]: " kill
    [[ "${kill,,}" == "y" ]] || { echo "Dibatalkan. Hentikan aplikasi yang memakai '$db' dulu."; return 0; }
    force=1
  fi
  if [[ -n "$owner" && "$owner" != "$POSTGRES_USER" ]]; then
    super=$(psql_admin -tAc "SELECT rolsuper FROM pg_roles WHERE rolname=$(sql_literal "$owner")" | tr -d '[:space:]')
    others=$(psql_admin -tAc "SELECT string_agg(datname, ', ') FROM pg_database WHERE pg_get_userbyid(datdba)=$(sql_literal "$owner") AND datname <> $(sql_literal "$db")" | sed 's/^ *//;s/ *$//')
    if [[ "$super" == "t" ]]; then
      echo "Role '$owner' adalah superuser; tidak ditawarkan untuk dihapus."
    elif [[ -n "$others" ]]; then
      echo "Role '$owner' juga pemilik database lain ($others); role tidak dihapus."
    else
      read -r -p "Hapus juga role/user '$owner'? [Y/n]: " drop_role
      [[ "${drop_role,,}" == "n" ]] && drop_role="" || drop_role=$owner
    fi
  fi
  read -r -p "Backup database '$db' dulu sebelum dihapus? [Y/n]: " pre
  if [[ "${pre,,}" != "n" ]]; then
    local bk
    bk=$(do_backup "$db") || { err "Backup gagal; penghapusan dibatalkan."; return 1; }
    echo "Backup: $bk"
  fi
  echo
  echo "AKAN DIHAPUS PERMANEN: database '$db'${drop_role:+ dan role '$drop_role'}."
  read -r -p "Ketik nama database ($db) untuk konfirmasi: " confirm
  [[ "$confirm" == "$db" ]] || { echo "Dibatalkan."; return 0; }

  if [[ -n "$force" ]]; then
    if (( $(psql_admin -tAc "SHOW server_version_num" | tr -d '[:space:]') >= 130000 )); then
      psql_admin -q -c "DROP DATABASE $(sql_ident "$db") WITH (FORCE);" || { err "Gagal menghapus database."; return 1; }
    else
      psql_admin -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=$(sql_literal "$db") AND pid <> pg_backend_pid();" >/dev/null
      psql_admin -q -c "DROP DATABASE $(sql_ident "$db");" || { err "Gagal menghapus database."; return 1; }
    fi
  else
    psql_admin -q -c "DROP DATABASE $(sql_ident "$db");" || { err "Gagal menghapus database (masih ada koneksi?)."; return 1; }
  fi
  echo "Database '$db' dihapus."
  if [[ -n "$drop_role" ]]; then
    local errf; errf=$(mktemp)
    if psql_admin -q -c "DROP ROLE $(sql_ident "$drop_role");" 2>"$errf"; then
      echo "Role '$drop_role' dihapus."
    else
      echo "Role '$drop_role' TIDAK dihapus: $(head -n 2 "$errf" | tr '\n' ' ')"
      echo "(biasanya karena role masih punya objek/hak di database lain)"
    fi
    rm -f -- "$errf"
  fi
}

# ---------------------------------------------------------------------------
# SERTIFIKAT SSL
# ---------------------------------------------------------------------------
SSL_CERT_FILE="$CERT_DIR/server.crt"
SSL_KEY_FILE="$CERT_DIR/server.key"

cert_days_left() {
  local f=${1:-$SSL_CERT_FILE} end
  [[ -r "$f" ]] || return 1
  end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2) || return 1
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

cert_expiry_warning() {
  local d
  d=$(cert_days_left) || return 0
  if (( d < 0 )); then
    echo "Sertifikat SSL sudah KEDALUWARSA $(( -d )) hari lalu. Rotasi lewat menu 16."
  elif (( d < 30 )); then
    echo "Sertifikat SSL berakhir dalam $d hari. Rotasi lewat menu 16."
  fi
}

show_cert_info() {
  local f=$1
  openssl x509 -in "$f" -noout -subject -issuer -enddate 2>/dev/null | sed -E 's/^subject=/  Subject : /; s/^issuer=/  Issuer  : /; s/^notAfter=/  Berlaku s.d.: /'
  echo "  Sisa    : $(cert_days_left "$f") hari"
}

# Fingerprint sertifikat yang benar-benar disajikan server (via STARTTLS postgres).
served_fingerprint() {
  local host=$POSTGRES_BIND
  [[ "$host" == "0.0.0.0" ]] && host=127.0.0.1
  timeout 10 openssl s_client -starttls postgres -connect "$host:$POSTGRES_PORT" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

rotate_ssl() {
  load_config || return 1
  need_cmd openssl || return 1
  [[ -f "$SSL_CERT_FILE" && -f "$SSL_KEY_FILE" ]] || { err "Sertifikat tidak ditemukan di $CERT_DIR (stack dibuat manual?)."; return 1; }
  local choice tmpd ts bdir crt_in key_in newfp servedfp
  echo "Sertifikat saat ini:"
  show_cert_info "$SSL_CERT_FILE"
  echo
  echo "  1. Buat sertifikat self-signed baru (berlaku 10 tahun)"
  echo "  2. Pakai sertifikat sendiri (mis. dari CA / Let's Encrypt): file .crt/fullchain + .key"
  echo "  0. Batal"
  read -r -p "Pilihan: " choice
  case "$choice" in 1|2) ;; *) echo "Dibatalkan."; return 0 ;; esac

  tmpd=$(mktemp -d "$BASE_DIR/.ssl.XXXXXX")
  if [[ "$choice" == 1 ]]; then
    openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
      -out "$tmpd/crt" -keyout "$tmpd/key" -subj "/CN=$POSTGRES_CONTAINER" >/dev/null 2>&1 \
      || { safe_rm_in_base "$tmpd"; err "Gagal membuat sertifikat."; return 1; }
  else
    read -r -p "Path file sertifikat (.crt / fullchain.pem): " crt_in; crt_in=$(expand_path "$crt_in")
    read -r -p "Path file private key (.key / privkey.pem): " key_in; key_in=$(expand_path "$key_in")
    [[ -r "$crt_in" && -r "$key_in" ]] || { safe_rm_in_base "$tmpd"; err "File tidak ditemukan / tidak bisa dibaca."; return 1; }
    openssl x509 -in "$crt_in" -noout 2>/dev/null || { safe_rm_in_base "$tmpd"; err "File sertifikat tidak valid (harus PEM)."; return 1; }
    openssl pkey -in "$key_in" -noout 2>/dev/null || { safe_rm_in_base "$tmpd"; err "Private key tidak valid atau terenkripsi passphrase."; return 1; }
    if [[ "$(openssl x509 -in "$crt_in" -noout -pubkey 2>/dev/null)" != "$(openssl pkey -in "$key_in" -pubout 2>/dev/null)" ]]; then
      safe_rm_in_base "$tmpd"; err "Private key tidak cocok dengan sertifikat."; return 1
    fi
    openssl x509 -in "$crt_in" -noout -checkend 0 >/dev/null 2>&1 || { safe_rm_in_base "$tmpd"; err "Sertifikat sudah kedaluwarsa."; return 1; }
    cat -- "$crt_in" > "$tmpd/crt"; cat -- "$key_in" > "$tmpd/key"
  fi
  echo "Sertifikat baru:"
  show_cert_info "$tmpd/crt"

  ts=$(date +%Y%m%d-%H%M%S)
  bdir="$BACKUP_DIR/ssl-$ts"
  mkdir -p "$bdir"; chmod 700 "$bdir"
  cp -p -- "$SSL_CERT_FILE" "$SSL_KEY_FILE" "$bdir/"
  # Tulis di tempat (inode sama): file di-bind-mount satu per satu ke container,
  # file baru dengan inode lain tidak akan terlihat dari dalam container.
  cat -- "$tmpd/crt" > "$SSL_CERT_FILE"
  cat -- "$tmpd/key" > "$SSL_KEY_FILE"
  newfp=$(openssl x509 -in "$tmpd/crt" -noout -fingerprint -sha256 | cut -d= -f2)
  safe_rm_in_base "$tmpd"
  echo "Sertifikat lama disimpan di $bdir"

  if container_running; then
    psql_admin -q -c "SELECT pg_reload_conf();" >/dev/null || { err "Reload konfigurasi gagal."; return 1; }
    sleep 1
    servedfp=$(served_fingerprint || true)
    if [[ -z "$servedfp" ]]; then
      echo "Reload dikirim. Verifikasi otomatis tidak bisa dilakukan (port tidak terjangkau dari host);"
      echo "cek dengan menu 11 dan log (menu 12)."
    elif [[ "$servedfp" == "$newfp" ]]; then
      echo "Server sudah memakai sertifikat baru (tanpa restart)."
    else
      err "Server masih menyajikan sertifikat lama; kemungkinan sertifikat/key baru ditolak (lihat log)."
      cat -- "$bdir/server.crt" > "$SSL_CERT_FILE"; cat -- "$bdir/server.key" > "$SSL_KEY_FILE"
      psql_admin -q -c "SELECT pg_reload_conf();" >/dev/null || true
      err "Sertifikat lama dikembalikan."
      return 1
    fi
  else
    echo "Container tidak berjalan; sertifikat baru dipakai saat container dinyalakan."
  fi
}


# Nama database dari nama file backup: <db>-YYYYMMDD-HHMMSS[-pid].dump
db_from_backup_name() {
  sed -nE 's/^(.+)-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.dump$/\1/p' <<< "$(basename "$1")"
}

# Kumpulkan semua backup .dump: lokal (backups/, auto/, downloaded/) dan R2 (auto/, manual/).
# Output per baris: epoch|sumber|lokasi|ukuran|nama_file  (urut terbaru dulu, nama file unik,
# salinan lokal diutamakan bila file yang sama juga ada di R2).
collect_backups() {
  local d listing ts size name epoch sub
  {
    for d in "$BACKUP_DIR" "$AUTO_DIR" "$DOWNLOAD_DIR"; do
      [[ -d "$d" ]] || continue
      find "$d" -maxdepth 1 -type f -name '*.dump' -printf "%T@|lokal|%p|%s|%f\n" | sed -E 's/^([0-9]+)\.[0-9]+\|/\1|/'
    done
    if r2_configured; then
      for sub in auto manual; do
        if listing=$(rclone_run lsf "$(r2_path "$sub")" --files-only --format "tsp" --separator ";" --include '*.dump' 2>/dev/null); then
          while IFS=';' read -r ts size name; do
            [[ -n "$name" ]] || continue
            epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
            printf '%s|R2:%s|%s|%s|%s\n' "$epoch" "$sub" "$sub/$name" "$size" "$name"
          done <<< "$listing"
        else
          echo "Peringatan: gagal membaca daftar backup R2 ($sub); hanya backup lokal yang ditampilkan." >&2
        fi
      done
    fi
  } | awk -F'|' '!($5 in best) || ($2 == "lokal" && src[$5] != "lokal") { best[$5] = $0; src[$5] = $2 }
                 END { for (k in best) print best[k] }' | sort -t'|' -k1,1nr
}

# Pilih backup secara interaktif. Mencetak path file lokal yang siap di-restore
# (backup dari R2 di-download dulu ke downloaded/).
pick_backup() {
  local filter rows=() r i=0 pick epoch src loc size name dbn path
  read -r -p "Filter nama database (kosong = semua): " filter
  [[ -z "$filter" ]] || valid_dbname "$filter" || { err "Filter tidak valid."; return 1; }
  echo "Mencari backup lokal$(r2_configured && echo ' dan R2')..." >&2
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    IFS='|' read -r epoch src loc size name <<< "$r"
    dbn=$(db_from_backup_name "$name")
    [[ -z "$filter" || "$dbn" == "$filter" ]] || continue
    rows+=("$r")
    (( ${#rows[@]} < 40 )) || break
  done < <(collect_backups)
  (( ${#rows[@]} > 0 )) || { err "Tidak ada backup .dump yang ditemukan${filter:+ untuk '$filter'}."; return 1; }

  {
    printf '\n %3s  %-16s  %-10s  %-20s  %8s  %s\n' "No" "Waktu" "Sumber" "Database" "Ukuran" "File"
    for r in "${rows[@]}"; do
      i=$((i+1))
      IFS='|' read -r epoch src loc size name <<< "$r"
      printf ' %3d  %-16s  %-10s  %-20s  %8s  %s\n' "$i" "$(date -d "@$epoch" '+%Y-%m-%d %H:%M')" "$src" \
        "$(db_from_backup_name "$name")" "$(numfmt --to=iec "$size" 2>/dev/null || echo "$size")" "$name"
    done
    echo
    echo "  m = masukkan path file manual"
  } >&2
  read -r -p "Pilih nomor backup (kosong = batal): " pick
  [[ -n "$pick" ]] || return 2
  if [[ "${pick,,}" == "m" ]]; then
    read -r -p "Path file backup .dump: " path
    expand_path "$path"
    return 0
  fi
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#rows[@]} )) || { err "Pilihan tidak valid."; return 1; }
  IFS='|' read -r epoch src loc size name <<< "${rows[$((pick-1))]}"
  if [[ "$src" == lokal ]]; then
    printf '%s\n' "$loc"
  else
    load_r2_conf || { err "Konfigurasi R2 tidak lengkap."; return 1; }
    mkdir -p "$DOWNLOAD_DIR"; chmod 700 "$DOWNLOAD_DIR"
    echo "Download $name dari R2..." >&2
    rclone_run copyto "$(r2_path "")/$loc" "$DOWNLOAD_DIR/$name" >&2 || { err "Download dari R2 gagal."; return 1; }
    chmod 600 "$DOWNLOAD_DIR/$name"
    echo "Tersimpan: $DOWNLOAD_DIR/$name" >&2
    printf '%s\n' "$DOWNLOAD_DIR/$name"
  fi
}

restore_database() {
  require_running || return 1
  local file db confirm owner role_args=() pre def_db rc
  rc=0; file=$(pick_backup) || rc=$?
  (( rc != 2 )) || { echo "Dibatalkan."; return 0; }
  (( rc == 0 )) || return 1
  [[ -f "$file" && -r "$file" ]] || { err "File tidak ditemukan / tidak bisa dibaca: $file"; return 1; }
  if ! docker exec -i "$POSTGRES_CONTAINER" pg_restore -l < "$file" >/dev/null 2>&1; then
    err "File bukan arsip pg_dump format custom (-Fc) yang valid, atau dibuat oleh pg_dump yang lebih baru dari server."
    return 1
  fi
  echo "File: $file"
  def_db=$(db_from_backup_name "$file")
  if [[ -n "$def_db" ]] && valid_dbname "$def_db" && db_exists "$def_db"; then
    read -r -p "Restore ke database yang sudah ada [$def_db]: " db
    db=${db:-$def_db}
  else
    [[ -n "$def_db" ]] && echo "Database asal '$def_db' belum ada di server ini. Buat dulu lewat menu 5 jika ingin restore ke nama yang sama."
    read -r -p "Restore ke database yang sudah ada: " db
  fi
  valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
  db_exists "$db" || { err "Database '$db' tidak ada. Buat dulu lewat menu 5."; return 1; }
  [[ "$db" != "postgres" && "$db" != "template0" && "$db" != "template1" ]] || { err "Restore ke database sistem tidak diizinkan."; return 1; }

  # Objek hasil restore dibuat sebagai pemilik database, bukan sebagai admin,
  # supaya user aplikasi bisa mengakses tabelnya.
  owner=$(psql_admin -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=$(sql_literal "$db")" | tr -d '[:space:]') || return 1
  if [[ -n "$owner" && "$owner" != "$POSTGRES_USER" ]]; then
    role_args=(--role="$owner")
  fi

  echo "PERINGATAN: objek di database '$db' yang namanya sama dengan isi backup akan DIHAPUS lalu dibuat ulang."
  echo "Objek hasil restore akan dimiliki oleh: ${owner:-$POSTGRES_USER}"
  read -r -p "Buat backup database '$db' terlebih dahulu? [Y/n]: " pre
  if [[ "${pre,,}" != "n" ]]; then
    do_backup "$db" >/dev/null || { err "Backup pengaman gagal; restore dibatalkan."; return 1; }
  fi
  read -r -p "Ketik RESTORE untuk melanjutkan: " confirm
  [[ "$confirm" == "RESTORE" ]] || { echo "Dibatalkan."; return 0; }
  if run_pg_restore "$file" "$db" "${role_args[@]}"; then
    echo "Restore selesai ke database '$db'."
    return 0
  fi
  err "Restore gagal. Karena --single-transaction, database '$db' tidak berubah."
  (( ${#role_args[@]} > 0 )) || return 1
  echo "Penyebab umum: dump berisi EXTENSION/objek yang hanya boleh dibuat superuser."
  read -r -p "Ulangi restore sebagai admin lalu pindahkan kepemilikan objek ke '$owner'? [y/N]: " confirm
  [[ "${confirm,,}" == "y" ]] || return 1
  run_pg_restore "$file" "$db" || { err "Restore sebagai admin juga gagal; database '$db' tidak berubah."; return 1; }
  reassign_to_owner "$db" "$owner" || { err "Restore berhasil, tetapi pemindahan kepemilikan gagal. Periksa manual."; return 1; }
  echo "Restore selesai ke database '$db'; kepemilikan objek dipindahkan ke '$owner'."
}

run_pg_restore() {
  local file=$1 db=$2; shift 2
  docker exec -i "$POSTGRES_CONTAINER" pg_restore \
    -U "$POSTGRES_USER" -d "$db" "$@" --no-owner --no-acl \
    --clean --if-exists --single-transaction --exit-on-error < "$file"
}

# Pindahkan objek milik admin (kecuali milik extension) ke pemilik database.
# REASSIGN OWNED tidak bisa dipakai karena admin adalah bootstrap superuser.
reassign_to_owner() {
  local db=$1 owner=$2
  docker exec -i "$POSTGRES_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" \
    -v new_owner="$owner" >/dev/null <<'SQL'
SELECT set_config('pgm.new_owner', :'new_owner', false);
DO $$
DECLARE
  r record;
  me oid := (SELECT oid FROM pg_roles WHERE rolname = current_user);
  tgt text := current_setting('pgm.new_owner');
BEGIN
  FOR r IN SELECT nspname FROM pg_namespace
           WHERE nspowner = me AND nspname NOT IN ('public','information_schema') AND nspname NOT LIKE 'pg\_%' LOOP
    EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.nspname, tgt);
  END LOOP;
  FOR r IN SELECT c.oid::regclass AS obj FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relowner = me AND c.relkind IN ('r','p','v','m','f','S')
             AND n.nspname NOT IN ('information_schema') AND n.nspname NOT LIKE 'pg\_%'
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('e','a','i')) LOOP
    EXECUTE format('ALTER TABLE %s OWNER TO %I', r.obj, tgt);
  END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS obj FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE p.proowner = me AND n.nspname NOT IN ('information_schema') AND n.nspname NOT LIKE 'pg\_%'
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e') LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.obj, tgt);
  END LOOP;
  FOR r IN SELECT t.oid::regtype AS obj, t.typtype FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE t.typowner = me AND t.typtype IN ('e','d','r','m','c')
             AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
             AND n.nspname NOT IN ('information_schema') AND n.nspname NOT LIKE 'pg\_%'
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e') LOOP
    IF r.typtype = 'd' THEN
      EXECUTE format('ALTER DOMAIN %s OWNER TO %I', r.obj, tgt);
    ELSE
      EXECUTE format('ALTER TYPE %s OWNER TO %I', r.obj, tgt);
    END IF;
  END LOOP;
END $$;
SQL
}

list_databases() {
  require_running || return 1
  psql_admin -c "SELECT datname AS database, pg_get_userbyid(datdba) AS owner, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate = false ORDER BY datname;"
}

list_users() {
  require_running || return 1
  psql_admin -c "SELECT rolname AS username, rolsuper AS superuser, rolcreatedb AS create_db, rolcanlogin AS can_login FROM pg_roles WHERE rolname NOT LIKE 'pg_%' ORDER BY rolname;"
}

show_status() {
  load_config || return 1
  (cd "$BASE_DIR" && docker compose ps)
}

show_ssl() {
  require_running || return 1
  psql_admin -c "SHOW ssl;" -c "SELECT type, address, auth_method FROM pg_hba_file_rules WHERE type <> 'local' ORDER BY rule_number;"
}

show_logs() {
  load_config || return 1
  echo "(Tekan Ctrl+C untuk kembali ke menu)"
  docker logs --tail 100 -f "$POSTGRES_CONTAINER" || true
}

# Pastikan folder data milik user postgres di container. Memperbaiki instalasi yang
# dibuat versi script lama (folder data root 700 -> "mkdir: Permission denied").
# Return 0 = sudah benar, 10 = baru diperbaiki.
ensure_data_dir_owner() {
  local dir="$BASE_DIR/data" uid=${POSTGRES_UID:-} gid=${POSTGRES_GID:-}
  [[ -d "$dir" ]] || return 0
  if [[ -z "$uid" ]]; then
    uid=$(docker run --rm --entrypoint id "$POSTGRES_IMAGE" -u postgres 2>/dev/null || true)
    gid=$(docker run --rm --entrypoint id "$POSTGRES_IMAGE" -g postgres 2>/dev/null || true)
    [[ "$uid" =~ ^[0-9]+$ ]] || { err "Tidak bisa membaca UID postgres dari image $POSTGRES_IMAGE."; return 1; }
    [[ "$gid" =~ ^[0-9]+$ ]] || gid=$uid
    env_set POSTGRES_UID "$uid"; env_set POSTGRES_GID "$gid"
  fi
  [[ -n "$gid" ]] || gid=$uid
  if [[ "$(stat -c '%u' "$dir")" != "$uid" ]]; then
    echo "Memperbaiki owner $dir -> $uid:$gid (user postgres di container)"
    chown "$uid:$gid" "$dir" && chmod 700 "$dir" || { err "Gagal mengubah owner $dir."; return 1; }
    return 10
  fi
  return 0
}

start_stack() {
  load_config || return 1
  check_docker || return 1
  local fixed=0
  ensure_data_dir_owner || { (( $? == 10 )) && fixed=1 || return 1; }
  if (( fixed )); then
    # Container lama mungkin sedang restart-loop; buat ulang agar langsung mencoba lagi.
    (cd "$BASE_DIR" && docker compose up -d --force-recreate) || return 1
  else
    (cd "$BASE_DIR" && docker compose up -d) || return 1
  fi
  echo "Menunggu PostgreSQL siap..."
  wait_ready "$POSTGRES_CONTAINER" "$POSTGRES_USER" "$POSTGRES_DB" && echo "PostgreSQL siap." || { err "PostgreSQL belum siap. Periksa logs."; return 1; }
}
stop_stack()    { load_config || return 1; (cd "$BASE_DIR" && docker compose stop); }
restart_stack() { load_config || return 1; (cd "$BASE_DIR" && docker compose restart); }

# Ganti nilai satu key di .env secara atomik (file sementara + rename), baris lain dipertahankan.
env_set() {
  local key=$1 value=$2 tmp line found=0
  tmp=$(mktemp "$BASE_DIR/.env.XXXXXX")
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*= ]]; then
      (( found )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
      found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$ENV_FILE"
  (( found )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

# Uji login TCP dengan password baru. Password dikirim lewat stdin, bukan argumen/env proses.
verify_login() {
  local user=$1 db=$2 password=$3
  printf '%s\n' "$password" | docker exec -i "$POSTGRES_CONTAINER" sh -c \
    'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -w -h 127.0.0.1 -p 5432 -U "$1" -d "$2" -tAc "SELECT 1" "sslmode=prefer"' \
    _ "$user" "$db" 2>/dev/null | grep -qx 1
}

change_password() {
  require_running || return 1
  local user password password2 info is_admin=0 login_db recreate
  echo "Role yang bisa login:"
  psql_admin -tAc "SELECT '  - ' || rolname || CASE WHEN rolsuper THEN ' (superuser)' ELSE '' END FROM pg_roles WHERE rolcanlogin AND rolname NOT LIKE 'pg\_%' ORDER BY rolname"
  read -r -p "Username yang akan diganti password-nya [$POSTGRES_USER]: " user
  user=${user:-$POSTGRES_USER}
  valid_identifier "$user" || { err "Username tidak valid."; return 1; }
  info=$(psql_admin -tAc "SELECT rolcanlogin FROM pg_roles WHERE rolname=$(sql_literal "$user")" | tr -d '[:space:]') || return 1
  [[ -n "$info" ]] || { err "Role '$user' tidak ditemukan."; return 1; }
  [[ "$info" == "t" ]] || { err "Role '$user' tidak bisa login (NOLOGIN)."; return 1; }
  [[ "$user" == "$POSTGRES_USER" ]] && is_admin=1

  read -r -s -p "Password baru (kosong = generate otomatis): " password; echo
  if [[ -z "$password" ]]; then
    password=$(openssl rand -hex 24)
  else
    read -r -s -p "Ulangi password: " password2; echo
    [[ "$password" == "$password2" ]] || { err "Password tidak cocok."; return 1; }
    if (( is_admin )); then
      [[ "$password" =~ ^[A-Za-z0-9@#%+=._-]{16,}$ ]] || { err "Password admin minimal 16 karakter; hanya huruf, angka, dan @ # % + = . _ - (agar aman di .env)."; return 1; }
    else
      (( ${#password} >= 12 )) || { err "Password minimal 12 karakter."; return 1; }
    fi
  fi

  echo "PERINGATAN: aplikasi/klien yang memakai user '$user' harus diperbarui dengan password baru."
  echo "            Koneksi yang sedang terbuka tetap jalan; koneksi baru wajib memakai password baru."
  read -r -p "Ketik GANTI untuk melanjutkan: " password2
  [[ "$password2" == "GANTI" ]] || { echo "Dibatalkan."; return 0; }

  # 1) Ubah di database (via socket lokal, tidak butuh password lama).
  if ! psql_admin -q <<SQL
SET log_statement = 'none';
ALTER ROLE $(sql_ident "$user") WITH PASSWORD $(sql_literal "$password");
SQL
  then
    err "Gagal mengubah password di PostgreSQL. Tidak ada yang berubah."; return 1
  fi
  echo "Password role '$user' di PostgreSQL sudah diubah."

  # 2) Untuk admin: simpan juga ke .env supaya konfigurasi tetap sinkron.
  if (( is_admin )); then
    if ! env_set POSTGRES_PASSWORD "$password"; then
      err "Password di database SUDAH berubah, tetapi gagal menulis $ENV_FILE."
      err "Simpan password ini dan perbarui .env secara manual: $password"
      return 1
    fi
    echo "$ENV_FILE diperbarui."
  fi

  # 3) Verifikasi login dengan password baru.
  login_db=$POSTGRES_DB
  (( is_admin )) || login_db=$(psql_admin -tAc "SELECT datname FROM pg_database WHERE pg_get_userbyid(datdba)=$(sql_literal "$user") AND NOT datistemplate ORDER BY datname LIMIT 1" | tr -d '[:space:]')
  if [[ -n "$login_db" ]]; then
    if verify_login "$user" "$login_db" "$password"; then
      echo "Verifikasi login dengan password baru: BERHASIL (database '$login_db')."
    else
      echo "Catatan: verifikasi login otomatis gagal (cek pg_hba/hak CONNECT). Password tetap sudah diganti."
    fi
  fi

  if (( is_admin )); then
    echo
    echo "Container masih menyimpan POSTGRES_PASSWORD lama di environment-nya (terlihat di"
    echo "'docker inspect'), walau tidak lagi dipakai untuk login. Recreate container untuk"
    echo "menyegarkannya; data tetap aman, downtime beberapa detik."
    read -r -p "Recreate container sekarang? [y/N]: " recreate
    if [[ "${recreate,,}" == "y" ]]; then
      (cd "$BASE_DIR" && docker compose up -d --force-recreate) || { err "Recreate gagal; jalankan menu 2."; return 1; }
      wait_ready "$POSTGRES_CONTAINER" "$POSTGRES_USER" "$POSTGRES_DB" && echo "PostgreSQL siap." || { err "PostgreSQL belum siap. Periksa logs."; return 1; }
    else
      echo "OK. Container akan ikut diperbarui otomatis saat menu 2 (Start) dijalankan berikutnya."
    fi
  fi
  echo
  echo "Password baru untuk '$user': $password"
  echo "Simpan sekarang dan perbarui DSN aplikasi."
}

# Jalankan aksi menu di subshell dengan `set -e` aktif: perintah yang gagal
# menghentikan aksi itu saja, lalu kembali ke menu (bukan menutup script).
run_action() {
  local rc
  set +e
  ( set -e; trap - INT; "$@" )
  rc=$?
  set -e
  if (( rc == 130 )); then
    echo; echo "Dibatalkan (Ctrl+C)."
  elif (( rc != 0 )); then
    echo; echo "Aksi gagal (exit code $rc)."
  fi
  pause
}

main_menu() {
  local choice cw
  # Ctrl+C membatalkan aksi yang sedang berjalan, bukan menutup manager.
  trap 'echo' INT
  while true; do
    clear 2>/dev/null || true
    echo "=============================================="
    echo "        POSTGRESQL DOCKER MANAGER"
    echo "=============================================="
    echo "Folder   : $BASE_DIR"
    if [[ -f "$ENV_FILE" ]] && load_config 2>/dev/null; then
      echo "Container: $POSTGRES_CONTAINER | Bind: $POSTGRES_BIND:$POSTGRES_PORT"
      check_ownership
      cw=$(cert_expiry_warning 2>/dev/null || true)
      [[ -z "$cw" ]] || echo "PERINGATAN: $cw"
      if [[ -f "$INSTALLED_BIN" ]] && { [[ -f "$CRON_FILE" ]] || [[ -f "/etc/systemd/system/$SYSTEMD_UNIT.timer" ]]; } \
         && ! cmp -s "$SCRIPT_PATH" "$INSTALLED_BIN"; then
        echo "PERINGATAN: salinan scheduler ($INSTALLED_BIN) berbeda dari script ini; buka menu auto backup -> 1 untuk memperbarui."
      fi
    elif [[ -f "$COMPOSE_FILE" ]]; then
      echo "Status: compose.yaml ada tetapi .env tidak ditemukan/tidak valid"
    else
      echo "Status: Belum setup"
    fi
    echo "----------------------------------------------"
    echo " 1. Setup PostgreSQL dari nol"
    echo " 2. Start PostgreSQL"
    echo " 3. Stop PostgreSQL"
    echo " 4. Restart PostgreSQL"
    echo " 5. Buat database + user baru"
    echo " 6. Backup database"
    echo " 7. Restore database (pilih dari backup lokal / R2)"
    echo " 8. List database"
    echo " 9. List database user/role"
    echo "10. Cek status container"
    echo "11. Cek SSL & aturan akses (pg_hba)"
    echo "12. Lihat PostgreSQL logs"
    echo "13. Ganti password user/role"
    echo "14. Auto backup & Cloudflare R2"
    echo "15. Hapus database + user"
    echo "16. Rotasi sertifikat SSL"
    echo "17. Uninstall instance (hapus container, opsional data)"
    echo " 0. Keluar"
    echo "=============================================="
    if ! read -r -p "Pilih menu: " choice; then echo; exit 0; fi
    echo
    case "$choice" in
      1) run_action setup_stack ;;
      2) run_action start_stack ;;
      3) run_action stop_stack ;;
      4) run_action restart_stack ;;
      5) run_action create_database ;;
      6) run_action backup_database ;;
      7) run_action restore_database ;;
      8) run_action list_databases ;;
      9) run_action list_users ;;
      10) run_action show_status ;;
      11) run_action show_ssl ;;
      12) run_action show_logs ;;
      13) run_action change_password ;;
      14) run_action schedule_menu ;;
      15) run_action drop_database ;;
      16) run_action rotate_ssl ;;
      17) run_action uninstall_instance ;;
      0) echo "Selesai."; exit 0 ;;
      *) echo "Pilihan tidak dikenal."; pause ;;
    esac
  done
}

set -e
case "${1:-}" in
  backup-auto)
    # Mode non-interaktif untuk scheduler (systemd timer / cron).
    need_cmd docker; need_cmd flock
    set +e
    backup_auto_notify
    exit $?
    ;;
  "") ;;
  *)
    echo "Pemakaian: $0              menu interaktif"
    echo "           $0 backup-auto  backup terjadwal (non-interaktif)"
    exit 2 ;;
esac
need_cmd openssl || exit 1
main_menu
