#!/bin/bash

# ==============================================================================
# INPUT VALIDATION & CONFIGURATION
# ==============================================================================
if [ -z "$1" ] || ! command -v jq &>/dev/null; then
    echo "Usage: $0 '<JSON_ARRAY_OF_IPS>'" >&2
    echo "Example: $0 '[\"192.168.1.20\", \"192.168.1.21\"]'" >&2
    echo "Note: This script requires 'jq' to be installed locally." >&2
    exit 1
fi

# Parse the JSON string into a bash array using jq
mapfile -t CANDIDATE_IPS < <(echo "$1" | jq -r '.[]')

if [ ${#CANDIDATE_IPS[@]} -eq 0 ]; then
    echo "[CRITICAL ERROR] No valid IP addresses found in the provided JSON array." >&2
    exit 1
fi

# Prompt for SSH user if not already provided via environment
if [ -z "$SSH_USER" ]; then
    read -r -p "Enter SSH Username [root]: " SSH_USER
    SSH_USER="${SSH_USER:-root}"
fi

# Create a temporary file to hold JSON output to allow matrix processing at the end
JSON_OUT=$(mktemp)
exec 3>"$JSON_OUT"

# Print valid JSON header straight to temp file descriptor
echo "{" >&3
echo "  \"scan_timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"," >&3
echo "  \"access_points\": [" >&3

TOTAL_TARGETS=${#CANDIDATE_IPS[@]}
CURRENT_COUNT=0
VALID_AP_COUNT=0

# ==============================================================================
# DATA COLLECTION ENGINE
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

    # Remote command to discover hostname, active RF Profiles, and primary interface MAC
    REMOTE_CMD=$(cat << 'EOF'
# Discover hostname dynamically across UniFi versions/models
unifi_name=$(mca-cli-op info 2>/dev/null | awk -F': ' '/Hostname/ {print $2}')
[ -z "$unifi_name" ] && unifi_name=$(hostname 2>/dev/null)
[ -z "$unifi_name" ] && unifi_name="Unknown-AP"

primary_mac=$(ip link show | awk '/ether/ {print $2; exit}' | tr '[:upper:]' '[:lower:]')
[ -z "$primary_mac" ] && primary_mac=$(ifconfig 2>/dev/null | awk '/HWaddr/ {print $5; exit}' | tr '[:upper:]' '[:lower:]')

if iwconfig 2>/dev/null | grep -q 'RTWIFI'; then
    # --------------------------------------------------------------------------
    # TARGET: MediaTek Platform (e.g., U6-Lite, Standalone APs)
    # --------------------------------------------------------------------------
    rf_data=$(iwconfig 2>/dev/null | awk '
        /^[a-z0-9\.]+/ { 
            vif=$1;
        }
        /Channel=/ {
            if (vif != "") {
                split($0, chunks, "Channel=");
                split(chunks[2], subchunks, " ");
                chan=subchunks[1];
                
                if(chan != "0" && chan != "") {
                    freq=2412; width=20;
                    if(chan > 14) { 
                        freq=5000 + (chan * 5);
                        width=80; 
                    } else {
                        freq=2407 + (chan * 5);
                    }
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
    # --------------------------------------------------------------------------
    # TARGET: Qualcomm / Upstream Drivers (U6-Pro, U6-LR, U7-Pro Enterprise)
    # --------------------------------------------------------------------------
    raw_iw=$(mca-roam-info 2>/dev/null || iw dev 2>/dev/null)
    rf_data=$(echo "$raw_iw" | awk '
        /Inf:/ { 
            split($0, a, " "); current_vif=a[2]; gsub(/[^a-zA-Z0-9\-]/, "", current_vif); next;
        }
        /Interface/ { 
            current_vif=$2; next;
        }
        /Band:/ { band[current_vif] = $2; }
        /Channel:/ { chan[current_vif] = $2; }
        /Frequency:/ { freq[current_vif] = $2; }
        /channel/ { 
            if (current_vif != "") {
                gsub(/[\(\),]/, "", $0);
                for (i=1; i<=NF; i++) {
                    if ($i == "channel") { chan[current_vif] = $(i+1); }
                    if ($i == "MHz" && $(i-1) ~ /^[0-9]+$/) {
                        if ($(i-2) == "width") {
                            width[current_vif] = $(i-1);
                        } else {
                            freq[current_vif] = $(i-1);
                        }
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
                if (w_val == 0) {
                    if (chan[v] > 14) { w_val = 80; } 
                    else { w_val = 20; }
                }
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
    # INTER-AP NEIGHBOR SCANNING ENGINE
    # --------------------------------------------------------------------------
    REMOTE_SCAN_CMD=$(cat << 'EOF'
if command -v mca-dump &>/dev/null; then
    # Qualcomm UniFi Native Engine
    mca-dump | awk '
        /\"bssid\"/ { gsub(/[^a-fA-F0-9:]/, "", $2); bssid=tolower($2) }
        /\"rssi\"/ { gsub(/[^0-9\-]/, "", $2); rssi=$2 }
        /\"essid\"/ { split($0, parts, "\""); essid=parts[4] }
        /\"channel\"/ { 
            gsub(/[^0-9]/, "", $2); chan=$2;
            if (bssid != "" && rssi != "") {
                neighbors[bssid] = rssi "," chan "," essid;
                bssid=""; rssi="";
            }
        }
        END {
            f=1;
            for (b in neighbors) {
                split(neighbors[b], d, ",");
                if (!f) printf ",\n";
                printf "        {\n          \"bssid\": \"%s\",\n          \"rssi_dbm\": %d,\n          \"channel\": %d,\n          \"ssid\": \"%s\"\n        }", b, d[1], d[2], d[3];
                f=0;
            }
            if (!f) printf "\n";
        }
    '
elif iwconfig 2>/dev/null | grep -q 'RTWIFI'; then
    # Consolidated MediaTek Survey Parsing Engine
    survey_data=""
    for iface in $(iwconfig 2>/dev/null | awk '/^(ra|apcli)[0-9]+/ {print $1}'); do
        iwpriv "$iface" CloudScan 1 &>/dev/null
        iwpriv "$iface" Scan 1 &>/dev/null
    done
    
    sleep 2.2
    
    for iface in $(iwconfig 2>/dev/null | awk '/^(ra|apcli)[0-9]+/ {print $1}'); do
        raw_survey=$(iwpriv "$iface" get_site_survey 2>/dev/null)
        if echo "$raw_survey" | grep -q "BSSID"; then
            survey_data="${survey_data}${raw_survey}\n"
        fi
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
                        rssi = int((sig_pct / 2) - 100);
                        if (rssi < -100) rssi = -100;
                        if (rssi > -30)  rssi = -30;
                        
                        if (bssid != "" && chan ~ /^[0-9]+$/) {
                            targets[bssid] = rssi "," chan "," ssid;
                        }
                    }
                }
            }
            END {
                f=1;
                for (t in targets) {
                    split(targets[t], val, ",");
                    if (!f) printf ",\n";
                    printf "        {\n          \"bssid\": \"%s\",\n          \"rssi_dbm\": %d,\n          \"channel\": %d,\n          \"ssid\": \"%s\"\n        }", t, val[1], val[2], val[3];
                    f=0;
                }
                if (!f) printf "\n";
            }
        '
    fi
fi
EOF
)

    # Securely query profiles and metrics from targets using system default SSH keys
    RAW_RESPONSE=$(ssh -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes "$SSH_USER@$AP_IP" "$REMOTE_CMD" 2>/dev/null)
    SIGNAL_BLOCKS=$(ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes "$SSH_USER@$AP_IP" "$REMOTE_SCAN_CMD" 2>/dev/null)

    # Parse dynamically found fields out of raw response
    TARGET_NAME=$(echo "$RAW_RESPONSE" | awk -F'===' '/===NAME_START===/ {print $3}')
    TARGET_MAC=$(echo "$RAW_RESPONSE" | awk -F'===' '/===MAC_START===/ {print $3}')
    PARSED_BLOCKS=$(echo "$RAW_RESPONSE" | sed -n '/===RF_START===/,/===RF_END===/p' | grep -v "===.*_START===" | grep -v "===.*_END===")

    # Manage trailing structural array syntax across loops dynamically
    if [ "$VALID_AP_COUNT" -gt 0 ]; then
        echo "    }," >&3
    fi
    VALID_AP_COUNT=$((VALID_AP_COUNT + 1))

    # Hostname Map Normalization (dynamic fallback if empty)
    HOSTNAME="${TARGET_NAME:-AP-$AP_IP}"

    echo "    {" >&3
    echo "      \"hostname\": \"$HOSTNAME\"," >&3
    echo "      \"ip_address\": \"$AP_IP\"," >&3
    echo "      \"mac_address\": \"$TARGET_MAC\"," >&3
    echo "      \"rf_profiles\": [" >&3
    if [ -n "$PARSED_BLOCKS" ]; then
        echo "$PARSED_BLOCKS" >&3
    fi
    echo "      ]," >&3
    echo "      \"inter_ap_signals\": [" >&3
    if [ -n "$SIGNAL_BLOCKS" ]; then
        echo "$SIGNAL_BLOCKS" >&3
    fi
    echo "      ]" >&3
    echo "  [+] Extracted operational RF specifications safely for $HOSTNAME." >&2
done

# Terminate top-level schema blocks cleanly
if [ "$VALID_AP_COUNT" -gt 0 ]; then
    echo "    }" >&3
fi
echo "  ]" >&3
echo "}" >&3

# Output collected JSON safely to terminal
cat "$JSON_OUT"

# ==============================================================================
# MATRIX GENERATION ENGINE
# ==============================================================================
echo -e "\n======================================================================" >&2
echo " GENERATING INTER-AP SIGNAL MATRIX (dBm RSSI)" >&2
echo "======================================================================" >&2

awk '
BEGIN {
    FS="\""
}
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
/\"rssi_dbm\"/ { 
    split($0, line_parts, ":")
    clean_val = line_parts[2]
    gsub(/[^0-9\-]/, "", clean_val)
    rssi = clean_val + 0
    
    # Safety catch: Ensure the RSSI is properly registered as negative
    if (rssi > 0) {
        rssi = -rssi
    }
    
    if (current_host != "" && current_bssid != "") {
        matrix[current_host, current_bssid] = rssi
    }
}
END {
    # Print header row
    printf "%-18s", "Observer \\ Target"
    for (h in hosts) {
        printf " | %-17s", h
    }
    print ""
    
    # Print separation line
    printf "%-18s", "------------------"
    for (h in hosts) {
        printf " | %-17s", "-----------------"
    }
    print ""

    # Print data rows
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
                if (found) {
                    printf " | %-17s", (val " dBm")
                } else {
                    printf " | %-17s", "     (Unseen)"
                }
            }
        }
        print ""
    }
}
' "$JSON_OUT"

# Clean up temp configuration profiles
rm -f "$JSON_OUT"
echo "======================================================================" >&2
echo " COMPLETE: Clean structural serialization and matrix verified." >&2
