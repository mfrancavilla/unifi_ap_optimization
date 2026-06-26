#!/bin/bash

# ==============================================================================
# INPUT VALIDATION & SYSTEM ENVIRONMENT CHECKS
# ==============================================================================
set -o pipefail

if ! command -v jq &>/dev/null; then
    echo "[CRITICAL ERROR] The 'jq' utility is missing locally. Please install it first." >&2
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 '<JSON_ARRAY_OF_IPS>'" >&2
    echo "Example: $0 '[\"192.168.1.20\", \"192.168.1.127\"]'" >&2
    exit 1
fi

CANDIDATE_IPS=()
while read -r line; do
    [[ -n "$line" ]] && CANDIDATE_IPS+=("$line")
done < <(echo "$1" | jq -r '.[]' 2>/dev/null)

if [ ${#CANDIDATE_IPS[@]} -eq 0 ]; then
    echo "[CRITICAL ERROR] Failed to parse input. Ensure argument is a valid JSON array of strings." >&2
    exit 1
fi

read -r -p "Enter SSH Username: " SSH_USER
if [ -z "$SSH_USER" ]; then
    echo "[CRITICAL ERROR] An SSH username is required to connect to the nodes." >&2
    exit 1
fi

if [ -z "$SSH_KEY" ]; then
    if [ -f "$HOME/.ssh/id_ed25519" ]; then
        SSH_KEY="$HOME/.ssh/id_ed25519"
    else
        SSH_KEY="$HOME/.ssh/id_rsa"
    fi
fi

if [ ! -f "$SSH_KEY" ]; then
    echo "[CRITICAL ERROR] Identity private key file not found. Checked: $SSH_KEY" >&2
    exit 1
fi

JSON_OUT=$(mktemp)
if [[ ! -f "$JSON_OUT" ]]; then
    echo "[CRITICAL ERROR] Secure temporary workspace instantiation blocked." >&2
    exit 1
fi
exec 3>"$JSON_OUT"

echo "{" >&3
echo "  \"scan_timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"," >&3
echo "  \"access_points\": [" >&3

TOTAL_TARGETS=${#CANDIDATE_IPS[@]}
CURRENT_COUNT=0
VALID_AP_COUNT=0

SSH_FLAGS=(-i "$SSH_KEY" \
           -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o GlobalKnownHostsFile=/dev/null \
           -o BatchMode=yes \
           -o NumberOfPasswordPrompts=0)

# ==============================================================================
# REMOTELY EXECUTED DIAGNOSTIC SCRIPTS
# ==============================================================================
REMOTE_CMD=$(cat << 'EOF'
unifi_name=$(mca-cli-op info 2>/dev/null | awk -F': ' '/Hostname/ {print $2}')
[ -z "$unifi_name" ] && unifi_name=$(hostname 2>/dev/null)
[ -z "$unifi_name" ] && unifi_name="Unknown-AP"

primary_mac=$(ip link show 2>/dev/null | awk '/ether/ {print $2; exit}' | tr '[:upper:]' '[:lower:]')
[ -z "$primary_mac" ] && primary_mac=$(ifconfig 2>/dev/null | awk '/HWaddr/ {print $5; exit}' | tr '[:upper:]' '[:lower:]')

if iwconfig 2>/dev/null | grep -q 'RTWIFI'; then
    rf_data=$(iwconfig 2>/dev/null | awk '
        /^[a-z0-9\.]+/ { vif=$1; }
        /Channel=/ {
            if (vif != "") {
                split($0, chunks, "Channel=");
                split(chunks[2], subchunks, " ");
                chan=subchunks[1];
                if(chan != "0" && chan != "") {
                    freq=2412; width=20;
                    if(chan > 14) { freq=5000 + (chan * 5); width=80; }
                    else { freq=2407 + (chan * 5); }
                    vifs[vif] = chan "," freq "," width;
                }
            }
        }
        END {
            first=1;
            for(v in vifs) {
                split(vifs[v], data, ",");
                if(!first) printf ",\n";
                printf "        {\n          \"interface\": \"%s\",\n          \"channel\": %d,\n          \"frequency_mhz\": %d,\n          \"width_mhz\": %d\n        }", v, data[1], data[2], data[3];
                first=0;
            }
            if(!first) printf "\n";
        }
    ')
else
    raw_iw=$(mca-roam-info 2>/dev/null || iw dev 2>/dev/null)
    rf_data=$(echo "$raw_iw" | awk '
        /Inf:/ { split($0, a, " "); current_vif=a[2]; gsub(/[^a-zA-Z0-9\-]/, "", current_vif); next; }
        /Interface/ { current_vif=$2; next; }
        /Band:/ { band[current_vif] = $2; }
        /Channel:/ { chan[current_vif] = $2; }
        /Frequency:/ { freq[current_vif] = $2; }
        /channel/ { 
            if (current_vif != "") {
                gsub(/[\(\),]/, "", $0);
                for (i=1; i<=NF; i++) {
                    if ($i == "channel") { chan[current_vif] = $(i+1); }
                    if ($i == "MHz" && $(i-1) ~ /^[0-9]+$/) {
                        if ($(i-2) == "width") { width[current_vif] = $(i-1); }
                        else { freq[current_vif] = $(i-1); }
                    }
                }
            }
        }
        END {
            first=1;
            for (v in chan) {
                if (v == "" || chan[v] + 0 == 0) continue;
                f_val = freq[v] + 0;
                if (f_val == 0) {
                    if (chan[v] <= 14) { f_val = 2407 + (chan[v] * 5); }
                    else if (chan[v] >= 36 && chan[v] <= 177) { f_val = 5000 + (chan[v] * 5); }
                    else { f_val = 4000; }
                }
                w_val = width[v] + 0;
                if (w_val == 0) { if (chan[v] > 14) { w_val = 80; } else { w_val = 20; } }
                if (!first) printf ",\n";
                printf "        {\n          \"interface\": \"%s\",\n          \"channel\": %d,\n          \"frequency_mhz\": %d,\n          \"width_mhz\": %d\n        }", v, chan[v], f_val, w_val;
                first=0;
            }
            if (!first) printf "\n";
        }
    ')
fi

echo "===NAME_START===$unifi_name===NAME_END==="
echo "===MAC_START===$primary_mac===MAC_END==="
echo "===RF_START==="
echo "$rf_data"
echo "===RF_END==="
EOF
)

# --------------------------------------------------------------------------
# INTER-AP NEIGHBOR SCANNING ENGINE (STANDARDIZED ON TRUE ABSOLUTE SIGNAL)
# --------------------------------------------------------------------------
REMOTE_SCAN_CMD=$(cat << 'EOF'
if command -v mca-dump &>/dev/null; then
    mca-dump | awk '
        BEGIN { FS="\"" }
        /\"bssid\"/ { 
            gsub(/[^a-fA-F0-9:]/, "", $4); 
            b_idx++; 
            b_list[b_idx] = tolower($4); 
            next; 
        }
        /\"essid\"/ { 
            e_idx++; 
            e_list[e_idx] = $4; 
            next; 
        }
        /\"channel\"/ { 
            gsub(/[^0-9]/, "", $4); 
            c_idx++; 
            c_list[c_idx] = $4; 
            next; 
        }
        /\"signal\"/ { 
            split($0, parts, ":");
            clean_val = parts[2];
            gsub(/[^0-9\-]/, "", clean_val);
            s_idx++;
            s_list[s_idx] = clean_val + 0;
            next; 
        }
        END {
            max_nodes = b_idx;
            if (s_idx > max_nodes) max_nodes = s_idx;
            
            printed = 0;
            for (i = 1; i <= max_nodes; i++) {
                b_val = b_list[i];
                e_val = e_list[i];
                c_val = c_list[i] ? c_list[i] : 0;
                s_val = s_list[i];
                
                if (b_val == "" && i > 1) b_val = b_list[i-1];
                if (s_val == "" || s_val == 0) continue;
                
                if (printed) printf ",\n";
                printf "        {\n          \"bssid\": \"%s\",\n          \"signal_dbm\": %d,\n          \"channel\": %d,\n          \"ssid\": \"%s\"\n        }", b_val, s_val, c_val, e_val;
                printed = 1;
            }
            if (printed) printf "\n";
        }
    '
elif iwconfig 2>/dev/null | grep -q 'RTWIFI'; then
    survey_data=""
    for iface in $(iwconfig 2>/dev/null | awk '/^(ra|apcli)[0-9]+/ {print $1}'); do
        iwpriv "$iface" CloudScan 1 &>/dev/null
        iwpriv "$iface" Scan 1 &>/dev/null
    done
    sleep 2.5
    for iface in $(iwconfig 2>/dev/null | awk '/^(ra|apcli)[0-9]+/ {print $1}'); do
        raw_survey=$(iwpriv "$iface" get_site_survey 2>/dev/null)
        if echo "$raw_survey" | grep -q "BSSID"; then survey_data="${survey_data}${raw_survey}\n"; fi
    done

    if [ -n "$survey_data" ]; then
        echo -e "$survey_data" | awk '
            NR > 3 {
                chan = $1;
                match($0, /([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/);
                if (RSTART > 0) {
                    bssid = tolower(substr($0, RSTART, RLENGTH));
                    ssid_part = substr($0, 4, RSTART - 4);
                    gsub(/[ \t]+$/, "", ssid_part);
                    if (ssid_part == "") { ssid = "Hidden Network"; } else { ssid = ssid_part; }
                    
                    post_bssid = substr($0, RSTART + RLENGTH);
                    match(post_bssid, /[0-9]+/);
                    sig_pct = substr(post_bssid, RSTART, RLENGTH);
                    
                    if (sig_pct != "") {
                        # Calculate true mathematical absolute signal level from ratio percentage
                        calculated_signal = int((sig_pct / 2) - 100);
                        if (calculated_signal < -100) calculated_signal = -100;
                        if (calculated_signal > -30)  calculated_signal = -30;
                        if (bssid != "" && chan ~ /^[0-9]+$/) { targets[bssid] = calculated_signal "," chan "," ssid; }
                    }
                }
            }
            END {
                f=1;
                for (t in targets) {
                    split(targets[t], val, ",");
                    if (!f) printf ",\n";
                    printf "        {\n          \"bssid\": \"%s\",\n          \"signal_dbm\": %d,\n          \"channel\": %d,\n          \"ssid\": \"%s\"\n        }", t, val[1], val[2], val[3];
                    f=0;
                }
                if (!f) printf "\n";
            }
        '
    fi
fi
EOF
)

# ==============================================================================
# DATA COLLECTION ENGINE LOOP
# ==============================================================================
for AP_IP in "${CANDIDATE_IPS[@]}"; do
    CURRENT_COUNT=$((CURRENT_COUNT + 1))

    echo "======================================================================" >&2
    echo " PROGRESS: [$CURRENT_COUNT/$TOTAL_TARGETS] Processing Node: $AP_IP" >&2
    echo "======================================================================" >&2

    if ! nc -w 2 -z "$AP_IP" 22 2>/dev/null; then
        echo "  [-] Node $AP_IP dropped connection handshake. Skipping..." >&2
        continue
    fi

    RAW_RESPONSE=$(ssh "${SSH_FLAGS[@]}" "$SSH_USER@$AP_IP" "$REMOTE_CMD" 2>/dev/null)
    SIGNAL_BLOCKS=$(ssh "${SSH_FLAGS[@]}" "$SSH_USER@$AP_IP" "$REMOTE_SCAN_CMD" 2>/dev/null)

    if [ -z "$RAW_RESPONSE" ]; then
        echo "  [-] Profiling execution returned empty data on $AP_IP. Verify keys." >&2
        continue
    fi

    TARGET_NAME=$(echo "$RAW_RESPONSE" | awk -F'===' '/===NAME_START===/ {print $3}')
    TARGET_MAC=$(echo "$RAW_RESPONSE" | awk -F'===' '/===MAC_START===/ {print $3}')
    PARSED_BLOCKS=$(echo "$RAW_RESPONSE" | sed -n '/===RF_START===/,/===RF_END===/p' | grep -v "===")

    if [ "$VALID_AP_COUNT" -gt 0 ]; then
        echo "    }," >&3
    fi
    VALID_AP_COUNT=$((VALID_AP_COUNT + 1))

    HOSTNAME="${TARGET_NAME:-AP-$AP_IP}"

    echo "    {" >&3
    echo "      \"hostname\": \"$HOSTNAME\"," >&3
    echo "      \"ip_address\": \"$AP_IP\"," >&3
    echo "      \"mac_address\": \"$TARGET_MAC\"," >&3
    echo "      \"rf_profiles\": [" >&3
    if [ -n "$PARSED_BLOCKS" ]; then echo "$PARSED_BLOCKS" >&3; fi
    echo "      ]," >&3
    echo "      \"inter_ap_signals\": [" >&3
    if [ -n "$SIGNAL_BLOCKS" ]; then echo "$SIGNAL_BLOCKS" >&3; fi
    echo "      ]" >&3
    echo "  [+] Extracted operational RF specifications safely for $HOSTNAME." >&2
done

if [ "$VALID_AP_COUNT" -gt 0 ]; then
    echo "    }" >&3
fi
echo "  ]" >&3
echo "}" >&3
exec 3>&-

if [ "$VALID_AP_COUNT" -eq 0 ]; then
    echo -e "\n[CRITICAL ERROR] No targets responded to profiling queries. Aborting matrix calculations." >&2
    rm -f "$JSON_OUT"
    exit 1
fi

cat "$JSON_OUT"

# ==============================================================================
# MATRIX GENERATION ENGINE
# ==============================================================================
echo -e "\n======================================================================" >&2
echo " GENERATING INTER-AP SIGNAL MATRIX (dBm RSSI)" >&2
echo "======================================================================" >&2

awk '
BEGIN { FS="\"" }
/\"hostname\"/ { host = $4 }
/\"mac_address\"/ { 
    mac = tolower($4)
    if (mac != "" && host != "") {
        mac_to_host[mac] = host
        hosts[host] = 1
        current_host = host
    }
}
/\"bssid\"/ { current_bssid = tolower($4) }
/\"signal_dbm\"/ { 
    split($0, line_parts, ":")
    clean_val = line_parts[2]
    gsub(/[^0-9\-]/, "", clean_val)
    sig_val = clean_val + 0
    
    # Ensure value maintains proper negative polarity
    if (sig_val > 0) {
        sig_val = -sig_val
    }
    
    if (current_host != "" && current_bssid != "") {
        matrix[current_host, current_bssid] = sig_val
    }
}
END {
    printf "%-18s", "Observer \\ Target"
    for (h in hosts) { printf " | %-17s", h }
    print ""
    
    printf "%-18s", "------------------"
    for (h in hosts) { printf " | %-17s", "-----------------" }
    print ""

    for (local_host in hosts) {
        printf "%-18s", local_host
        for (remote_host in hosts) {
            if (local_host == remote_host) {
                printf " | %-17s", "     [Self]"
            } else {
                found = 0
                val = ""
                for (m in mac_to_host) {
                    if (mac_to_host[m] == remote_host) {
                        prefix = substr(m, 1, 14)
                        for (pair in matrix) {
                            split(pair, k, SUBSEP)
                            if (k[1] == local_host && substr(k[2], 1, 14) == prefix) {
                                val = matrix[pair]
                                found = 1
                                break
                            }
                        }
                    }
                    if (found) break
                }
                if (found && val != "") { printf " | %-17s", (val " dBm") } 
                else { printf " | %-17s", "     (Unseen)" }
            }
        }
        print ""
    }
}
' "$JSON_OUT"

rm -f "$JSON_OUT"
echo "======================================================================" >&2
echo " COMPLETE: Clean structural serialization and matrix verified." >&2
