# Tomcat AJP Thread Pool Monitor

JMX Exporter를 이용하여 Tomcat의 **AJP Connector Thread Pool 상태**를 모니터링하고,
Thread Pool 사용률에 따라 INFO / WARN / CRITICAL 로그를 기록하는 간단한 모니터링 스크립트입니다.

## 구성

```text
.
├── README.md
├── config.env (선택, git에는 포함되지 않음)
├── config.yaml
├── jmx_prometheus_javaagent-1.6.0.jar
└── thread_mon.sh
```

### 파일 설명

| 파일                                   | 설명                                 |
| ------------------------------------ | ---------------------------------- |
| `jmx_prometheus_javaagent-1.6.0.jar` | Prometheus JMX Exporter Java Agent |
| `config.yaml`                        | JMX Exporter 설정 파일                 |
| `thread_mon.sh`                      | Tomcat AJP Thread Pool 모니터링 스크립트   |
| `config.env`                         | Teams 알림 웹훅 등 민감한 설정 (git에 커밋되지 않음) |
| `README.md`                          | 설치 및 사용 방법                         |

---

# 1. 사전 요구사항

다음 환경이 필요합니다.

* Linux
* Java 8 이상
* Tomcat / HyperFrame 등 JMX를 제공하는 Java WAS
* `curl`
* `awk`
* `grep`
* `cron` 또는 `crond`

JMX Exporter는 Java Agent 방식으로 WAS에 연결합니다.

---

# 2. Repository 다운로드

모니터링을 적용할 서버에서 GitHub Repository를 clone합니다.

```bash
git clone <REPOSITORY_URL>
cd <REPOSITORY_NAME>
```

예:

```bash
git clone https://github.com/example/tomcat-thread-monitor.git
cd tomcat-thread-monitor
```

스크립트 실행 권한을 확인합니다.

```bash
chmod +x thread_mon.sh
```

---

# 3. JMX Exporter 설정

Repository에 포함된 `config.yaml`을 확인합니다.

```bash
cat config.yaml
```

`whitelistObjectNames`로 Tomcat AJP Thread Pool MBean(`Catalina:type=ThreadPool,*`)만
조회하도록 범위를 좁혀두었습니다. `thread_mon.sh`는 1분마다 `/metrics`를 스크래핑하므로,
모든 MBean을 대상으로 하면(`whitelistObjectNames` 미설정) 스크래핑마다 JVM의 모든 MBean을
읽게 되어 불필요한 부하가 생깁니다. 출력되는 metric 이름(`catalina_threadpool_*`)은
기존과 동일하므로 `thread_mon.sh` 수정은 필요 없습니다.

> `config.yaml`은 WAS 기동 시 Java Agent 옵션으로 로드되므로, 파일을 수정한 뒤에는
> WAS(Tomcat)를 재기동해야 반영됩니다.

JMX Exporter는 Java Agent로 실행되며 Prometheus metrics를 HTTP로 제공합니다.

기본적으로 다음 포트를 사용합니다.

```text
9404
```

JMX Exporter가 정상적으로 실행되면 다음 URL에서 metrics를 확인할 수 있습니다.

```text
http://localhost:9404/metrics
```

---

# 4. JMX Exporter 실행

## 4.1 Java Agent 방식

WAS 실행 옵션에 다음 Java Agent 옵션을 추가합니다.

```bash
-javaagent:/path/to/jmx_prometheus_javaagent-1.6.0.jar=9404:/path/to/config.yaml
```

예:

```bash
java \
-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar=9404:/opt/jmx-exporter/config.yaml \
-jar application.jar
```

Tomcat을 사용하는 경우 `CATALINA_OPTS` 또는 `JAVA_OPTS`에 추가할 수 있습니다.

```bash
export CATALINA_OPTS="$CATALINA_OPTS -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar=9404:/opt/jmx-exporter/config.yaml"
```

이후 Tomcat을 재기동합니다.

> 이미 실행 중인 WAS에 Java Agent를 추가하려면 WAS 재기동이 필요합니다.

---

# 5. JMX Exporter 정상 동작 확인

JMX Exporter가 정상적으로 실행됐는지 확인합니다.

```bash
curl -s http://localhost:9404/metrics
```

Tomcat Thread Pool metric이 출력되는지 확인합니다.

```bash
curl -s http://localhost:9404/metrics | grep 'catalina_threadpool_'
```

AJP Connector metric만 확인하려면:

```bash
curl -s http://localhost:9404/metrics | grep 'catalina_threadpool_' | grep 'ajp-'
```

예:

