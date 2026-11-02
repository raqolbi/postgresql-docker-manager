# PostgreSQL Docker Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Bash script untuk melakukan setup PostgreSQL 18 menggunakan Docker
Compose dari nol, kemudian mengelola database melalui menu interaktif.

Script mengelola satu instance PostgreSQL dalam container Docker.
Database dan role baru dibuat di dalam instance yang sama.

## Fitur

-   Setup PostgreSQL Docker dari nol.
-   Membuat direktori data, backup, dan sertifikat SSL.
-   Membuat konfigurasi `.env` dan `compose.yaml`.
-   Menjalankan PostgreSQL dengan Docker Compose.
-   Start, stop, dan restart container.
-   Membuat `pg_hba.conf` sendiri: koneksi TCP wajib SSL + `scram-sha-256` (opsional).
-   Membuat database baru sekaligus role/user pemiliknya (database terisolasi per user).
-   Backup database ke format PostgreSQL custom (`.dump`) + backup roles/globals.
-   Restore backup `.dump` ke database yang sudah ada, dengan backup pengaman otomatis
    dan kepemilikan objek mengikuti pemilik database.
-   Melihat daftar database dan role.
-   Memeriksa status container dan status SSL.
-   Melihat 100 baris log terakhir dan mengikuti log secara live.
-   Mengganti password admin maupun user lain; untuk admin, `.env` ikut diperbarui.
-   Auto backup terjadwal (systemd timer, atau cron jika systemd tidak ada) dengan retensi.
-   Tujuan backup bisa dipilih: lokal saja, Cloudflare R2 saja, atau lokal + R2.

## Prasyarat

Jalankan script pada server Linux yang memiliki:

-   Bash.
-   Docker Engine.
-   Docker Compose plugin (`docker compose`).
-   OpenSSL.
-   (Opsional, untuk R2) tidak perlu instal apa pun: rclone dijalankan sebagai
    container `rclone/rclone`. Jika rclone sudah terpasang di host, bisa dipakai juga.
-   Hak akses `root` atau kemampuan menjalankan perintah dengan `sudo`.

Periksa dependensi sebelum menjalankan:

``` bash
docker --version
docker compose version
openssl version
```

> Script tidak memasang Docker Engine atau Docker Compose. Pasang
> keduanya terlebih dahulu jika belum tersedia.

## Instalasi dan menjalankan

Semua file yang dibuat script (`.env`, `compose.yaml`, `data/`, `certs/`,
`config/`, `backups/`, dst.) disimpan di **folder tempat
`postgres-manager.sh` berada**. Jadi pilih folder khusus untuk satu instance
PostgreSQL, misalnya `/opt/postgres`:

``` bash
sudo git clone https://github.com/raqolbi/postgresql-docker-manager.git /opt/postgres
cd /opt/postgres
sudo ./postgres-manager.sh
```

Atau salin `postgres-manager.sh` saja ke folder tersebut, lalu jalankan:

``` bash
chmod +x postgres-manager.sh
sudo ./postgres-manager.sh
```

Script bisa dipanggil dari mana saja (`sudo /opt/postgres/postgres-manager.sh`);
folder kerja selalu mengikuti lokasi file script, dan ditampilkan di bagian
atas menu.

Catatan:

-   Gunakan satu folder untuk satu instance. Dua folder berbeda = dua
    instance terpisah (pastikan nama container dan port berbeda).
-   Nama folder hanya boleh berisi huruf, angka, `.`, `_`, `-`, dan `/`.
-   Folder sistem seperti `/`, `/usr`, `/etc`, `/var`, `/tmp`, `/root`, `/home`
    ditolak.
-   Owner dan permission folder proyek sendiri tidak diubah; yang diatur hanya
    file/subfolder yang dibuat script.
-   `.gitignore` di repo sudah mengecualikan semua file runtime (password,
    private key, data, backup), sehingga folder clone aman untuk `git pull`.
-   Contoh path di dokumentasi ini memakai `/opt/postgres`; sesuaikan dengan
    folder Anda.

Script harus dijalankan sebagai `root`, sehingga gunakan `sudo` jika
masuk sebagai user biasa.

## Menu interaktif

