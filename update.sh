#!/bin/bash

YELLOW='\033[0;33m'
RED='\033[1;91m'
GREEN='\033[1;32m'
WHITE='\033[1;37m'
BG_HEADER='\033[40;1;37m'
NC='\033[0m'

if (( EUID != 0 )); then
    echo -e "${RED}ERROR: Script update harus dijalankan sebagai root.${NC}" >&2
    exit 1
fi

REPO_ZIP="https://raw.githubusercontent.com/Pujianto1219/autoscript/main/menu/menu.zip"
WORK_DIR=""
BAR_STATUS="/tmp/.update_bar_rc.$$"
LAST_ERR="/tmp/.update_last_err.$$"

cleanup_all() {
    tput cnorm 2>/dev/null || true
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    rm -f "$BAR_STATUS" "$LAST_ERR"
}
trap cleanup_all EXIT INT TERM

fun_bar() {
    local func_name="$1"
    rm -f "$BAR_STATUS" "$LAST_ERR"

    (
        "$func_name"
        echo "$?" > "$BAR_STATUS"
    ) >/dev/null 2>&1 &
    local bg_pid=$!

    tput civis 2>/dev/null || true
    echo -ne "${YELLOW}Please Wait Loading ${WHITE}- ${YELLOW}["
    while kill -0 "$bg_pid" 2>/dev/null; do
        for ((i = 0; i < 18; i++)); do
            kill -0 "$bg_pid" 2>/dev/null || break
            echo -ne "\033[0;32m#"
            sleep 0.1
        done
        if ! kill -0 "$bg_pid" 2>/dev/null; then
            break
        fi
        echo -e "${YELLOW}]"
        sleep 0.3
        tput cuu1 2>/dev/null || true
        tput dl1 2>/dev/null || true
        echo -ne "${YELLOW}Please Wait Loading ${WHITE}- ${YELLOW}["
    done

    wait "$bg_pid" 2>/dev/null || true
    local rc=1
    [ -r "$BAR_STATUS" ] && rc=$(cat "$BAR_STATUS")
    tput cnorm 2>/dev/null || true

    if [[ "$rc" == "0" ]]; then
        echo -e "${YELLOW}]${WHITE} - ${GREEN}OK !${NC}"
        return 0
    else
        echo -e "${YELLOW}]${WHITE} - ${RED}FAILED !${NC}"
        return 1
    fi
}