```text
catalina_threadpool_currentthreadcount{name="\"ajp-apr-192.0.2.10-8209\""} 100.0
catalina_threadpool_currentthreadsbusy{name="\"ajp-apr-192.0.2.10-8209\""} 0.0
catalina_threadpool_maxthreads{name="\"ajp-apr-192.0.2.10-8209\""} 200.0
catalina_threadpool_connectioncount{name="\"ajp-apr-192.0.2.10-8209\""} 1.0
```

`thread_mon.sh`는 AJP Connector 이름이나 IP를 직접 지정하지 않습니다.

metrics 중 `ajp-` Connector를 자동으로 검색합니다.

---

# 6. thread_mon.sh 설정

스크립트 상단의 설정을 확인합니다.

```bash
METRIC_URL="http://localhost:9404/metrics"

LOG_DIR="/var/log/threadpool"

WARN_THRESHOLD=80
CRIT_THRESHOLD=90
```

## METRIC_URL

JMX Exporter metrics 주소입니다.

기본값:

```bash
METRIC_URL="http://localhost:9404/metrics"
```

JMX Exporter를 다른 포트로 실행하는 경우 수정합니다.

예:

```bash
METRIC_URL="http://localhost:9500/metrics"
```

## LOG_DIR

모니터링 로그가 저장될 디렉토리입니다.

예:

```bash
LOG_DIR="/var/log/threadpool"
```

운영 환경에 맞게 변경합니다.

## Threshold

Thread Pool 사용률 기준입니다.

```bash
WARN_THRESHOLD=80
CRIT_THRESHOLD=90
```

현재 설정은 다음과 같습니다.

|      사용률 | 상태       |
| -------: | -------- |
|  0 ~ 79% | INFO     |
| 80 ~ 89% | WARN     |
|   90% 이상 | CRITICAL |

사용률은 다음과 같이 계산합니다.

```text
currentThreadsBusy / maxThreads × 100
```

예:

```text
currentThreadsBusy = 180
maxThreads = 200

180 / 200 × 100 = 90%
```

---

# 7. thread_mon.sh 수동 테스트

Crontab 등록 전에 수동으로 실행합니다.

```bash
./thread_mon.sh
```

정상 실행되면 설정한 로그 디렉토리에 로그가 생성됩니다.

예:

```bash
ls -l /var/log/threadpool/
```

INFO 로그:

```text
threadpool_20260916.log
```

WARN 로그:

```text
threadpool_warn_20260916.log
```

CRITICAL 로그:

```text
threadpool_critical_20260916.log
```

INFO 로그 확인:

```bash
cat /var/log/threadpool/threadpool_$(date +%Y%m%d).log
```

예:

```text
2026-09-16 16:00:01 AJP=ajp-apr-192.0.2.10-8209 BUSY=0/200(0%) CURRENT=100 CONNECTION=1
```

---

# 8. Crontab 등록

Thread Pool 상태를 **1분마다 확인**하려면 crontab에 등록합니다.

Crontab 편집:

```bash
crontab -e
```

다음 내용을 추가합니다.

```cron
* * * * * /path/to/thread_mon.sh
```

예:

```cron
* * * * * /opt/tomcat-thread-monitor/thread_mon.sh
```

스크립트의 실행 결과를 별도의 cron 로그에 남기고 싶다면:

```cron
* * * * * /opt/tomcat-thread-monitor/thread_mon.sh >> /opt/tomcat-thread-monitor/cron.log 2>&1
```

단, `thread_mon.sh` 자체가 별도의 로그 파일을 생성하므로 cron 로그는 별도로 남기지 않아도 됩니다.

추천:

```cron
* * * * * /opt/tomcat-thread-monitor/thread_mon.sh
```

---

# 9. Crontab 등록 확인

```bash
crontab -l
```

예:

```text
* * * * * /opt/tomcat-thread-monitor/thread_mon.sh
```

cron 서비스가 실행 중인지 확인합니다.

Rocky Linux / RHEL 계열:

```bash
systemctl status crond
```

실행 중이 아니라면:

```bash
systemctl start crond
```

부팅 후 자동 시작:

```bash
systemctl enable crond
```

---

# 10. 모니터링 항목

`thread_mon.sh`는 JMX Exporter에서 다음 AJP Thread Pool metric을 조회합니다.

### Current Threads Busy

```text
catalina_threadpool_currentthreadsbusy
```

현재 실제로 작업을 처리하고 있는 Thread 수입니다.

### Current Thread Count

```text
catalina_threadpool_currentthreadcount
```

현재 생성되어 있는 Thread 수입니다.

### Max Threads

```text
catalina_threadpool_maxthreads
```