``` text
==============================================
        POSTGRESQL DOCKER MANAGER
==============================================
 1. Setup PostgreSQL dari nol
 2. Start PostgreSQL
 3. Stop PostgreSQL
 4. Restart PostgreSQL
 5. Buat database + user baru
 6. Backup database
 7. Restore database (pilih dari backup lokal / R2)
 8. List database
 9. List database user/role
10. Cek status container
11. Cek SSL & aturan akses (pg_hba)
12. Lihat PostgreSQL logs
13. Ganti password user/role
14. Auto backup & Cloudflare R2
15. Hapus database + user
16. Rotasi sertifikat SSL
17. Uninstall instance (hapus container, opsional data)
 0. Keluar
```

## Setup pertama kali

Pilih menu **1. Setup PostgreSQL dari nol**. Script akan meminta
konfigurasi berikut:

  -----------------------------------------------------------------------
  Parameter               Default                 Keterangan
  ----------------------- ----------------------- -----------------------
  PostgreSQL image        `postgres:18`           Image Docker yang
                                                  digunakan

  Database awal           `qolcore`               Database yang dibuat
                                                  saat inisialisasi

  Admin username          `qolcore_owner`          Role administrator awal

  Host port               `5434`                  Port PostgreSQL yang
                                                  dipublikasikan di host

  Bind address            `127.0.0.1`             Alamat interface host
                                                  untuk publikasi port.
                                                  Pakai `0.0.0.0` hanya
                                                  jika perlu akses dari
                                                  server lain

  Wajibkan SSL            `Y`                     Tolak koneksi TCP
                                                  tanpa SSL

  Container name          `qolcore-postgres`      Nama container Docker
  -----------------------------------------------------------------------

Password admin dapat dibuat otomatis atau dimasukkan sendiri. Password
yang dimasukkan sendiri harus minimal 16 karakter dan hanya menggunakan
huruf, angka, serta karakter `@ # % + = . _ -`. Password otomatis dibuat
menggunakan `openssl rand`.

Script kemudian:

1.  Melakukan `docker pull` image lalu membaca versi mayor PostgreSQL dan UID
    user `postgres` di image (Debian = 999, Alpine = 70).
2.  Menentukan lokasi mount data: PG 18+ ke `/var/lib/postgresql`, versi lama
    ke `/var/lib/postgresql/data` (mencegah data jatuh ke volume anonim).
3.  Membuat direktori kerja PostgreSQL.
4.  Membuat self-signed SSL certificate (RSA 2048, berlaku 10 tahun).
5.  Membuat `config/pg_hba.conf` dan mengatur permission file.
6.  Menulis file `.env` dan `compose.yaml`.
7.  Menjalankan `docker compose up -d`.
8.  Menunggu PostgreSQL siap via TCP (bukan hanya socket, supaya tidak
    tertipu server sementara saat inisialisasi).
9.  Mencabut hak `CONNECT` dari `PUBLIC` pada database awal dan `postgres`.

**Perlindungan data:** setup dibatalkan jika `compose.yaml`
atau `.env` sudah ada, jika folder `data/` tidak kosong, atau jika nama
container sudah dipakai. Script tidak menimpa konfigurasi/cluster yang
sudah ada.

> `.env` dan `compose.yaml` harus milik root dan tidak bisa ditulis user lain,
> karena dipakai oleh perintah yang berjalan sebagai root. Script menampilkan
> peringatan di menu jika tidak demikian, atau jika folder proyek bisa ditulis
> user lain (group/other writable).

## Struktur direktori

Setelah setup berhasil, isi folder proyek (contoh `/opt/postgres`):

``` text
/opt/postgres/
├── postgres-manager.sh
├── .env
├── compose.yaml
├── data/
├── certs/
│   ├── server.crt
│   └── server.key
├── config/
│   └── pg_hba.conf
└── backups/
```

  -----------------------------------------------------------------------
  Path                                Fungsi
  ----------------------------------- -----------------------------------
  `/opt/postgres/.env`                Konfigurasi image, database awal,
                                      user, password, port, bind address,
                                      dan nama container

  `/opt/postgres/compose.yaml`        Konfigurasi Docker Compose

  `/opt/postgres/data/`               Data persisten PostgreSQL

  `/opt/postgres/certs/`              Sertifikat SSL dan private key

  `/opt/postgres/config/pg_hba.conf`  Aturan autentikasi klien

  `/opt/postgres/backups/`            File hasil backup
  -----------------------------------------------------------------------

Permission penting yang diterapkan:

-   `/opt/postgres/.env`: `600`.
-   `/opt/postgres/compose.yaml`: `600`.
-   Folder `certs/` dan `backups/`: `700`, milik root.
-   Folder `data/`: `700`, milik user `postgres` di container (999 Debian / 70 Alpine).
-   `pg_hba.conf`: `640`, milik user `postgres` di container.
-   `server.key`: `600`.
-   `server.crt`: `644`.
-   File backup: `600`.

