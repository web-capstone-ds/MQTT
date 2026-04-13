# MQTT Broker 작업명세서
## DS 비전 검사 장비 모바일 모니터링 프로젝트

> **레포지토리**: `web-capstone-ds / MQTT`  
> **작성일**: 2026-04-13  
> **작업 범위**: Eclipse Mosquitto 2.x Broker 설정 전체 (B1)  
> **상태**: ✅ 완료

---

## 1. 개요

망 분리된 공장 로컬 Wi-Fi 환경에서 N대의 비전 검사 장비(EAP), MES 서버, 모바일 앱, Historian, Oracle 서버가 단일 Broker를 통해 통신하는 MQTT Pub/Sub 인프라를 구성한다.

### 핵심 설계 원칙

- **ACL 기반 권한 격리**: 클라이언트별 최소 권한 원칙 적용
- **Retained Message 정책**: 모바일 앱 신규 구독 시 마지막 상태 즉시 복원
- **Will Message**: EAP 비정상 종료 시 Broker가 자동 발행
- **Persistence**: 재시작 후 Retained 메시지 보존

---

## 2. 산출물 목록

| 파일 | 설명 |
| :--- | :--- |
| `broker/mosquitto.conf` | Mosquitto 메인 설정 파일 |
| `broker/acl` | 토픽 접근 제어 (5개 계정) |
| `broker/passwd` | 계정 비밀번호 파일 (htpasswd 형식) |
| `broker/init_passwd.sh` | `.env` 기반 초기 계정 생성 스크립트 |
| `broker/docker-compose.yml` | 로컬 개발용 컨테이너 실행 설정 |
| `broker/.env.example` | 비밀번호 환경변수 예시 파일 |

---

## 3. mosquitto.conf 설정 명세

| 항목 | 설정값 | 근거 |
| :--- | :--- | :--- |
| 포트 | `1883` | 망 분리 로컬 환경 |
| 익명 접속 | `allow_anonymous false` | ACL 인증 의무화 |
| 비밀번호 파일 | `/etc/mosquitto/passwd` | 명세서 §부록 A.1 |
| ACL 파일 | `/etc/mosquitto/acl` | 명세서 §부록 A.2 |
| Persistence | `true` / `/var/lib/mosquitto/` | 재시작 후 Retained 보존 |
| max_packet_size | `65535` bytes | INSPECTION_RESULT 2.1KB 여유 |
| 로그 레벨 | `error warning notice information` | 운영 수준 |
| log_dest | `stdout` | 컨테이너 환경 표준 출력 |

> `keepalive_interval`은 Mosquitto 2.x에 존재하지 않는 지시어이므로 포함하지 않는다.

---

## 4. ACL 계정 권한 명세

명세서 §부록 A.2~A.3 기준.

| 계정 | Publish 허용 토픽 | Subscribe 허용 토픽 | 비고 |
| :--- | :--- | :--- | :--- |
| `eap_vis_001` | `ds/DS-VIS-001/#` | `ds/DS-VIS-001/control` | 장비 #1 전용 |
| `eap_vis_002` | `ds/DS-VIS-002/#` | `ds/DS-VIS-002/control` | 장비 #2 전용 |
| `eap_vis_003` | `ds/DS-VIS-003/#` | `ds/DS-VIS-003/control` | 장비 #3 전용 |
| `eap_vis_004` | `ds/DS-VIS-004/#` | `ds/DS-VIS-004/control` | 장비 #4 전용 |
| `mes_server` | `ds/#` | `ds/#` | 전체 접근 |
| `oracle_server` | `ds/+/oracle` | `ds/+/lot` `ds/+/result` | 분석 서버 |
| `mobile_app` | `ds/+/control` | `ds/#` | EMERGENCY_STOP · STATUS_QUERY · ALARM_ACK 한정 |
| `historian` | 없음 | `ds/#` | 읽기 전용 |

> `mobile_app`은 `ds/+/alarm`에 **쓰기 불가** — ACL에 명시적 미허용으로 차단

---

## 5. 토픽 구조 및 Retained 정책

명세서 §1.1 기준.

| 토픽 패턴 | 이벤트 타입 | QoS | Retained | 방향 |
| :--- | :--- | :--- | :--- | :--- |
| `ds/{eq}/heartbeat` | HEARTBEAT | 1 | ❌ | EAP → Broker |
| `ds/{eq}/status` | STATUS_UPDATE | 1 | ✅ | EAP → Broker |
| `ds/{eq}/result` | INSPECTION_RESULT | 1 | ❌ | EAP → Broker |
| `ds/{eq}/lot` | LOT_END | 2 | ✅ | EAP → Broker |
| `ds/{eq}/alarm` | HW_ALARM | 2 | ✅ | EAP → Broker |
| `ds/{eq}/recipe` | RECIPE_CHANGED | 2 | ✅ | EAP → Broker |
| `ds/{eq}/control` | CONTROL_CMD | 2 | ❌ | Broker → EAP |
| `ds/{eq}/oracle` | ORACLE_ANALYSIS | 2 | ✅ | Oracle → Broker |

---

## 6. Will Message 명세

명세서 §부록 A.4 기준.

| 항목 | 값 |
| :--- | :--- |
| Will Topic | `ds/{equipment_id}/status` |
| Will QoS | 1 (AtLeastOnce) |
| WillRetain | `true` (신규 구독자도 즉시 STOP 인지) |
| Will Payload 필드 | `equipment_id`, `event_type: EAP_DISCONNECTED`, `timestamp` |

---

## 7. 초기 실행 절차

```bash
# 1. 비밀번호 파일 생성
cp broker/.env.example broker/.env
# .env 파일 열어 비밀번호 변경

# 2. passwd 파일 초기화 (로컬에서 직접)
cd broker
sh init_passwd.sh

# 3. 컨테이너 기동
docker-compose up -d

# 4. 익명 접속 거부 확인
mosquitto_pub -h localhost -t "test" -m "hello"
# → Connection Refused 정상

# 5. 인증 접속 확인
mosquitto_pub -h localhost -u mes_server -P <pw> -t "ds/DS-VIS-001/status" -m "test"
# → 성공
```

---

## 8. 검증 체크리스트

| 항목 | 결과 |
| :--- | :--- |
| `allow_anonymous false` 설정 | ✅ PASS |
| 8개 계정 ACL 정의 (4대 EAP 포함) | ✅ PASS |
| `mobile_app` → `ds/+/alarm` 쓰기 차단 | ✅ PASS |
| `persistence true` + `persistence_location` | ✅ PASS |
| `max_packet_size 65535` | ✅ PASS |
| 로그 4종 설정 | ✅ PASS |
| docker-compose 볼륨 마운트 4종 | ✅ PASS |
| init_passwd.sh `.env` 기반 8개 계정 생성 | ✅ PASS |
| `.env.example` 제공 | ✅ PASS |
| `keepalive_interval` 제거 (유효하지 않은 지시어) | ✅ PASS |

---

## 9. 다음 단계 연동 대상

| 컴포넌트 | 연동 방식 | 계정 |
| :--- | :--- | :--- |
| MES 서버 (EAP_VM 레포) | `mes_server` 계정으로 접속 | `mes_server` |
| 가상 EAP Publisher (추후) | 장비별 `eap_vis_{id}` 계정 | `eap_vis_001~004` |
| 모바일 앱 (추후) | `ds/+/control` 발행, `ds/#` 구독 | `mobile_app` |
| Historian 서버 (추후) | `ds/#` 읽기 전용 구독 | `historian` |
| Oracle 서버 (추후) | LOT/Result 구독, oracle 발행 | `oracle_server` |