Thread Pool에서 사용할 수 있는 최대 Thread 수입니다.

### Connection Count

```text
catalina_threadpool_connectioncount
```

현재 Connector에 연결된 Connection 수입니다.

---

# 11. Thread Pool 사용률

모니터링 기준은 `currentThreadCount`가 아니라 **`currentThreadsBusy`**입니다.

```text
사용률 = currentThreadsBusy / maxThreads × 100
```

예를 들어:

```text
currentThreadsBusy = 50
currentThreadCount = 100
maxThreads = 200
```

Thread Pool 사용률:

```text
50 / 200 × 100 = 25%
```

따라서 현재 생성된 Thread가 100개라고 해서 사용률이 50%인 것은 아닙니다.

---

# 12. 로그 상태

## INFO

항상 현재 상태를 기록합니다.

```text
2026-09-16 16:00:01 AJP=ajp-apr-192.0.2.10-8209 BUSY=20/200(10%) CURRENT=100 CONNECTION=1
```

## WARN

Thread Pool 사용률이 `WARN_THRESHOLD` 이상인 경우 기록합니다.

기본값:

```text
80%
```

예:

```text
[WARN] 2026-09-16 16:10:01 AJP=ajp-apr-192.0.2.10-8209 BUSY=165/200(82%) CURRENT=200 CONNECTION=10 CPU=35.2% MEM=61.4% LOAD= 1.20, 1.10, 0.95
```

## CRITICAL

Thread Pool 사용률이 `CRIT_THRESHOLD` 이상인 경우 기록합니다.

기본값:

```text
90%
```

예:

```text
[CRITICAL] 2026-09-16 16:15:01 AJP=ajp-apr-192.0.2.10-8209 BUSY=185/200(92%) CURRENT=200 CONNECTION=15 CPU=72.3% MEM=78.1% LOAD= 3.20, 2.90, 2.50
```

WARN / CRITICAL 상태에서는 서버의 CPU, Memory, Load Average도 함께 기록합니다.

---

# 13. Teams 멘션 알림

`WARN` 또는 `CRITICAL` 상태가 발생하면 `thread_mon.sh`가 Power Automate 웹훅을 통해
Teams로 Adaptive Card 알림을 전송하며, 지정한 담당자를 `@멘션`합니다.

## 13.1 config.env 설정

스크립트와 같은 디렉토리에 `config.env` 파일을 생성합니다. (git에는 포함되지 않습니다.)

```bash
WEBHOOK_URL="https://.../triggers/manual/paths/invoke?..."
TEAMS_MENTION_ID="사용자의 Teams(AAD) Object ID"
TEAMS_MENTION_NAME="화면에 표시될 이름"
WARN_THRESHOLD=80
CRIT_THRESHOLD=90
```

| 변수                    | 설명                                                  |
| --------------------- | --------------------------------------------------- |
| `WEBHOOK_URL`         | Teams에 Adaptive Card를 게시하는 Power Automate 플로우 URL   |
| `TEAMS_MENTION_ID`    | 멘션할 사용자의 Teams(AAD) Object ID                        |
| `TEAMS_MENTION_NAME`  | 멘션 텍스트(`<at>이름</at>`)에 표시할 이름                        |
| `WARN_THRESHOLD`      | 스크립트 상단 기본값을 덮어씀 (선택)                                |
| `CRIT_THRESHOLD`      | 스크립트 상단 기본값을 덮어씀 (선택)                                |

`config.env`가 없거나 `WEBHOOK_URL`이 비어있으면 Teams 알림 전송은 건너뛰고
기존의 로그 기록 동작만 수행합니다.

## 13.2 전송 조건 (상태 변화 시에만 전송)

매 실행마다 현재 상태를 `OK` / `WARN` / `CRITICAL` 중 하나로 판정하고,
직전 실행의 상태를 `${LOG_DIR}/.thread_mon_state` 파일에 저장해 비교합니다.
**직전 상태와 동일하면 알림을 보내지 않고(쿨다운), 상태가 바뀐 경우에만 알림을 전송**합니다.

| 직전 상태 → 현재 상태            | 알림 전송 여부                  |
| -------------------------- | -------------------------- |
| OK → WARN / CRITICAL       | 전송 (`[WARN]` / `[CRITICAL]`) |
| WARN → CRITICAL (악화)       | 전송 (`[CRITICAL]`)           |
| CRITICAL → WARN (완화)       | 전송 (`[WARN]`)               |
| WARN / CRITICAL → OK (복구)  | 전송 (`[RECOVERED]`)          |
| 동일 상태 유지 (WARN→WARN 등)    | 전송하지 않음                    |