Jangan membagikan file `.env` atau private key.

## Membuat database dan user baru

Pilih menu **5. Buat database + user baru**.

Masukkan nama database dan username pemiliknya. Nama database dan
username harus memenuhi aturan berikut:

-   Diawali huruf atau underscore (`_`).
-   Karakter berikutnya hanya huruf, angka, atau underscore.
-   Maksimal 63 karakter.

Script akan menolak jika nama database atau role sudah digunakan.
Password dapat dimasukkan sendiri atau dikosongkan agar dibuat otomatis.

Password yang diketik sendiri harus diulang dan minimal 12 karakter.

Script menjalankan operasi setara dengan:

``` sql
CREATE ROLE nama_user LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '...';
CREATE DATABASE nama_database OWNER nama_user ENCODING 'UTF8' TEMPLATE template0;
REVOKE CONNECT, TEMPORARY ON DATABASE nama_database FROM PUBLIC;
```

`REVOKE ... FROM PUBLIC` membuat user lain tidak bisa connect ke database
ini. Jika `CREATE DATABASE` gagal, role yang baru dibuat dihapus kembali.

Setelah berhasil, script menampilkan database, username, password, dan
format connection string. **Simpan password yang ditampilkan saat itu
juga.** Password user database baru tidak disimpan ke `.env` maupun file
lain oleh script.

Format DSN:

``` text
postgresql://USERNAME:PASSWORD@HOST:5434/NAMA_DATABASE?sslmode=require
```

Ganti `HOST`, `5434`, username, password, dan nama database sesuai
konfigurasi server.

## Backup database

Pilih menu **6. Backup database**, lalu masukkan nama database, atau
kosongkan untuk mem-backup **semua database aplikasi** (semua kecuali
template dan `postgres`).

File backup dibuat dalam format custom PostgreSQL (`pg_dump -Fc`) dengan
pola nama:

``` text
/opt/postgres/backups/NAMA_DATABASE-YYYYMMDD-HHMMSS.dump
```

Pengaman yang diterapkan:

-   Sebelum dump, ruang disk dicek: harus tersisa minimal ukuran database
    + 1 GiB. Backup dibatalkan jika kurang, karena disk penuh juga akan
    mengganggu PostgreSQL di disk yang sama.
-   File ditulis sebagai `*.partial`, divalidasi dengan `pg_restore -l`, baru
    di-rename. Jika gagal, file parsial dihapus.
-   Permission file `600`, folder `700`.
-   Setiap backup juga membuat `globals-YYYYMMDD-HHMMSS.sql` (`pg_dumpall
    --globals-only`) berisi role dan hash password-nya. Perlakukan file ini
    sama rahasianya dengan `.env`.

Backup manual (menu 6) dan backup pengaman sebelum restore disimpan di
`/opt/postgres/backups/` dan **tidak** dihapus otomatis.

## Auto backup terjadwal

Pilih menu **14. Auto backup & Cloudflare R2**:

``` text
  1. Aktifkan / ubah jadwal & tujuan (lokal / R2 / lokal + R2)
  2. Nonaktifkan jadwal
  3. Jalankan auto backup sekarang (tes)
  4. Lihat log auto backup
  5. Atur kredensial Cloudflare R2
  6. Tes koneksi R2
  7. Lihat & download backup dari R2
  8. Atur notifikasi Telegram
  9. Tes notifikasi Telegram
 10. Matikan notifikasi Telegram
```

Saat mengaktifkan jadwal, isi:

  Parameter        Default   Keterangan
  ---------------- --------- ------------------------------------------------
  Jam              `02:30`   Jam harian, zona waktu server (`timedatectl`)
  Database         `all`     `all` = semua database aplikasi, termasuk yang dibuat nanti; atau `db1,db2`
  Tujuan           Lokal     1 = lokal saja, 2 = R2 saja, 3 = lokal + R2
  Retensi lokal    `14`      Hapus backup otomatis lokal lebih tua dari N hari (0 = simpan selamanya)

### Tujuan backup

  Tujuan          Lokal (`backups/auto/`)                   R2 (`<prefix>/auto/`)
  --------------- ----------------------------------------- -----------------------------
  Lokal saja      Disimpan, dihapus sesuai retensi lokal    -
  R2 saja         Hanya sementara; dihapus **setelah**      Disimpan, dihapus sesuai
                  upload terverifikasi                      retensi R2
  Lokal + R2      Disimpan, dihapus sesuai retensi lokal    Disimpan, dihapus sesuai
                                                            retensi R2

