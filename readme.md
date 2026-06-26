# UniFi AP Telemetry and Key Deployment Tools

This repository contains a pair of standalone Bash scripts designed to audit UniFi Access Point environments and bootstrap public key authentication. They are designed to be entirely environment-agnostic, handling diverse UniFi hardware ecosystems (Qualcomm and MediaTek platforms) without hardcoded configurations.

---

## Prerequisites

Both scripts require the following packages installed on your local control machine:

**jq**: Used to safely read and extract data from the incoming JSON IP arrays.

**sshpass**: Required by the key deployment tool to pass initial password authorizations to remote targets.

To install dependencies on Debian/Ubuntu systems:
```bash
sudo apt-get update && sudo apt-get install jq sshpass -y
```

---

## 1. SSH Public Key Deployment Script (`deploy_keys.sh`)

This script streamlines the process of push-injecting a local computer\'s public SSH identity onto a collection of target Access Points. It replaces explicit manually targeted pathways with standard automated fallback configurations.

### Features
**Automatic Identity Discovery**: Scans local standard configurations (`id_ed25519.pub`, `id_rsa.pub`, or `id_ecdsa.pub`) and selects the first available credential.

**Idempotent Appending**: Analyzes pre-existing entries on targets to cleanly bypass redundant credential insertions.

**Prompting Over Hardcoding**: Requests target environment SSH usernames dynamically at run-time if the environment variable is absent.

### Usage
Run the script by passing a valid JSON string containing an array of your destination IP addresses:

```bash
./deploy_keys.sh '["192.168.1.29", "192.168.1.127", "192.168.1.79"]'
```

---

## 2. RF Telemetry & Signal Matrix Parser (\`get_telemetry.sh\`)

This utility framework interrogates target Access Points to build a structured visual landscape of your wireless infrastructure. It translates hardware-level scans into machine-readable structures and cross-referenced visual matrices.

### Features
**Cross-Platform Adaptation**: Dynamically identifies the system framework on-the-fly to execute matching data extractions for both Qualcomm/Upstream drivers (`mca-roam-info` / `iw`) and MediaTek platforms (`iwpriv` / `iwconfig`).

**Dynamic Hostname Alignment**: Queries active device indicators directly via internal UniFi operational stacks (`mca-cli-op`), eliminating manual network mapping.

**BSSID Neighbor Localization**: Forces cross-channel sweeps to build complex spatial relationship representations between peer endpoints.

### Usage
Execute the telemetry sweep by delivering your hardware catalog targets as a structural JSON text argument:

```bash
./get_telemetry.sh '["192.168.1.29", "192.168.1.127", "192.168.1.79"]'
```

### Execution Output Frameworks

#### Raw Serialization Block (Standard Output)
The script builds a standard JSON data schema detailing spatial and functional states:

```json
{
  "scan_timestamp": "2026-06-25T21:23:44Z",
  "access_points": [
    {
      "hostname": "Main-Hall-AP",
      "ip_address": "192.168.1.29",
      "mac_address": "e0:63:da:aa:bb:cc",
      "rf_profiles": [
        {
          "interface": "rai0",
          "channel": 36,
          "frequency_mhz": 5180,
          "width_mhz": 80
        }
      ],
      "inter_ap_signals": [
        {
          "bssid": "e0:63:da:dd:ee:ff",
          "rssi_dbm": -62,
          "channel": 149,
          "ssid": "Secure_Corporate_WiFi"
        }
      ]
    }
  ]
}
```

#### Spatial Interaction Grid (Standard Error Output)
Simultaneously, a structured grid outputs directly onto standard error for instantaneous network visualization:

```text
Observer \  Target | Main-Hall-AP      | Office-AP         | Patio-U7          
------------------ | ----------------- | ----------------- | -----------------
Main-Hall-AP       |      [Self]       | -68 dBm           | -75 dBm           
Office-AP          | -65 dBm           |      [Self]       |      (Unseen)     
Patio-U7           | -78 dBm           |      (Unseen)     |      [Self]       
```

---

## Global Environmental Overrides

You can suppress interactive user-prompts within automated system flows or continuous pipeline environments by pre-declaring standard environmental markers before calling execution steps:

```bash
export SSH_USER="admin_operator"
./get_telemetry.sh '["192.168.1.5"]'
```
