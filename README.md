# Renesas RZ + optiga-tpm2 use with Microsoft Azure Iot hub

## The security chain:

```bash
TPM Chip (hardware)
    └── Private key at 0x81000001 < ONLY exists here
            └── Signs TLS handshake
                    └── Azure verifies signature matches registered cert
                            └── Connection allowed
```

The private key cannot be extracted, exported, or stolen even with full root access to the device. It is stored at a persistent handle "0x81000001"
If at any poit the tpm board will be disconnected connections to Azure automatically wont work.

---

SETUP:

Yocto build requires meta-tpm2 layer with recipes:
```
tpm2-tss-engine tpm2-tss tpm2-totp tpm2-tools tpm2-pytss tpm2-pkcs11 tpm2-openssl tpm2-abrmd packagegroup-tpm2-initramfs packagegroup-tpm2
```

openembedded-core layer:
```
openssl
```

As well as meta-networking for mqtt:
```
mosquitto
```

## Step 1: Create TPM2 Primary Key
```bash
tpm2_createprimary -C o -c primary.ctx
```

## Step 2: Create TPM2 Child Key
```bash
tpm2_create -C primary.ctx -G rsa -u key.pub -r key.priv
```

## Step 3: Load and Persist the Key

### Load key into TPM
```bash
tpm2_load -C primary.ctx -u key.pub -r key.priv -c key.ctx
```
### Verify
```bash
tpm2_getcap handles-persistent
```
### Should show: 0x81000001 if not make it persistent
```bash
tpm2_evictcontrol -C o -c key.ctx 0x81000001
```

## Step 4: Generate Certificate
```bash
OPENSSL_MODULES=/usr/lib/ossl-modules openssl req -x509 \
  -provider tpm2 -provider default \
  -key "handle:0x81000001" \
  -subj "/CN=my-device-001" \
  -days 365 \
  -out /root/device.crt
```

## Step 5: Get Certificate Thumbprint
```bash
openssl x509 -in /root/device.crt -noout -fingerprint -sha1 \
  | sed 's/.*=//' | tr -d ':'
```
### Example output: 133E693916CD55ECB3F19F2D10E8C0FE600B92A4


Step 6: Download Azure CA Certificate
```bash
wget https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem
```

## Step 7: Register Device in Azure Portal

1. Go to IoT Hub > Devices > Add Device
2. Device ID: my-device-001 / same as -subj "/CN=my-device-001" \
3. Authentication type: X.509 Self-Signed
4. Primary thumbprint and Secondary thumbprint: paste fingerprint from Step 5
5. Click Save


## Step 8: Prepare MQTT Packets
```bash
python3 << 'EOF'
import struct

def encode_str(s):
    b = s.encode()
    return struct.pack('>H', len(b)) + b

def remaining_length(n):
    out = []
    while True:
        b = n % 128
        n //= 128
        if n > 0: b |= 0x80
        out.append(b)
        if n == 0: break
    return bytes(out)

HUB      = "ArnasTestHub.azure-devices.net"  # change to your hub
DEVICE   = "my-device-001"                   # change to your device ID
USER     = "%s/%s/?api-version=2021-04-12" % (HUB, DEVICE)
TOPIC    = "devices/%s/messages/events/" % DEVICE
MESSAGE  = b'{"temperature": 25.3}'          # change to your payload

payload = encode_str("MQTT") + bytes([4, 0x82]) + struct.pack('>H', 60)
payload += encode_str(DEVICE) + encode_str(USER)
connect_pkt = bytes([0x10]) + remaining_length(len(payload)) + payload

pub_payload = encode_str(TOPIC) + MESSAGE
publish_pkt = bytes([0x30]) + remaining_length(len(pub_payload)) + pub_payload
disconnect_pkt = bytes([0xE0, 0x00])

with open('/tmp/mqtt_connect.bin', 'wb') as f:
    f.write(connect_pkt)
with open('/tmp/mqtt_publish.bin', 'wb') as f:
    f.write(publish_pkt)
with open('/tmp/mqtt_disconnect.bin', 'wb') as f:
    f.write(disconnect_pkt)

print("Packets ready. Topic: %s" % TOPIC)
print("Message: %s" % MESSAGE.decode())
EOF
```

## Step 9: Send MQTT Message via TPM2
```bash
OPENSSL_MODULES=/usr/lib/ossl-modules openssl s_client \
  -connect ArnasTestHub.azure-devices.net:8883 \
  -provider tpm2 -provider default \
  -cert /root/device.crt \
  -key "handle:0x81000001" \
  -CAfile /root/DigiCertGlobalRootG2.crt.pem \
  -quiet -ign_eof \
  2>/dev/null \
  < <(cat /tmp/mqtt_connect.bin && sleep 2 \
      && cat /tmp/mqtt_publish.bin && sleep 3 \
      && cat /tmp/mqtt_disconnect.bin && sleep 2) \
  | python3 -c "
import sys
data = sys.stdin.buffer.read(4)
if len(data) >= 4 and data[0] == 0x20 and data[3] == 0:
    print('SUCCESS - message sent!')
else:
    print('FAILED: %s' % data.hex() if data else 'no response')
"
```
---

To verify if azure is getting the messages
In azure shell:
```bash
az extension add --name azure-iot
```
```bash
az iot hub monitor-events \
  --hub-name ArnasTestHub \
  --device-id my-device-001 \
  --timeout 30
```