Mode R2 saja tetap membutuhkan ruang disk lokal sementara untuk membuat dump.

Jika upload ke R2 gagal (jaringan, kredensial), file **tetap disimpan lokal**
dan otomatis ikut di-upload pada run berikutnya. Status run dicatat sebagai
gagal agar terlihat di log.

### Retensi (berapa lama backup disimpan)

Ada dua pengaturan terpisah:

  Pengaturan      Default   Berlaku untuk                       Diatur di
  --------------- --------- ----------------------------------- ----------------
  Retensi lokal   14 hari   `backups/auto/` di server           menu 14 → 1
  Retensi R2      30 hari   `<prefix>/auto/` di bucket R2        menu 14 → 5

Contoh retensi 14 hari: setiap kali auto backup berjalan, file yang
umurnya **lebih dari 14 × 24 jam** dihapus, sehingga yang tersisa kira-kira
backup 14 hari terakhir. Isi `0` untuk tidak pernah menghapus.

Hal yang perlu diperhatikan:

-   Penghapusan terjadi **saat auto backup berjalan** (setelah backup baru
    berhasil), bukan terus-menerus. Jika jadwal dimatikan, file lama tidak
    ikut terhapus.
-   **Backup terbaru tiap database selalu disimpan**, walaupun umurnya sudah
    lewat batas. Contoh: database yang sudah tidak di-backup lagi tetap
    menyisakan satu backup terakhirnya.
-   Retensi **hanya** berlaku untuk backup otomatis. Backup manual (menu 6),
    backup pengaman sebelum restore, folder `manual/` di R2, dan file di
    `backups/downloaded/` **tidak pernah dihapus otomatis**, jadi bisa tetap
    muncul di daftar restore walaupun lebih tua dari batas retensi. Hapus
    manual jika sudah tidak perlu.

### Yang dilakukan script saat mengaktifkan jadwal

1.  Menyimpan pengaturan di `/opt/postgres/backup.conf` (root, `600`).
2.  Memasang salinan script ke `/usr/local/sbin/postgres-manager` (root,
    `755`). Scheduler menjalankan salinan ini, bukan file di folder user,
    supaya file yang bisa diedit user biasa tidak dieksekusi sebagai root.
3.  Membuat `pgm-backup-<id>.service` + `pgm-backup-<id>.timer` di
    systemd. `<id>` diambil dari path folder proyek, mis. `/opt/postgres` →
    `pgm-backup-opt-postgres`, jadi beberapa instance bisa punya jadwal
    masing-masing. Unit menjalankan salinan script dengan
    `PGM_BASE_DIR=<folder proyek>` (`Persistent=true`: jika server mati saat jadwal, backup
    dijalankan begitu server hidup). Tanpa systemd, dipakai
    `/etc/cron.d/pgm-backup-<id>`.

Perilaku auto backup (`postgres-manager backup-auto`):

-   Memakai lock (`flock`), jadi dua backup tidak pernah berjalan bersamaan.
-   Upload ke R2 dilakukan **sebelum** retensi lokal, sehingga file yang belum
    ter-upload tidak terhapus duluan.
-   Retensi (lokal maupun R2) selalu menyisakan **backup terbaru tiap
    database**, walaupun sudah melewati batas hari.
-   Jika ada langkah yang gagal, proses keluar dengan status gagal sehingga
    terlihat di `systemctl status pgm-backup-opt-postgres.service` / log.

Perintah manual yang berguna:

``` bash
systemctl list-timers pgm-backup-opt-postgres.timer       # jadwal berikutnya
journalctl -u pgm-backup-opt-postgres.service -n 50       # log
sudo PGM_BASE_DIR=/opt/postgres /usr/local/sbin/postgres-manager backup-auto   # jalankan sekarang
```

> Setelah memperbarui `postgres-manager.sh`, buka menu 14 → 1 lagi agar
> salinan di `/usr/local/sbin` ikut diperbarui.

## Cloudflare R2

### Persiapan di dashboard Cloudflare

1.  **R2 → Create bucket**, misalnya `qolcore-backup`. Biarkan private (jangan
    aktifkan public access / r2.dev).