res1() {
    WORK_DIR=$(mktemp -d /tmp/update_pkg.XXXXXX)
    local zip_file="${WORK_DIR}/menu.zip"
    local ext_dir="${WORK_DIR}/extract"
    local src_dir=""
    mkdir -p "$ext_dir"

    local url="${REPO_ZIP}?v=$(date +%s)"

    # 1. Unduh menu.zip (dengan timeout & anti-cache)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 -H "Cache-Control: no-cache" -o "$zip_file" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-cache --timeout=15 --tries=2 -O "$zip_file" "$url" 2>/dev/null
    else
        echo "curl/wget tidak ditemukan di VPS." > "$LAST_ERR"
        return 1
    fi

    if [ ! -s "$zip_file" ]; then
        echo "Gagal mengunduh menu.zip dari GitHub." > "$LAST_ERR"
        return 1
    fi

    # 2. Deteksi jenis file: ZIP asli vs Script self-extract hasil enc (AcilshopENC)
    if unzip -tq "$zip_file" >/dev/null 2>&1; then
        if ! unzip -oq "$zip_file" -d "$ext_dir" >/dev/null 2>&1; then
            echo "Gagal mengekstrak arsip menu.zip." > "$LAST_ERR"
            return 1
        fi
    else
        local first_line
        first_line=$(head -n 1 "$zip_file" | sed '1s/^\xef\xbb\xbf//; s/\r$//')
        if [[ "$first_line" == "#!/bin/bash"* || "$first_line" == "#!/usr/bin/env bash"* ]]; then
            # Bersihkan CRLF/BOM pada file enc itu sendiri sebelum dijalankan
            sed -i '1s/^\xef\xbb\xbf//; s/\r$//' "$zip_file"
            if ! bash "$zip_file" "$ext_dir" >/dev/null 2>&1; then
                echo "Gagal mengekstrak menu.zip (mode enc)." > "$LAST_ERR"
                return 1
            fi
        else
            echo "Format menu.zip tidak valid (bukan ZIP maupun script enc)." > "$LAST_ERR"
            return 1
        fi
    fi

    # 3. Tentukan folder hasil ekstrak (mendukung struktur menu/* maupun langsung file)
    if [ -d "${ext_dir}/menu" ]; then
        src_dir="${ext_dir}/menu"
    else
        src_dir="$ext_dir"
    fi

    if [ -z "$(find "$src_dir" -maxdepth 1 -type f 2>/dev/null)" ]; then
        echo "Tidak ada file script ditemukan di dalam menu.zip." > "$LAST_ERR"
        return 1
    fi

    # 4. Pengaman utama: hapus BOM & CRLF khusus file teks (aman untuk binary) + chmod +x
    find "$src_dir" -maxdepth 1 -type f -exec grep -Iq . {} \; -exec sed -i '1s/^\xef\xbb\xbf//; s/\r$//' {} +
    find "$src_dir" -maxdepth 1 -type f -exec chmod +x {} +

        # 5. Pindahkan ke /usr/local/sbin/
    find "$src_dir" -maxdepth 1 -type f -exec mv -f {} /usr/local/sbin/ \;

    # 6. Pengaman akhir untuk seluruh script teks di /usr/local/sbin/
    find /usr/local/sbin -maxdepth 1 -type f -exec grep -Iq . {} \; -exec sed -i '1s/^\xef\xbb\xbf//; s/\r$//' {} +
    chmod +x /usr/local/sbin/* >/dev/null 2>&1 || true

    # 7. Auto-patch error redirection pada script member*, cek*, & daemon sshquota
    local f
    for f in /usr/local/sbin/{member,cek}{ssh,vmess,vless,trojan} /usr/bin/sshquota; do
        [ -f "$f" ] || continue
        sed -i 's/\r$//' "$f"
        sed -i -E 's#tr -d '\''\[:space:\]'\'' < "([^"]+)" 2>/dev/null#[ -r "\1" ] \&\& tr -d '\''[:space:]'\'' < "\1" || true#g' "$f"
        chmod +x "$f"
    done
    systemctl is-active --quiet limitssh && systemctl restart limitssh >/dev/null 2>&1 || true

    rm -rf "$WORK_DIR"
    WORK_DIR=""
    return 0
}

clear
echo -e "${YELLOW}──────────────────────────────────────────${NC}"
echo -e "${BG_HEADER}       UPDATE AUTOSCRIPT IN PROCESS       ${NC}"
echo -e "${YELLOW}──────────────────────────────────────────${NC}"
echo -e ""
echo -e "${RED}Update Script Service${WHITE}"

UPDATE_OK=0
if fun_bar res1; then
    UPDATE_OK=1
fi

if [ "$UPDATE_OK" -ne 1 ] && [ -s "$LAST_ERR" ]; then
    echo -e "${RED}[ ERROR ] $(cat "$LAST_ERR")${NC}"
fi

# Restart netfilter-persistent hanya jika terpasang
if systemctl show -p LoadState netfilter-persistent 2>/dev/null | grep -q '=loaded$'; then
    systemctl restart netfilter-persistent >/dev/null 2>&1 || true
fi

# Hapus file update.sh sementara saja (jangan hapus jika dijalankan dari /usr/local/sbin atau /usr/bin)
rm -f /root/update.sh 2>/dev/null || true
if [ -f "$0" ] && [[ "$0" != "/usr/local/sbin/"* ]] && [[ "$0" != "/usr/bin/"* ]]; then
    rm -f "$0" 2>/dev/null || true
fi

echo -e "${YELLOW}──────────────────────────────────────────${NC}"
echo -e ""
if [ -t 1 ]; then
    read -n 1 -s -r -p "Press [ Enter ] To Back On Menu"
    command -v menu >/dev/null 2>&1 && menu
fi