즉 사용률이 WARN/CRITICAL 임계치 이상으로 계속 유지되는 동안에는 매 분마다 반복 전송되지 않고,
상태가 바뀌는 시점에만 한 번씩 전송됩니다. 다만 로그 파일(`WARN_LOG`, `CRIT_LOG`)에는
상태 유지 여부와 무관하게 매 실행 결과가 계속 기록됩니다.

> `.thread_mon_state` 파일을 삭제하면 다음 실행 시 직전 상태를 알 수 없으므로 `OK`로 간주합니다.
> 이 경우 현재 상태가 WARN/CRITICAL이면 새로운 발생으로 판단해 알림이 다시 전송됩니다.

## 13.5 Thread Dump 자동 생성

Teams 알림과 같은 시점(직전 상태와 다른, 즉 새로 WARN/CRITICAL에 진입한 순간)에
WAS의 Thread Dump를 함께 남깁니다. 사용률이 WARN/CRITICAL로 계속 유지되는 동안에는
알림과 마찬가지로 반복해서 뜨지 않습니다.

### 동작 방식

1. `ps` 목록에서 `WAS_PROCESS_PATTERN`(기본값 `org.apache.catalina.startup.Bootstrap`)과
   일치하는 프로세스를 `pgrep -f`로 검색해 PID를 자동으로 찾습니다.
2. `jstack <PID>` (없으면 `jcmd <PID> Thread.print`)로 덤프를 떠서
   `${LOG_DIR}/threaddump/threaddump_<WARN|CRITICAL>_<시각>_pid<PID>.log`에 저장합니다.
3. 오래된 덤프 파일(`THREAD_DUMP_RETENTION_DAYS`, 기본 7일 경과)은 자동으로 삭제합니다.
4. 덤프 파일 경로는 `WARN_LOG`/`CRIT_LOG`에 기록되고, Teams 알림 카드의
   `Thread Dump` 항목에도 표시됩니다.

### 관련 설정 (`config.env`에서 덮어쓰기 가능)

| 변수                        | 기본값                                          | 설명                                   |
| ------------------------- | -------------------------------------------- | ------------------------------------ |
| `WAS_PROCESS_PATTERN`      | `org.apache.catalina.startup.Bootstrap`      | `pgrep -f`로 WAS 프로세스를 찾는 패턴          |
| `THREAD_DUMP_DIR`          | `${LOG_DIR}/threaddump`                      | Thread Dump 저장 디렉토리                  |
| `THREAD_DUMP_RETENTION_DAYS` | `7`                                         | 이 기간(일)이 지난 덤프 파일은 자동 삭제              |
| `JSTACK_BIN`               | `jstack`                                     | 덤프에 사용할 실행 파일 (PATH에 없으면 전체 경로 지정)   |

> Tomcat이 아닌 다른 WAS(HyperFrame 등)를 사용하거나 커스텀 실행 커맨드를 쓰는 경우,
> `ps -ef | grep java`로 실제 커맨드라인을 확인한 뒤 `WAS_PROCESS_PATTERN`을
> `config.env`에서 그 커맨드라인의 일부 문자열로 재정의해야 합니다.
>
> `jstack`/`jcmd`는 JDK에 포함된 도구이므로 JRE만 설치된 환경에서는 동작하지 않습니다.
> 이 경우 두 도구 모두 찾지 못했다는 에러가 `WARN_LOG`/`CRIT_LOG`에 기록되고,
> Thread Dump 없이 Teams 알림만 전송됩니다.
>
> 프로세스가 여러 개 매칭되면(예: 같은 서버에 WAS가 여러 개 실행 중) 첫 번째로 검색된
> PID를 대상으로 합니다. 특정 WAS를 지정하고 싶다면 `WAS_PROCESS_PATTERN`을
> 더 구체적으로(예: 포트 번호나 인스턴스 이름 포함) 설정하세요.

## 13.3 카드 형식

알림 카드는 제목 줄(상태별 아이콘/색상) + 멘션 줄 + 항목별 FactSet(표 형태)으로 구성되어,
하나의 긴 줄로 이어지던 이전 방식보다 가독성이 좋습니다.

| 상태         | 아이콘 | 색상        |
| ---------- | --- | --------- |
| WARN       | ⚠️  | warning   |
| CRITICAL   | 🔴  | attention |
| RECOVERED  | ✅   | good      |

예시(WARN):

```text
⚠️ [WARN] Thread Pool 사용률 WARN
<at>김재훈</at> 확인 부탁드립니다.

시간              2026-09-17 10:01:00
AJP 커넥터         ajp-nio-8009
사용률             83% (83/100)
Current Threads  100
Connection Count 142
CPU              6.7%
MEM              21.3%
Load Avg         0.05, 0.02, 0.00
```