2.  **R2 → Manage API Tokens → Create API token**:
    -   Permission: **Object Read & Write**.
    -   Specify bucket: **hanya** bucket backup tersebut.
    -   Simpan **Access Key ID** dan **Secret Access Key** (secret hanya
        ditampilkan sekali).
3.  Catat **Account ID** (terlihat di halaman R2 / URL dashboard).

### Mengisi konfigurasi

Menu **14 → 5. Atur kredensial Cloudflare R2**, isi:

  Isian               Contoh / default
  ------------------- -------------------------------------------------------
  Account ID          `0123456789abcdef...`
  Access Key ID       dari API token
  Secret Access Key   dari API token (input tersembunyi)
  Bucket              `qolcore-backup`
  Prefix              `postgres/<hostname>`; satu bucket bisa untuk beberapa server
  Endpoint            `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` (bucket EU: `https://<ACCOUNT_ID>.eu.r2.cloudflarestorage.com`)
  Retensi R2          `30` hari (0 = tidak pernah hapus)

Setelah disimpan, script langsung menjalankan tes tulis → baca → hapus.
Konfigurasi disimpan di `/opt/postgres/r2.conf` (root, `600`).

Struktur di bucket:

``` text
qolcore-backup/
└── postgres/<hostname>/
    ├── auto/      # dari auto backup (kena retensi R2)
    └── manual/    # dari menu 6 jika memilih upload (tidak dihapus otomatis)
```

### Cara upload bekerja

-   Memakai **rclone** dengan image Docker terkunci versi
    (`rclone/rclone:1.68.2`), jadi tidak perlu memasang apa pun di host. Jika
    rclone sudah ada di host, script menawarkan untuk memakainya.
-   Kredensial dikirim lewat env-file sementara (`600`, langsung dihapus),
    tidak pernah muncul di argumen proses (`ps`).
-   `no_check_bucket` aktif sehingga token cukup berizin Object Read & Write
    (tidak butuh izin membuat bucket).

### Backup manual ke R2

Menu **6** menawarkan upload ke `<prefix>/manual/` setelah backup selesai,
jika R2 sudah dikonfigurasi.

### Restore dari R2

1.  Menu **14 → 7**: pilih folder `auto` atau `manual`, lalu pilih file dari
    30 file terbaru.
2.  File diunduh ke `/opt/postgres/backups/downloaded/`.
3.  Jalankan menu **7** dengan path file tersebut.

### Catatan keamanan R2

-   File backup berisi seluruh data, dan `globals-*.sql` berisi hash password
    role. Pastikan bucket **tidak** publik dan token hanya untuk bucket itu.
-   R2 mengenkripsi data saat disimpan (at rest), tetapi Cloudflare secara
    teknis bisa membaca isinya. Jika butuh enkripsi sisi klien, bisa
    ditambahkan dengan `rclone crypt` (passphrase wajib disimpan aman;
    hilang = backup tidak bisa dibuka).
-   Opsional: pasang **Object lifecycle rule** di bucket sebagai pengaman
    tambahan (mis. hapus objek di `postgres/` setelah 90 hari).

## Restore database

Pilih menu **7. Restore database**. Script otomatis mencari semua backup
`.dump` yang tersedia:

-   Lokal: `backups/` (manual & pengaman), `backups/auto/`, `backups/downloaded/`.
-   R2 (jika dikonfigurasi): `<prefix>/auto/` dan `<prefix>/manual/`.

Langkah:

1.  Isi filter nama database, atau kosongkan untuk menampilkan semua.
2.  Pilih nomor backup dari daftar (maks. 40 terbaru, urut terbaru dulu):

    ``` text
     No  Waktu             Sumber      Database   Ukuran  File
      1  2026-11-02 02:31  lokal       qolcore      120M  qolcore-20261102-023102.dump
      2  2026-11-01 02:30  R2:auto     qolcore      119M  qolcore-20261101-023011.dump
      m = masukkan path file manual
    ```

    File yang ada di lokal dan R2 sekaligus hanya ditampilkan sekali (salinan
    lokal diutamakan). Ketik `m` untuk memasukkan path file sendiri.
3.  Jika sumbernya R2, file di-download dulu ke `backups/downloaded/`.
4.  File divalidasi (`pg_restore -l`).
5.  Database tujuan otomatis disarankan sesuai nama di file backup (tekan
    Enter untuk memakai saran, atau ketik nama lain). Jika database tersebut
    belum ada di server, buat dulu lewat menu 5.
6.  Pilih apakah database tujuan di-backup dulu (default: ya), lalu ketik
    `RESTORE`.

