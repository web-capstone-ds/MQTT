# GEMINI.md — DS 비전 검사 장비 모바일 모니터링 프로젝트
# 작업 범위: MES 서버 (C# / .NET 8 / MQTTnet v4) + Eclipse Mosquitto Broker 구성

> **작성자**: 수석 아키텍트  
> **수신자**: Gemini CLI  
> **버전**: v1.1 (2026-04-13)  
> **작업 성격**: 코드 + 설정 파일 작성 (문서 수정 없음)

---

## 0. 프로젝트 컨텍스트

### 0.1 너의 역할
너는 15년 차 경력의 제조 IT(MES/스마트 팩토리) 도메인 전문 프로젝트 매니저(PM)이자 수석 아키텍트입니다.  
디에스(DS) 주식회사와의 2개월 단기 협업 프로젝트에서 **MES 서버와 MQTT Broker 구성 코드**를 작성한다.

### 0.2 프로젝트 본질

- 망 분리된 반도체 후공정 공장 현장에서 **N대의 비전 검사 장비(EAP)** 상태를 모바일로 모니터링하는 Edge 기반 N:1 관제 시스템
- 통신: **MQTT (Eclipse Mosquitto 2.x) over Local Wi-Fi** — 외부 인터넷 없음
- 최우선 가치: **데이터 병목 없는 파이프라인** + **현장 엔지니어 즉시성**

### 0.3 이번 작업 범위 (Scope)

| 구성 요소 | 언어 / 플랫폼 | 핵심 역할 |
| :--- | :--- | :--- |
| **MQTT Broker** | Eclipse Mosquitto 2.x | 메시지 라우팅 중재자. ACL / Will / Retained / QoS 차등 |
| **MES 서버** | C# / .NET 8 / MQTTnet v4 | N대 가상 EAP 일괄 제어. LOT 시작·종료. Recipe 변경. EMERGENCY_STOP |

