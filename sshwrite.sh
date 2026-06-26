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

# Automatically determine the system's default public key
LOCAL_PUB_KEY=""
for key_type in id_ed25519.pub id_rsa.pub id_ecdsa.pub; do
    if [ -f "$HOME/.ssh/$key_type" ]; then
        LOCAL_PUB_KEY="$HOME/.ssh/$key_type"
        break
    fi
done

if [ -z "$LOCAL_PUB_KEY" ]; then
    echo "[CRITICAL ERROR] No standard local public key found (e.g., id_ed25519.pub or id_rsa.pub)." >&2
    exit 1
fi

# Prompt for SSH user if not already provided via environment
if [ -z "$SSH_USER" ]; then
    read -r -p "Enter SSH Username [root]: " SSH_USER
    SSH_USER="${SSH_USER:-root}"
fi

# ==============================================================================
# SECURITY & PRE-FLIGHT VALIDATION
# ==============================================================================
printf "Enter SSH Password for %s to authorize SCP transfer: " "$SSH_USER"
read -rs PLAIN_PASS
echo ""

if [ -z "$PLAIN_PASS" ]; then
    echo "[CRITICAL ERROR] Password cannot be blank." >&2
    exit 1
fi

if ! command -v sshpass &>/dev/null; then
    echo "[*] 'sshpass' utility missing locally. Please install 'sshpass' first." >&2
    exit 1
fi

export SSHPASS="$PLAIN_PASS"

# ==============================================================================
# LOCAL DIRECT KEY INJECTION LOOP (SCP METHOD)
# ==============================================================================
TOTAL_TARGETS=${#CANDIDATE_IPS[@]}
CURRENT_COUNT=0
PUB_KEY_FILENAME=$(basename "$LOCAL_PUB_KEY")

for AP_IP in "${CANDIDATE_IPS[@]}"; do
    CURRENT_COUNT=$((CURRENT_COUNT + 1))

    echo "======================================================================" >&2
    echo " PROGRESS: [$CURRENT_COUNT/$TOTAL_TARGETS] Deploying Key ($PUB_KEY_FILENAME) via SCP to Node: $AP_IP" >&2
    echo "======================================================================" >&2

    if ! nc -w 2 -z "$AP_IP" 22 2>/dev/null; then
        echo "  [-] Node $AP_IP dropped network handshake. Skipping deployment..." >&2
        continue
    fi

    # 1. Ensure the destination configuration folder path framework exists securely on the AP
    sshpass -e ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$AP_IP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null
    
    # 2. Stage the public key file directly up to a temporary storage file on the target via SCP
    if sshpass -e scp -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$LOCAL_PUB_KEY" "$SSH_USER@$AP_IP:/tmp/$PUB_KEY_FILENAME" &>/dev/null; then
        
        # 3. Append the staged key safely to authorized_keys cleanly avoiding duplicate insertions
        EXEC_PAYLOAD="touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && if ! grep -qFff /tmp/$PUB_KEY_FILENAME ~/.ssh/authorized_keys; then cat /tmp/$PUB_KEY_FILENAME >> ~/.ssh/authorized_keys && echo 'KEY_INJECTED_SUCCESSFULLY'; else echo 'KEY_ALREADY_EXISTS'; fi; rm -f /tmp/$PUB_KEY_FILENAME"
        RESPONSE=$(sshpass -e ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_USER@$AP_IP" "$EXEC_PAYLOAD" 2>/dev/null)

        if [ "$RESPONSE" = "KEY_INJECTED_SUCCESSFULLY" ]; then
            echo "  [+] Key authorization sequence completed successfully on $AP_IP." >&2
        elif [ "$RESPONSE" = "KEY_ALREADY_EXISTS" ]; then
            echo "  [*] Key signature already matches an active entry on $AP_IP. Skipping duplication..." >&2
        else
            echo "  [-] Target configuration script execution error occurred on node $AP_IP." >&2
        fi
    else
        echo "  [-] Secure copy data transfer via SCP failed on target node $AP_IP." >&2
    fi
done

echo "======================================================================" >&2
echo " COMPLETE: Direct SCP SSH Key Authorization sweep finalized." >&2