Perintah restore menggunakan opsi:

-   `--no-owner`
-   `--no-acl`
-   `--clean`
-   `--if-exists`
-   `--single-transaction` (gagal = tidak ada perubahan sama sekali)
-   `--exit-on-error`
-   `--role=<pemilik database>` jika pemilik bukan admin

Dengan `--role`, semua tabel/sequence/view hasil restore dimiliki oleh
pemilik database (user aplikasi), bukan admin. Jika restore gagal karena
dump berisi objek yang hanya boleh dibuat superuser (mis. extension
tertentu), script menawarkan restore ulang sebagai admin lalu memindahkan
kepemilikan schema, tabel, sequence, view, function, dan type ke pemilik
database.

**Perhatian:** `--clean --if-exists` menghapus objek yang akan
dipulihkan jika objek dengan nama yang sama sudah ada di database
tujuan. Operasi ini dapat mengganti data/objek yang ada. Buat backup
database tujuan terlebih dahulu sebelum restore jika datanya masih
diperlukan.

Script tidak membuat database tujuan secara otomatis. Buat database
terlebih dahulu melalui menu 5 jika belum tersedia.

## Ganti password user/role

Pilih menu **13. Ganti password user/role**, pilih username (default: admin
dari `.env`), lalu masukkan password baru atau kosongkan agar dibuat otomatis.
Ketik `GANTI` untuk konfirmasi.

Urutan yang dilakukan script:

1.  `ALTER ROLE ... PASSWORD` di PostgreSQL yang sedang berjalan, lewat socket
    lokal di container (tidak butuh password lama, tidak perlu restart).
2.  Jika yang diganti adalah admin, `POSTGRES_PASSWORD` di `.env` diperbarui
    secara atomik (baris lain tidak berubah, permission tetap `600`).
3.  Login TCP dengan password baru diuji otomatis.
4.  Untuk admin, ada opsi recreate container supaya environment container tidak
    lagi menyimpan password lama (data tetap aman, downtime beberapa detik).

Catatan:

-   `POSTGRES_PASSWORD` di `.env` hanya dipakai image Docker saat inisialisasi
    pertama. Mengubah `.env` secara manual **tidak** mengubah password di
    database. Selalu gunakan menu 13.
-   Koneksi yang sedang terbuka tidak diputus. Perbarui DSN/secret aplikasi
    sebelum aplikasi membuka koneksi baru.
-   Password admin harus minimal 16 karakter dengan karakter `A-Z a-z 0-9 @ # % + = . _ -`.
    Password user lain minimal 12 karakter.
-   Mengganti **nama** user tidak didukung.

## Hapus database + user

Menu **15**. Langkah:

1.  Pilih database dari daftar.
2.  Script menampilkan jumlah koneksi aktif dan user/role terkait. Jika ada
    koneksi aktif, Anda diminta setuju memutusnya (jika tidak, dibatalkan).
3.  Pilih apakah user/role yang **hanya** dipakai untuk database ini ikut
    dihapus (default: ya).
4.  Backup database dulu (default: ya) ke `backups/`.
5.  Ketik ulang **nama database** untuk konfirmasi.

Detail PostgreSQL:

-   Database utama admin (`POSTGRES_DB` di `.env`) dan database sistem
    (`postgres`, `template0/1`) tidak bisa dihapus dari menu ini.
-   Koneksi aktif diputus dengan `DROP DATABASE ... WITH (FORCE)`.
-   Role pemilik ditawarkan untuk dihapus hanya jika bukan admin/superuser dan
    tidak memiliki database lain. Jika role masih punya objek/hak di database
    lain, role tidak dihapus dan alasannya ditampilkan.

## Rotasi sertifikat SSL