> **범위 외**: 가상 EAP Publisher (C#), Historian (Node.js/TypeScript), Oracle (Python), 모바일 앱 (.NET MAUI)

### 0.4 진실의 원천 (Source of Truth)

모든 코드는 아래 두 문서를 기준으로 작성한다. 이 문서와 충돌하는 코드는 작성하지 않는다.

| 문서 | 경로 | 용도 |
| :--- | :--- | :--- |
| DS_EAP_MQTT_API_명세서 v3.4 | `명세서/DS_EAP_MQTT_API_명세서.md` | 토픽 구조 / QoS / Retained / ACL / 페이로드 필드 전체 |
| DS_이벤트정의서 | `명세서/DS_이벤트정의서.md` | Rule R01~R38c 판정 기준 |

### 0.5 저장소 구조

```
.
├── GEMINI.md
├── broker/                            ← B1 작업 산출물
│   ├── mosquitto.conf
│   ├── acl
│   ├── passwd (초기값)
│   ├── init_passwd.sh
│   └── docker-compose.yml
├── mes-server/                        ← M1~M5 작업 산출물
│   ├── MesServer.csproj
│   ├── appsettings.json
│   ├── Program.cs
│   ├── Infrastructure/
│   │   └── MqttClientService.cs
│   ├── Services/
│   │   ├── LotControlService.cs
│   │   ├── RecipeControlService.cs
│   │   └── EquipmentMonitorService.cs
│   ├── Models/
│   │   ├── ControlCommand.cs
│   │   ├── EquipmentStatus.cs
│   │   ├── LotEnd.cs
│   │   └── HwAlarm.cs
│   └── Scenarios/
│       └── ScenarioLoader.cs
├── EAP_mock_data/                     ← 읽기 전용 (파싱 기준)
│   ├── 01_heartbeat.json ~ 27_control_alarm_ack_burst.json
│   └── scenarios/multi_equipment_4x.json
└── 명세서/                             ← 읽기 전용 (구현 기준)
    ├── DS_EAP_MQTT_API_명세서.md
    └── DS_이벤트정의서.md
```

### 0.6 작업 시작 전 필독 문서

아래 순서대로 읽고 컨텍스트를 적재한 뒤 코드를 작성한다.

1. `명세서/DS_EAP_MQTT_API_명세서.md` — §1.1 토픽 표, §6.6 ACK 시퀀스, §부록 A.3~A.7 전체
2. `명세서/DS_이벤트정의서.md` — Rule R01, R23, R25, R26, R33, R34 판정 기준
3. `EAP_mock_data/scenarios/multi_equipment_4x.json` — N=4 시나리오 구조

---

## 1. 작업 원칙 (공통)

### 1.1 절대 금지

- ❌ **QoS 다운그레이드 금지** — `LOT_END` / `HW_ALARM` / `RECIPE_CHANGED` / `CONTROL_CMD` / `ORACLE_ANALYSIS` 는 반드시 QoS 2
- ❌ **CONTROL_CMD Retain 금지** — 명령은 1회성. `WithRetainFlag(false)` 강제
- ❌ **`ds/+/alarm` 에 mobile_app 쓰기 권한 부여 금지** — ACL §부록 A.3 엄수
- ❌ **장비 ID 하드코딩 금지** — `appsettings.json` 으로 외부화
- ❌ **예외 처리 없는 MQTT 연결 코드 금지** — 재연결 백오프 없는 코드는 납품 불가

### 1.2 필수 준수

- ✅ **MQTTnet v4** (`MQTTnet` NuGet 4.x) 기준으로만 작성 — v3 API 혼용 금지
- ✅ **Retained 토픽 5종**(`/status` · `/lot` · `/alarm` · `/recipe` · `/oracle`) 발행 시 `WithRetainFlag(true)` 필수
- ✅ **Will 메시지** `WillRetain = true` 설정 — 명세서 §부록 A.4
- ✅ **재연결 백오프**: `1s → 2s → 5s → 15s → 30s`, max 60s, jitter ±20% — 명세서 §부록 A.6
- ✅ **페이로드 직렬화**: `System.Text.Json` 사용. `Newtonsoft.Json` 사용 금지
- ✅ **UTC ISO 8601 밀리초**: `timestamp` 필드는 반드시 `yyyy-MM-ddTHH:mm:ss.fffZ` 포맷
- ✅ **`CancellationToken` 전파**: 모든 비동기 메서드에 전파. `CancellationToken.None` 하드코딩 금지
- ✅ **구조적 로깅**: `ILogger<T>` + `Serilog` 기반

### 1.3 답변 출력 형식

- 표와 불릿 포인트 우선 — 산문 나열 금지
- 코드 제공 시 반드시 포함해야 하는 항목:
  - 네트워크 단절 대응
  - MQTT 지수 백오프 재연결 (수치 명시: `1s→2s→5s→15s→30s, max 60s, jitter ±20%`)
  - `CancellationToken` 전파
  - `System.Text.Json` 직렬화
- 모호한 요청은 추측으로 진행하지 않고 **명세서 해당 절을 인용**하여 먼저 확인

---

## 2. Task B1 — Eclipse Mosquitto Broker 설정

### 2.1 배경

망 분리 로컬 Wi-Fi 현장에서 N대 EAP, MES 서버, 모바일 앱, Historian, Oracle이 단일 Broker를 통해 통신한다. ACL로 클라이언트 권한을 격리하고, Will + Retained 정책으로 모바일 앱의 즉시성을 보장한다.

### 2.2 산출물

```
broker/
├── mosquitto.conf
├── acl
├── passwd
├── init_passwd.sh
└── docker-compose.yml
```

### 2.3 `broker/mosquitto.conf` 요구사항

| 항목 | 설정 값 | 근거 |
| :--- | :--- | :--- |
| 포트 | 1883 | 망 분리 로컬 환경 |
| 익명 접속 | `allow_anonymous false` | ACL 인증 의무 |
| 비밀번호 파일 | `/etc/mosquitto/passwd` | §부록 A.1 |
| ACL 파일 | `/etc/mosquitto/acl` | §부록 A.2 |
| Persistence | `true` / `/var/lib/mosquitto/` | 재시작 후 Retained 메시지 보존 |
| max_packet_size | `65535` | INSPECTION_RESULT 2.1KB 여유 |
| keepalive | `60` | EAP 기준 §부록 A.6 |
| log_type | `error warning notice information` | 운영 수준 |

### 2.4 `broker/acl` 요구사항

명세서 §부록 A.2~A.3 그대로 반영한다.

| 계정 | Publish 허용 토픽 | Subscribe 허용 토픽 | 비고 |
| :--- | :--- | :--- | :--- |
| `eap_vis_{id}` | `ds/{id}/#` | `ds/{id}/control` | 장비별 개별 계정 |
| `mes_server` | `ds/#` | `ds/#` | 전체 접근 |
| `oracle_server` | `ds/+/oracle` | `ds/+/lot` `ds/+/result` | 분석 서버 |
| `mobile_app` | `ds/+/control` | `ds/#` | EMERGENCY_STOP · STATUS_QUERY · ALARM_ACK 한정 |
| `historian` | 없음 | `ds/#` | 읽기 전용 |

> `mobile_app` 은 `ds/+/alarm` 에 **절대 쓰기 불가** — ACL에 명시적 차단 필수

### 2.5 `broker/init_passwd.sh` 요구사항

- 비밀번호를 `.env` 파일 또는 환경변수에서 읽어 `mosquitto_passwd` 로 생성
- 초기 5개 계정 자동 생성: `eap_vis_001` / `mes_server` / `oracle_server` / `mobile_app` / `historian`

### 2.6 `broker/docker-compose.yml` 요구사항

- `eclipse-mosquitto:2` 이미지 사용
- 볼륨 마운트: `mosquitto.conf` / `passwd` / `acl` / persistence 디렉터리

### 2.7 검증 체크리스트

- [ ] `allow_anonymous false` 설정 확인
- [ ] 5개 계정 ACL 정의됨
- [ ] `mobile_app` → `ds/+/alarm` Publish 불가 ACL 차단 확인
- [ ] `persistence true` + `persistence_location` 설정 확인
- [ ] `docker-compose up` 후 익명 `mosquitto_pub` 거부 확인

### 2.8 Git 커밋 메시지

```
feat(broker): Eclipse Mosquitto 설정 초기 구성 (B1)

- mosquitto.conf: 포트·인증·Persistence·로그
- acl: 5개 계정 토픽 접근 제어 (mobile_app alarm 쓰기 차단)
- init_passwd.sh: .env 기반 초기 계정 생성 스크립트
- docker-compose.yml: 로컬 개발용 컨테이너 실행

명세서 §부록 A.1~A.4 Retained·Will 정책 반영.
```

---

## 3. Task M1 — MES 서버 프로젝트 구조 초기화

### 3.1 배경

C# 콘솔 앱(.NET 8 / Generic Host)으로 구성한다. `EAP_mock_data/scenarios/multi_equipment_4x.json` 의 시나리오를 읽어 각 장비에 MQTT 명령을 라우팅한다.

### 3.2 `mes-server/appsettings.json` 구조

```json
{
  "Mqtt": {
    "Host": "localhost",
    "Port": 1883,
    "Username": "mes_server",
    "Password": "CHANGE_ME",
    "ClientId": "mes-server-001",
    "KeepAliveSec": 60,
    "ReconnectBackoffSec": [1, 2, 5, 15, 30, 60]
  },
  "Equipments": [
    { "Id": "DS-VIS-001", "DisplayName": "비전 #1", "Site": "Carsem-A" },
    { "Id": "DS-VIS-002", "DisplayName": "비전 #2", "Site": "Carsem-A" },
    { "Id": "DS-VIS-003", "DisplayName": "비전 #3", "Site": "Carsem-A" },
    { "Id": "DS-VIS-004", "DisplayName": "비전 #4", "Site": "Carsem-A" }
  ],
  "ScenarioPath": "../EAP_mock_data/scenarios/multi_equipment_4x.json"
}
```

### 3.3 NuGet 의존성

| 패키지 | 버전 | 용도 |
| :--- | :--- | :--- |
| `MQTTnet` | 4.x | MQTT 클라이언트 |
| `Microsoft.Extensions.Hosting` | 8.x | Generic Host / DI |
| `Serilog.Extensions.Hosting` | 최신 | 구조적 로깅 |
| `Serilog.Sinks.Console` | 최신 | 콘솔 출력 |

### 3.4 검증 체크리스트

- [ ] .NET 8 Target Framework 확인
- [ ] `appsettings.json` 장비 목록·브로커 정보 외부화
- [ ] `Program.cs` DI 등록: `MqttClientService` / `LotControlService` / `EquipmentMonitorService` / `ScenarioLoader`
- [ ] `MQTTnet` v4 패키지 참조 확인 (v3 혼용 금지)

### 3.5 Git 커밋 메시지

```
feat(mes): MES 서버 프로젝트 구조 초기화 (M1)

- .NET 8 Generic Host 기반 콘솔 앱
- appsettings.json: Mqtt·Equipments·ScenarioPath 외부화
- NuGet: MQTTnet v4, Serilog
- DI 서비스 등록 스켈레톤
```

---

## 4. Task M2 — MqttClientService (재연결 백오프 + Retained 발행)

### 4.1 배경

망 분리 Wi-Fi 환경에서 연결이 수시로 끊긴다. 지수 백오프 없이 즉시 재연결하면 Broker 과부하가 발생한다. 명세서 §부록 A.6의 수치를 코드로 정확히 구현해야 한다.

### 4.2 인터페이스

```csharp
public interface IMqttClientService
{
    Task PublishAsync<T>(
        string topic, T payload,
        MqttQualityOfServiceLevel qos,
        bool retain,
        CancellationToken ct);

    Task SubscribeAsync(
        string topicFilter,
        Func<MqttApplicationMessage, Task> handler,
        CancellationToken ct);

    Task StartAsync(CancellationToken ct);
    Task StopAsync(CancellationToken ct);
}
```

### 4.3 재연결 백오프 — 구현 요구사항

명세서 §부록 A.6 수치를 그대로 사용한다.

```csharp
// 이 배열 값은 변경 불가 — 명세서 §부록 A.6 확정값
private static readonly int[] BackoffSeconds = [1, 2, 5, 15, 30, 60];

private static TimeSpan GetBackoffDelay(int attempt)
{
    var baseSec = BackoffSeconds[Math.Min(attempt, BackoffSeconds.Length - 1)];
    var jitter   = baseSec * (0.8 + Random.Shared.NextDouble() * 0.4); // ±20%
    return TimeSpan.FromSeconds(jitter);
}
```

### 4.4 Retained 토픽 정책 — 구현 요구사항

명세서 §1.1 Retained 정책을 코드로 강제한다. 호출자가 잘못된 값을 넘겨도 이 메서드가 최종 방어선이다.

```csharp
// 명세서 §1.1 기준 — heartbeat·result·control 은 retain 금지
private static bool MustRetain(string topic) =>
    topic.EndsWith("/status")  ||
    topic.EndsWith("/lot")     ||
    topic.EndsWith("/alarm")   ||
    topic.EndsWith("/recipe")  ||
    topic.EndsWith("/oracle");

private static bool MustNotRetain(string topic) =>
    topic.EndsWith("/heartbeat") ||
    topic.EndsWith("/result")    ||
    topic.EndsWith("/control");
```

> `MustNotRetain()` 해당 토픽에 `retain: true` 가 넘어오면 `InvalidOperationException` throw — 명세서 위반을 런타임에 즉시 차단

### 4.5 인바운드 메시지 큐

```csharp
// Backpressure 방지 — capacity 초과 시 oldest drop
private readonly Channel<(string Topic, string Payload)> _inboundChannel =
    Channel.CreateBounded<(string, string)>(
        new BoundedChannelOptions(capacity: 1000)
        {
            FullMode = BoundedChannelFullMode.DropOldest
        });
```

### 4.6 Will 메시지 등록

```csharp
// 명세서 §부록 A.4 — WillRetain = true 필수
options.WillTopic   = $"ds/{_clientId}/status";
options.WillRetain  = true;  // ← 반드시 true
options.WillQos     = MqttQualityOfServiceLevel.AtLeastOnce;
options.WillPayload = JsonSerializer.SerializeToUtf8Bytes(new MesDisconnectedPayload());
```

### 4.7 검증 체크리스트

- [ ] `BackoffSeconds` = `[1, 2, 5, 15, 30, 60]` 일치 확인
- [ ] jitter 계산 `Random.Shared` 사용 (스레드 안전)
- [ ] `MustNotRetain()` 위반 시 `InvalidOperationException` throw 확인
- [ ] `Channel.CreateBounded` capacity=1000, `DropOldest` 설정
- [ ] `WillRetain = true` 확인
- [ ] `CancellationToken` 재연결 루프 + 발행 모두 전파

### 4.8 Git 커밋 메시지

```
feat(mes): MqttClientService — 재연결 백오프 + Retained 정책 강제 (M2)

- 백오프: 1s→2s→5s→15s→30s max 60s, jitter ±20% (§부록 A.6)
- MustRetain() / MustNotRetain(): §1.1 토픽 정책 런타임 강제
- Channel<T> capacity=1000 DropOldest (backpressure)
- WillRetain=true (§부록 A.4)
- CancellationToken 전 경로 전파
```

---

## 5. Task M3 — LotControlService (LOT·알람 제어 명령 발행)

### 5.1 배경

MES는 오퍼레이터 또는 스케줄에 따라 N대 장비에 CONTROL_CMD를 발행한다. 명세서 §8의 페이로드 구조를 정확히 따른다.

### 5.2 발행 규격

```
토픽:   ds/{equipment_id}/control
QoS:    2
Retain: false  ← 명령은 1회성. 절대 Retain 금지
```

`CONTROL_CMD` 페이로드 모델 (`Models/ControlCommand.cs`):

```csharp
public record ControlCommand
{
    [JsonPropertyName("message_id")]      public string  MessageId     { get; init; } = Guid.NewGuid().ToString();
    [JsonPropertyName("event_type")]      public string  EventType     { get; init; } = "CONTROL_CMD";
    [JsonPropertyName("timestamp")]       public string  Timestamp     { get; init; } = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
    [JsonPropertyName("command")]         public string  Command       { get; init; } = "";
    [JsonPropertyName("issued_by")]       public string  IssuedBy      { get; init; } = "MES_SERVER";
    [JsonPropertyName("reason")]          public string? Reason        { get; init; }
    [JsonPropertyName("target_lot_id")]   public string? TargetLotId   { get; init; }
    [JsonPropertyName("target_burst_id")] public string? TargetBurstId { get; init; }
}
```

### 5.3 지원 명령 코드

| 명령 코드 | MES 발행 | 설명 |
| :--- | :--- | :--- |
| `EMERGENCY_STOP` | ✅ | 즉시 장비 정지. LOT 강제 중단 |
| `LOT_ABORT` | ✅ | 현재 LOT 강제 종료. LOT_END 유발 |
| `RECIPE_LOAD` | ✅ | 지정 Recipe 로드 |
| `ALARM_CLEAR` | ✅ | 알람 해제 및 복구 시도 |
| `STATUS_QUERY` | ✅ | 즉시 STATUS_UPDATE 발행 요청 |
| `ALARM_ACK` | ✅ | 알람 확인. `target_burst_id` 로 그룹 ACK 가능 (§6.6.2) |

### 5.4 LOT_END 수신 처리

- 구독 토픽: `ds/+/lot` (QoS 2)
- `yield_pct` 판정 — 명세서 §5.2 Rule R23:

```csharp
private static string ClassifyYield(float yieldPct) => yieldPct switch
{
    >= 98 => "EXCELLENT",
    >= 95 => "NORMAL",
    >= 90 => "WARNING",
    >= 80 => "MARGINAL",
    _     => "CRITICAL"   // → LogCritical + 콘솔 빨간 출력
};
```

### 5.5 LOT Start/End 불균형 감지 (Rule R25)

```csharp
// 차이 ≥ 5 시 CRITICAL (R25)
private readonly ConcurrentDictionary<string, int> _startCount = new();
private readonly ConcurrentDictionary<string, int> _endCount   = new();

private void CheckImbalance(string equipmentId)
{
    var diff = _startCount.GetValueOrDefault(equipmentId)
             - _endCount.GetValueOrDefault(equipmentId);
    if (diff >= 5)
        _logger.LogCritical("R25 CRITICAL: {EqId} LOT Start/End 불균형 {Diff}건",
                             equipmentId, diff);
}
```

### 5.6 검증 체크리스트

- [ ] `CONTROL_CMD` 발행 시 `retain: false` 강제 (`MustNotRetain` 통과)
- [ ] `message_id` = `Guid.NewGuid().ToString()` UUID v4
- [ ] `timestamp` = UTC `.fffZ` 포맷
- [ ] `ALARM_ACK` 발행 시 `target_burst_id` nullable 처리
- [ ] `yield_pct < 80` → `LogCritical` + 콘솔 빨간 출력
- [ ] Start/End 차이 ≥ 5 → `LogCritical` (R25)

### 5.7 Git 커밋 메시지

```
feat(mes): LotControlService — LOT 제어 명령 + 수신 처리 (M3)

- CONTROL_CMD 6종 발행 (EMERGENCY_STOP / LOT_ABORT / ALARM_ACK 등)
- ALARM_ACK target_burst_id 그룹 ACK 지원 (§6.6.2)
- LOT_END 수신: yield 5단계 판정, R23 CRITICAL 경보
- R25: Start/End 불균형 ≥5 CRITICAL 로그
- Retain=false 강제 (CONTROL_CMD 1회성 명령)
```

---

## 6. Task M4 — EquipmentMonitorService (장비 상태 집계 + Rule 실시간 감지)

### 6.1 구독 토픽

| 토픽 | QoS | 용도 |
| :--- | :--- | :--- |
| `ds/+/heartbeat` | 1 | ONLINE/OFFLINE 감지 (R01) |
| `ds/+/status` | 1 | 장비 상태·진행률 수신 |
| `ds/+/alarm` | 2 | HW_ALARM 수신 |
| `ds/+/lot` | 2 | LOT_END 공유 (LotControlService 와 동일 구독) |

### 6.2 Heartbeat ONLINE/OFFLINE 판정 (Rule R01)

```csharp
private readonly ConcurrentDictionary<string, DateTime> _lastHeartbeat = new();

private EquipmentOnlineStatus GetOnlineStatus(string equipmentId)
{
    if (!_lastHeartbeat.TryGetValue(equipmentId, out var last))
        return EquipmentOnlineStatus.Unknown;

    return (DateTime.UtcNow - last).TotalSeconds switch
    {
        <= 9  => EquipmentOnlineStatus.Online,   // R01 정상
        <= 30 => EquipmentOnlineStatus.Warning,  // R01 WARNING
        _     => EquipmentOnlineStatus.Offline   // R01 CRITICAL
    };
}
```

### 6.3 HW_ALARM 처리 규칙

| `alarm_level` | 출력 | 로그 레벨 |
| :--- | :--- | :--- |
| `CRITICAL` | 콘솔 빨간 텍스트 (`ConsoleColor.Red`) | `LogCritical` |
| `WARNING` | 콘솔 노란 텍스트 (`ConsoleColor.Yellow`) | `LogWarning` |

- `requires_manual_intervention = true` → 알람 미확인 목록에 등록 (`ConcurrentDictionary`)
- `hw_error_code = EAP_DISCONNECTED` → Will 수신. Heartbeat 타이머 무시하고 즉시 STOP 처리 (명세서 §부록 A.5)

### 6.4 STATUS_UPDATE 진행률 콘솔 출력

명세서 §3.1 v3.4 진행률 3필드(`current_unit_count` / `expected_total_units` / `current_yield_pct`) 파싱 후 출력.

```
[DS-VIS-001] RUN  | Carsem_3X3 | 1,247 / 2,792 (44.7%) | 수율 95.8%
[DS-VIS-002] RUN  | Carsem_4X6 |   850 / ?     ( ?.?%) | 수율 68.5% ⚠ WARNING
[DS-VIS-003] IDLE | Carsem_3X3 | LOT 완료 (2,792 units)
[DS-VIS-004] STOP | CRITICAL 알람 미확인 ●
```

### 6.5 일별 Rule 카운터 체크

| Rule | 파라미터 | CRITICAL 기준 | 카운터 리셋 |
| :--- | :--- | :--- | :--- |
| R26 | `CAM_TIMEOUT_ERR` / 일 | > 3건 | 자정 UTC |
| R33 | `AggregateException` 알람 / 일 | > 5건 | 자정 UTC |
| R34 | `EAP_DISCONNECTED` / 주 | > 2건 | 월요일 자정 |

### 6.6 검증 체크리스트

- [ ] Heartbeat 판정: 9s Warning / 30s Offline (R01)
- [ ] `ConcurrentDictionary` 사용 — 스레드 안전 확인
- [ ] `EAP_DISCONNECTED` 수신 시 Heartbeat 타이머 무시 즉시 STOP 처리
- [ ] `requires_manual_intervention = true` 알람 미확인 목록 관리
- [ ] 진행률 3필드 null 안전 파싱 (`expected_total_units` null 가능)
- [ ] R26/R33 일별 카운터 자정 리셋 로직

### 6.7 Git 커밋 메시지

```
feat(mes): EquipmentMonitorService — 상태 집계 + Rule 실시간 감지 (M4)

- Heartbeat ONLINE/WARNING/OFFLINE (R01: 9s/30s)
- HW_ALARM CRITICAL/WARNING 콘솔 색상 분기
- EAP_DISCONNECTED Will 수신 즉시 STOP (§부록 A.5)
- STATUS_UPDATE 진행률 3필드 콘솔 출력 (§3.1 v3.4)
- R26/R33/R34 일별·주별 카운터 자정 리셋
```

---

## 7. Task M5 — ScenarioLoader + 통합 시나리오 실행

### 7.1 배경

`EAP_mock_data/scenarios/multi_equipment_4x.json` 을 읽어 4대 장비에 해당하는 Mock 이벤트를 병렬로 Broker에 발행한다. `equipment_id` 를 동적으로 치환하여 각 장비 토픽으로 라우팅한다.

### 7.2 이벤트 타입 → 토픽/QoS/Retain 라우팅 테이블

명세서 §1.1과 완전히 일치해야 한다.

```csharp
private static (string Suffix, MqttQualityOfServiceLevel Qos, bool Retain)
    GetTopicMeta(string eventType) => eventType switch
{
    "HEARTBEAT"         => ("heartbeat", QoS1,  Retain: false),
    "STATUS_UPDATE"     => ("status",    QoS1,  Retain: true),
    "INSPECTION_RESULT" => ("result",    QoS1,  Retain: false),
    "LOT_END"           => ("lot",       QoS2,  Retain: true),
    "HW_ALARM"          => ("alarm",     QoS2,  Retain: true),
    "RECIPE_CHANGED"    => ("recipe",    QoS2,  Retain: true),
    "CONTROL_CMD"       => ("control",   QoS2,  Retain: false),
    "ORACLE_ANALYSIS"   => ("oracle",    QoS2,  Retain: true),
    _ => throw new ArgumentException($"Unknown event_type: {eventType}")
};
```

### 7.3 시나리오 실행 흐름

```
1. ScenarioLoader → multi_equipment_4x.json 파싱
2. 시작 시 mock_sequence 파일 전체 존재 여부 사전 검증
3. 4대 장비 Task.WhenAll 병렬 실행
4. 각 장비: mock_sequence 순서대로 JSON 파일 읽기
   → equipment_id 동적 치환 (페이로드 내부 포함)
   → GetTopicMeta()로 토픽·QoS·Retain 결정
   → MqttClientService.PublishAsync() 호출
5. 개별 장비 예외가 다른 장비 실행을 중단시키지 않도록 격리
6. 완료 후 총 발행 건수·소요 시간 로그 출력
```

### 7.4 검증 체크리스트

- [ ] 시작 시 `mock_sequence` 파일 사전 검증 (파일 미존재 시 즉시 오류)
- [ ] `equipment_id` 치환이 페이로드 JSON 내부(`"equipment_id"` 필드)에도 적용됨
- [ ] 라우팅 테이블이 명세서 §1.1 표와 QoS + Retain 쌍 완전 일치
- [ ] `Task.WhenAll` 에서 개별 장비 예외 격리 (`try/catch` per task)
- [ ] 완료 로그: `총 N건 발행, 소요 Xs` 형식

### 7.5 Git 커밋 메시지

```
feat(mes): ScenarioLoader — N=4 다설비 통합 시나리오 실행 (M5)

- multi_equipment_4x.json 파싱 + mock_sequence 사전 검증
- equipment_id 동적 치환 (payload 내부 포함)
- GetTopicMeta(): §1.1 토픽/QoS/Retain 라우팅 테이블
- Task.WhenAll 병렬 실행, 개별 장비 예외 격리
```

---

## 8. Task 실행 순서

| 순서 | Task | 제목 | 우선순위 | 의존성 |
| :--- | :--- | :--- | :--- | :--- |
| 1 | B1 | Mosquitto Broker 설정 | P0 | 없음 |
| 2 | M1 | MES 프로젝트 구조 초기화 | P0 | B1 (연결 테스트) |
| 3 | M2 | MqttClientService 백오프 | P0 | M1 |
| 4 | M3 | LotControlService | P1 | M2 |
| 5 | M4 | EquipmentMonitorService | P1 | M2 |
| 6 | M5 | ScenarioLoader 통합 실행 | P1 | M3, M4 |

---

## 9. 통합 검증 (전 Task 완료 후)

### 9.1 검증 시퀀스

```bash
# 1. Broker 기동
cd broker && docker-compose up -d

# 2. 익명 접속 거부 확인
mosquitto_pub -h localhost -t "test" -m "hello"
# → Connection Refused 기대

# 3. MES 서버 기동
cd mes-server && dotnet run

# 4. 모바일 역할 구독 (별도 터미널)
mosquitto_sub -h localhost -u mobile_app -P <pw> \
  -t "ds/+/status" -t "ds/+/alarm" -t "ds/+/lot" -t "ds/+/recipe" -v

# 5. 시나리오 실행 → 메시지 흐름 확인
```

### 9.2 교차 참조 체크리스트

| 체크 항목 | 기준 | 확인 위치 |
| :--- | :--- | :--- |
| Retained 토픽 5종 정확 | 명세서 §1.1 | `MqttClientService.MustRetain()` |
| CONTROL_CMD Retain=false | 명세서 §8 | `LotControlService` |
| 백오프 수열 `[1,2,5,15,30,60]` | 명세서 §부록 A.6 | `MqttClientService.BackoffSeconds` |
| ACL mobile_app alarm 쓰기 차단 | 명세서 §부록 A.3 | `broker/acl` |
| WillRetain=true | 명세서 §부록 A.4 | `MqttClientService` 연결 옵션 |
| QoS 라우팅 테이블 §1.1 일치 | 명세서 §1.1 | `ScenarioLoader.GetTopicMeta()` |
| timestamp UTC .fffZ 포맷 | 명세서 §1.2 | `ControlCommand` 모델 |

### 9.3 최종 보고 형식

```
## MES + Broker 구현 완료 보고

### 변경 통계
- 신규 파일: N개
- 추가 라인: +X

### Task 완료 현황
- [x] B1 Mosquitto Broker 설정 (P0)
- [x] M1 MES 프로젝트 구조 (P0)
- [x] M2 MqttClientService 백오프 (P0)
- [x] M3 LotControlService (P1)
- [x] M4 EquipmentMonitorService (P1)
- [x] M5 ScenarioLoader 통합 실행 (P1)

### 검증 결과
- Broker 익명 거부: PASS
- 재연결 백오프 수열: PASS
- 4대 시나리오 발행 + Retained 확인: PASS
- ACL 권한 격리: PASS
- 교차 참조 체크리스트: N/N

### 다음 단계 권고
1. 가상 EAP Publisher (C#) — Mock 발행 + Will 등록
2. .NET MAUI 모바일 Subscriber — §부록 A.7 세션 정책
3. Historian Node.js/TypeScript — ds/+/# 구독 + TimescaleDB 적재
```

---

## 10. 주의사항

### 10.1 자주 하는 실수

| 실수 | 방지책 |
| :--- | :--- |
| `AtLeastOnce` vs `ExactlyOnce` 혼용 | 라우팅 테이블 단일 관리 |
| `ConfigureAwait(false)` 누락 | 라이브러리 코드 전체 적용 |
| `CancellationToken.None` 하드코딩 | `stoppingToken` 파라미터 전파 |
| `DateTime.Now` 사용 | 반드시 `DateTime.UtcNow` 사용 |
| JSON 직렬화 UTC 미지정 | `JsonSerializerOptions` 커스텀 컨버터 등록 |
| MQTTnet v3 API 혼용 | v4 API 레퍼런스 먼저 확인 |

### 10.2 막혔을 때

- **페이로드 구조 불명확** → `EAP_mock_data/` 해당 번호 파일 직접 참조
- **QoS / Retain 불명확** → `명세서/DS_EAP_MQTT_API_명세서.md` §1.1 토픽 표가 최종 기준
- **재연결 수치 불명확** → §부록 A.6 수치가 확정값. 임의 변경 금지
- **두 가지 해석 가능** → **데이터 병목 방지** + **현장 엔지니어 즉시성** 두 원칙에 더 부합하는 쪽 선택
- **명세서에 없는 내용** → 추측으로 진행하지 않고 사용자에게 확인 요청

---

**End of GEMINI.md**
