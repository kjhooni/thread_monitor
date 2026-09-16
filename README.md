# Tomcat AJP Thread Pool Monitor

JMX Exporter를 이용하여 Tomcat의 **AJP Connector Thread Pool 상태**를 모니터링하고,
Thread Pool 사용률에 따라 INFO / WARN / CRITICAL 로그를 기록하는 간단한 모니터링 스크립트입니다.

## 구성

```text
.
├── README.md
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

# 13. 문제 해결

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

# 14. 전체 설치 순서

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

# 15. 주의사항

* JMX Exporter의 `9404` 포트가 외부에 노출되지 않도록 방화벽 정책을 확인합니다.
* `thread_mon.sh`는 로컬의 `localhost:9404/metrics`를 조회하는 것을 기본으로 합니다.
* 여러 서버에 배포할 경우 `LOG_DIR`은 각 서버의 WAS 로그 경로에 맞게 수정해야 합니다.
* AJP Connector가 여러 개 존재하는 경우 현재 스크립트는 `ajp-`로 검색되는 첫 번째 Connector를 대상으로 합니다.
* JMX Exporter Java Agent 적용 시 WAS 재기동이 필요할 수 있습니다.
* 운영 환경에서는 로그 파일의 보관 기간 및 용량을 별도로 관리하는 것을 권장합니다.