Menu **16** menampilkan sertifikat yang sedang dipakai (subject, issuer,
tanggal berakhir, sisa hari), lalu:

  Pilihan   Fungsi
  --------- ----------------------------------------------------------------------
  1         Buat sertifikat self-signed baru (berlaku 10 tahun)
  2         Pakai sertifikat sendiri (mis. dari CA / Let's Encrypt): fullchain + key

Untuk pilihan 2, script memastikan file berformat PEM, key tidak ber-passphrase,
key **cocok** dengan sertifikat, dan sertifikat belum kedaluwarsa.

-   Sertifikat lama disimpan di `backups/ssl-YYYYMMDD-HHMMSS/`.
-   Sertifikat baru dimuat **tanpa restart**.
-   Jika server menolak sertifikat baru, file lama otomatis dikembalikan dan
    server tetap memakai sertifikat sebelumnya.
-   Bagian atas menu menampilkan **peringatan** jika sertifikat berakhir dalam
    kurang dari 30 hari (atau sudah kedaluwarsa); peringatan yang sama ikut
    dikirim di notifikasi Telegram.

Lokasi sertifikat: `certs/server.crt` dan `certs/server.key` (di-mount satu per satu ke container; ditulis ulang di tempat agar container langsung melihat file baru, lalu `pg_reload_conf()`).

## Notifikasi Telegram

Menu **14 → 8** (auto backup & R2):

1.  Buat bot lewat **@BotFather** → dapatkan token (`123456:ABC...`).
2.  Kirim pesan ke bot (atau tambahkan bot ke grup), lalu ambil chat ID dari
    `https://api.telegram.org/bot<TOKEN>/getUpdates` (field `chat.id`; grup
    biasanya diawali `-100`).
3.  Isi token, chat ID, dan kapan dikirim: **hanya jika gagal** (default) atau
    **setiap auto backup**. Pesan tes langsung dikirim.

Isi pesan: status (✅/❌), host, folder, container, ringkasan per database,
status upload R2, baris error, dan peringatan sertifikat jika ada.

-   Disimpan di `telegram.conf` (root, `600`). Token dikirim ke `curl` lewat
    stdin sehingga tidak muncul di `ps`. Butuh `curl` di host.
-   Gagal mengirim notifikasi **tidak** mengubah status backup (backup sukses
    tetap tercatat sukses).
-   Menu 14 → 9 mengirim pesan tes, 14 → 10 mematikan notifikasi.

## Uninstall instance

Menu **17**. Yang selalu dilakukan:

-   Jadwal auto backup instance ini dimatikan.
-   Container dihentikan dan dihapus (`docker compose down`).
-   Salinan script di `/usr/local/sbin` dihapus **hanya jika** tidak dipakai
    instance lain.

Yang ditanyakan:

  Pertanyaan                                   Default   Catatan
  -------------------------------------------- --------- -------------------------------
  Backup terakhir semua database               Ya        Ke `backups/`
  Hapus data (`data/`) + konfigurasi            Tidak     Butuh ketik `HAPUS DATA`
  Hapus folder `backups/`                       Tidak     Hanya ditanya jika data dihapus

Konfirmasi akhir: ketik **nama container**. Script itu sendiri, backup di R2,
dan image Docker tidak dihapus.

-   Data disimpan → instance bisa dinyalakan lagi dengan menu 2.
-   Data dihapus → folder kembali ke kondisi "Belum setup" dan siap untuk
    setup baru (menu 1).

## Koneksi dan SSL

PostgreSQL dijalankan dengan SSL aktif menggunakan sertifikat
self-signed yang dibuat saat setup.

Contoh connection string:

``` text
postgresql://qolcore_owner:PASSWORD@HOST:5434/qolcore?sslmode=require
```

`sslmode=require` mengenkripsi koneksi, tetapi tidak memverifikasi
identitas server seperti verifikasi CA. Untuk verifikasi identitas
server, gunakan sertifikat dari CA tepercaya dan konfigurasi klien yang
sesuai.

Secara default `pg_hba.conf` hanya menerima koneksi TCP ber-SSL
(`hostssl ... scram-sha-256`) dan menolak koneksi non-SSL. Aplikasi wajib
memakai `sslmode=require` atau lebih ketat. Koneksi via socket di dalam
container (dipakai script lewat `docker exec`) memakai `trust`.

Menu **11** menjalankan `SHOW ssl;` dan menampilkan aturan `pg_hba` aktif.

## Keamanan jaringan

Default bind address adalah `127.0.0.1`. Jika memilih `0.0.0.0`, port
PostgreSQL dipublikasikan pada seluruh interface IPv4 host.

**Penting:** port yang dipublikasikan Docker **tidak** tunduk pada aturan
UFW / chain `INPUT`, karena Docker memasang aturan iptables sendiri.
Batasi akses lewat Oracle Cloud Security List/NSG dan/atau chain
`DOCKER-USER`, misalnya:

``` bash
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 5434 --ctdir ORIGINAL -j DROP
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 5434 --ctdir ORIGINAL -s 10.0.0.0/24 -j ACCEPT
```

Simpan aturan secara permanen (mis. `iptables-persistent`).

Rekomendasi:

-   Jika hanya aplikasi di server yang sama yang perlu mengakses
    PostgreSQL, pilih bind address `127.0.0.1`.
-   Jika akses dari VM atau server lain diperlukan, batasi sumber IP
    pada firewall host dan Oracle Cloud Security List/Network Security
    Group.
-   Jangan membuka port `5434` ke `0.0.0.0/0` tanpa kebutuhan dan
    kontrol akses yang jelas.
-   Gunakan password kuat dan unik untuk setiap role.
-   Batasi hak akses tiap user hanya pada database yang diperlukan.
-   Gunakan koneksi SSL dan pertimbangkan sertifikat CA tepercaya untuk
    koneksi produksi.

## Operasi Docker manual

Perintah berikut dapat dijalankan jika diperlukan:

``` bash
cd /opt/postgres

# Status
docker compose ps

# Start
docker compose up -d

# Stop
docker compose stop

# Restart
docker compose restart

# Log terakhir
docker logs --tail 100 qolcore-postgres

# Log live
docker logs -f qolcore-postgres
```

Sesuaikan nama container jika saat setup memilih nama yang berbeda.

## Batasan dan catatan operasional

-   Script mengelola satu instance/container PostgreSQL per folder proyek
    (folder tempat script berada).
-   Script tidak menyediakan ganti nama role atau pengelolaan firewall.
-   Menu backup meminta nama database dan menggunakan role admin dari
    konfigurasi untuk menjalankan `pg_dump`.
-   Menu restore membutuhkan file `.dump` yang tersedia di filesystem
    host.
-   Restore dilakukan ke database yang sudah ada.
-   Log live berjalan sampai `Ctrl+C`; `Ctrl+C` di aksi mana pun membatalkan
    aksi tersebut dan kembali ke menu.
-   Error pada sebuah aksi tidak menutup script; pesan error ditampilkan lalu
    kembali ke menu.
-   `.env` dibaca sebagai data (bukan di-`source`), hanya key `POSTGRES_*`
    yang dikenal yang dipakai.
-   Untuk stack lama yang dibuat manual, `POSTGRES_BIND` default `127.0.0.1`
    hanya untuk tampilan; konfigurasi port sebenarnya tetap di `compose.yaml`.
-   Lindungi folder proyek dan lakukan backup off-server
    secara berkala.

## Troubleshooting

### Docker Compose tidak ditemukan

Pastikan Docker Compose plugin tersedia:

``` bash
docker compose version
```

### `mkdir: cannot create directory '/var/lib/postgresql': Permission denied`

Terjadi pada setup dengan versi script lama: folder `/opt/postgres/data`
dibuat milik `root` dengan mode `700`, padahal entrypoint image PostgreSQL 18
berjalan sebagai user `postgres` (uid 999 untuk image Debian, 70 untuk
Alpine) dan harus bisa masuk ke folder itu.

Perbaikan: jalankan versi script terbaru lalu pilih menu **2. Start
PostgreSQL**. Script otomatis mengubah owner folder `data/` ke user postgres
di container dan membuat ulang container. Cara manual:

``` bash
sudo chown 999:999 /opt/postgres/data && sudo chmod 700 /opt/postgres/data
cd /opt/postgres && sudo docker compose up -d --force-recreate
```

### Container tidak berjalan atau PostgreSQL belum siap

Periksa status dan log:

``` bash
cd /opt/postgres
docker compose ps
docker logs --tail 200 qolcore-postgres
```

Jika nama container diubah saat setup, gunakan nama tersebut.

### Koneksi dari luar server gagal

Periksa:

1.  Bind address pada `/opt/postgres/.env`.
2.  Port host yang dikonfigurasi.
3.  Firewall OS.
4.  Oracle Cloud Security List atau Network Security Group.
5.  Status container dan log PostgreSQL.

### SSL error pada client

Pastikan client menggunakan mode SSL yang sesuai. Sertifikat yang dibuat
script adalah self-signed; client yang melakukan verifikasi
sertifikat/hostname memerlukan konfigurasi trust CA dan identitas
sertifikat yang sesuai.

------------------------------------------------------------------------

## Lisensi

Dirilis di bawah [MIT License](LICENSE). Copyright (c) 2026 Raqolbi.

Script ini disediakan "apa adanya" tanpa jaminan apa pun. Uji terlebih
dahulu di lingkungan non-produksi dan selalu simpan backup off-server
sebelum menjalankan restore atau perubahan konfigurasi.
