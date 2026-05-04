#!/bin/sh

#inputs
printf "Device ID: "
read DEVICE

printf "Hub hostname [ArnasTestHub.azure-devices.net]: "
read HUB
HUB=${HUB:-ArnasTestHub.azure-devices.net}

printf "Certificate path [/root/device.crt]: "
read CERT
CERT=${CERT:-/root/device.crt}

printf "Number of messages to send [1]: "
read COUNT
COUNT=${COUNT:-1}

printf "Message payload [{'temperature': 25.0}]: "
read PAYLOAD
PAYLOAD=${PAYLOAD:-{'temperature': 25.0}}

echo ""
echo "Sending $COUNT message(s) as device '$DEVICE' to '$HUB'..."
echo ""

i=1
while [ $i -le $COUNT ]; do
  #build MQTT packets
  MSG=$(echo "$PAYLOAD" | sed "s/{i}/$i/g")

  python3 -c "
import struct, sys

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

HUB    = sys.argv[1]
DEVICE = sys.argv[2]
MSG    = sys.argv[3].encode()
USER   = '%s/%s/?api-version=2021-04-12' % (HUB, DEVICE)
TOPIC  = 'devices/%s/messages/events/' % DEVICE

payload = encode_str('MQTT') + bytes([4, 0x82]) + struct.pack('>H', 60)
payload += encode_str(DEVICE) + encode_str(USER)
connect_pkt = bytes([0x10]) + remaining_length(len(payload)) + payload
pub_payload = encode_str(TOPIC) + MSG
publish_pkt = bytes([0x30]) + remaining_length(len(pub_payload)) + pub_payload
disconnect_pkt = bytes([0xE0, 0x00])

open('/tmp/mqtt_connect.bin','wb').write(connect_pkt)
open('/tmp/mqtt_publish.bin','wb').write(publish_pkt)
open('/tmp/mqtt_disconnect.bin','wb').write(disconnect_pkt)
" "$HUB" "$DEVICE" "$MSG"

  printf "  Message $i/$COUNT: "
  OPENSSL_MODULES=/usr/lib/ossl-modules openssl s_client \
    -connect ${HUB}:8883 \
    -provider tpm2 -provider default \
    -cert "$CERT" \
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
    print('SUCCESS')
else:
    print('FAILED - %s' % (data.hex() if data else 'no response'))
"
  i=$((i + 1))
  [ $i -le $COUNT ] && sleep 1
done

echo ""
echo "Done."