## 13.4 수동 테스트

```bash
source config.env
curl -sS --max-time 10 -w "\nHTTP_STATUS:%{http_code}\n" \
  -X POST -H "Content-Type: application/json" \
  -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"$schema":"http://adaptivecards.io/schemas/adaptive-card.json","type":"AdaptiveCard","version":"1.4","body":[{"type":"TextBlock","text":"⚠️ [TEST] 알림 테스트","weight":"Bolder","size":"Medium","color":"warning","wrap":true},{"type":"TextBlock","text":"<at>'"${TEAMS_MENTION_NAME}"'</at> 확인 부탁드립니다.","wrap":true},{"type":"FactSet","facts":[{"title":"시간","value":"'"$(date '+%F %T')"'"},{"title":"비고","value":"수동 테스트 메시지"}]}],"msteams":{"entities":[{"type":"mention","text":"<at>'"${TEAMS_MENTION_NAME}"'</at>","mentioned":{"id":"'"${TEAMS_MENTION_ID}"'","name":"'"${TEAMS_MENTION_NAME}"'"}}]}}}]}' \
  "${WEBHOOK_URL}"
```

`HTTP_STATUS:202`가 반환되고 Teams 채널/챗에 멘션과 FactSet 표가 함께 도착하면 정상입니다.

---

# 14. 문제 해결

## JMX Exporter에 접속되지 않는 경우

```bash
curl -v http://localhost:9404/metrics
```

포트가 LISTEN 상태인지 확인합니다.

```bash
ss -lntp | grep 9404
```

Java Agent가 정상적으로 적용됐는지 확인합니다.

```bash
ps -ef | grep java
```

다음과 같은 옵션이 존재하는지 확인합니다.

```text
-javaagent:/path/to/jmx_prometheus_javaagent-1.6.0.jar=9404:/path/to/config.yaml
```

---

## AJP metric이 조회되지 않는 경우

```bash
curl -s http://localhost:9404/metrics |
grep 'catalina_threadpool_' |
grep 'ajp-'
```

결과가 없다면 `config.yaml`의 JMX Exporter 설정 및 WAS의 JMX MBean을 확인합니다.

---

## Script 실행 권한 오류

```bash
chmod +x thread_mon.sh
```

확인:

```bash
ls -l thread_mon.sh
```

예:

```text
-rwxr-xr-x 1 root root ... thread_mon.sh
```

---

## Script 문법 확인

실행하지 않고 Shell 문법만 검사할 수 있습니다.

```bash
bash -n thread_mon.sh
```

오류가 출력되지 않으면 문법상 문제가 없는 것입니다.

---

# 15. 전체 설치 순서

처음 설치하는 경우 다음 순서로 진행합니다.

```bash
# 1. Repository 다운로드
git clone <REPOSITORY_URL>

# 2. Repository 이동
cd <REPOSITORY_NAME>

# 3. 실행 권한 부여
chmod +x thread_mon.sh

# 4. config 확인
cat config.yaml

# 5. WAS에 JMX Exporter Java Agent 적용
-javaagent:/path/jmx_prometheus_javaagent-1.6.0.jar=9404:/path/config.yaml

# 6. WAS 재기동

# 7. JMX Exporter 확인
curl -s http://localhost:9404/metrics

# 8. AJP metric 확인
curl -s http://localhost:9404/metrics | grep 'catalina_threadpool_' | grep 'ajp-'

# 9. Script 문법 확인
bash -n thread_mon.sh

# 10. Script 수동 테스트
./thread_mon.sh

# 11. Crontab 등록
crontab -e

# 1분마다 실행
* * * * * /path/to/thread_mon.sh
```

---

# 16. 주의사항

* JMX Exporter의 `9404` 포트가 외부에 노출되지 않도록 방화벽 정책을 확인합니다.
* `thread_mon.sh`는 로컬의 `localhost:9404/metrics`를 조회하는 것을 기본으로 합니다.
* 여러 서버에 배포할 경우 `LOG_DIR`은 각 서버의 WAS 로그 경로에 맞게 수정해야 합니다.
* AJP Connector가 여러 개 존재하는 경우 현재 스크립트는 `ajp-`로 검색되는 첫 번째 Connector를 대상으로 합니다.
* JMX Exporter Java Agent 적용 시 WAS 재기동이 필요할 수 있습니다.
* 운영 환경에서는 로그 파일의 보관 기간 및 용량을 별도로 관리하는 것을 권장합니다.

