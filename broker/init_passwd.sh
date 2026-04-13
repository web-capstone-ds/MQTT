#!/bin/sh
# init_passwd.sh (B1)
# .env 파일 또는 환경변수에서 비밀번호를 읽어 5개 계정 생성

set -e

PASS_FILE="/etc/mosquitto/passwd"

# .env 파일 로드 (로컬 실행 시)
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# MQTT_PASS_* 환경변수 유효성 검사 (생략 가능하나 권장)
if [ -z "$MQTT_PASS_MES_SERVER" ]; then
  echo "Error: MQTT_PASS_MES_SERVER is not set."
  exit 1
fi

# 첫 번째 계정 생성 (-c: create new file)
mosquitto_passwd -c -b "$PASS_FILE" eap_vis_001 "$MQTT_PASS_EAP_VIS_001"

# 나머지 계정 추가 (-b: batch mode)
mosquitto_passwd -b "$PASS_FILE" eap_vis_002 "$MQTT_PASS_EAP_VIS_002"
mosquitto_passwd -b "$PASS_FILE" eap_vis_003 "$MQTT_PASS_EAP_VIS_003"
mosquitto_passwd -b "$PASS_FILE" eap_vis_004 "$MQTT_PASS_EAP_VIS_004"
mosquitto_passwd -b "$PASS_FILE" mes_server "$MQTT_PASS_MES_SERVER"
mosquitto_passwd -b "$PASS_FILE" oracle_server "$MQTT_PASS_ORACLE_SERVER"
mosquitto_passwd -b "$PASS_FILE" mobile_app "$MQTT_PASS_MOBILE_APP"
mosquitto_passwd -b "$PASS_FILE" historian "$MQTT_PASS_HISTORIAN"

echo "MQTT passwords initialized for: eap_vis_001, mes_server, oracle_server, mobile_app, historian"
