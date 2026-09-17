#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

METRIC_URL="http://localhost:9404/metrics"

LOG_DIR="/var/log/threadpool"

INFO_LOG="${LOG_DIR}/threadpool_$(date +%Y%m%d).log"
WARN_LOG="${LOG_DIR}/threadpool_warn_$(date +%Y%m%d).log"
CRIT_LOG="${LOG_DIR}/threadpool_critical_$(date +%Y%m%d).log"

# 직전 실행의 상태(OK/WARN/CRITICAL)를 기록. 날짜와 무관하게 유지되어야 하므로 날짜 접미사 없음
STATE_FILE="${LOG_DIR}/.thread_mon_state"

WARN_THRESHOLD=80
CRIT_THRESHOLD=90

# 메트릭 조회가 연속 몇 회 실패하면 Teams 알림을 보낼지 (기본 3회 = 3분)
METRIC_FAIL_THRESHOLD=3

# WARN/CRITICAL 진입 시 Thread Dump를 뜰 WAS 프로세스를 ps에서 찾기 위한 패턴 (pgrep -f)
WAS_PROCESS_PATTERN="org.apache.catalina.startup.Bootstrap"

THREAD_DUMP_DIR="${LOG_DIR}/threaddump"
THREAD_DUMP_RETENTION_DAYS=7
JSTACK_BIN="jstack"

# config.env가 있으면 WEBHOOK_URL / TEAMS_MENTION_ID / TEAMS_MENTION_NAME / Threshold 등을 덮어씀
if [ -f "${SCRIPT_DIR}/config.env" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi

mkdir -p "${LOG_DIR}" "${THREAD_DUMP_DIR}"

# 동시 실행 방지: 직전 실행이 아직 끝나지 않았으면(예: curl 지연) 이번 실행은 건너뛴다
LOCK_FILE="${LOG_DIR}/.thread_mon.lock"
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    exit 0
fi

SERVER_HOSTNAME="$(hostname)"
FAIL_COUNT_FILE="${LOG_DIR}/.thread_mon_fail_count"

# JSON 문자열 escape
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "${s//$'\n'/\\n}"
}

# Teams Adaptive Card 멘션 알림 전송 (WARN/CRITICAL/RECOVERED 발생 시)
# 사용법: send_teams_alert <LEVEL> <제목> "항목1=값1" "항목2=값2" ...
send_teams_alert() {
    local level="$1"
    local title="$2"
    shift 2

    if [ -z "${WEBHOOK_URL}" ]; then
        return 0
    fi

    local icon color
    case "${level}" in
        CRITICAL)  icon="🔴"; color="attention" ;;
        WARN)      icon="⚠️"; color="warning" ;;
        RECOVERED) icon="✅"; color="good" ;;
        *)         icon="ℹ️"; color="default" ;;
    esac

    local mention_name="${TEAMS_MENTION_NAME:-담당자}"
    local esc_name esc_title
    esc_name=$(json_escape "${mention_name}")
    esc_title=$(json_escape "${title}")

    # 남은 인자("항목=값")를 FactSet JSON으로 변환
    local facts_json="" pair key value esc_key esc_value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        esc_key=$(json_escape "${key}")
        esc_value=$(json_escape "${value}")
        if [ -n "${facts_json}" ]; then
            facts_json+=","
        fi
        facts_json+="{\"title\":\"${esc_key}\",\"value\":\"${esc_value}\"}"
    done

    local payload
    payload=$(cat <<EOF
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "content": {
        "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
          {
            "type": "TextBlock",
            "text": "${icon} [${level}] ${esc_title}",
            "size": "Medium",
            "weight": "Bolder",
            "color": "${color}",
            "wrap": true
          },
          {
            "type": "TextBlock",
            "text": "<at>${esc_name}</at> 확인 부탁드립니다.",
            "wrap": true
          },
          {
            "type": "FactSet",
            "facts": [${facts_json}]
          }
        ],
        "msteams": {
          "entities": [
            {
              "type": "mention",
              "text": "<at>${esc_name}</at>",
              "mentioned": {
                "id": "${TEAMS_MENTION_ID}",
                "name": "${esc_name}"
              }
            }
          ]
        }
      }
    }
  ]
}
EOF
)

    curl -s -o /dev/null --max-time 5 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${WEBHOOK_URL}"
}

# ps에서 WAS(Tomcat) 프로세스를 자동 검색해 PID로 Thread Dump를 뜬다.
# 사용법: take_thread_dump <LEVEL> (WARN/CRITICAL) -> 성공 시 stdout으로 덤프 파일 경로 출력
take_thread_dump() {
    local level="$1"
    local target_log="${WARN_LOG}"
    if [ "${level}" = "CRITICAL" ]; then
        target_log="${CRIT_LOG}"
    fi

    local pid
    pid=$(pgrep -f "${WAS_PROCESS_PATTERN}" 2>/dev/null | head -1)

    if [ -z "${pid}" ]; then
        echo "$(date '+%F %T') ERROR thread dump skipped: WAS process not found (pattern=${WAS_PROCESS_PATTERN})" >> "${target_log}"
        return 1
    fi

    local dump_file="${THREAD_DUMP_DIR}/threaddump_${level}_$(date +%Y%m%d_%H%M%S)_pid${pid}.log"

    if command -v "${JSTACK_BIN}" >/dev/null 2>&1; then
        "${JSTACK_BIN}" "${pid}" > "${dump_file}" 2>&1
    elif command -v jcmd >/dev/null 2>&1; then
        jcmd "${pid}" Thread.print > "${dump_file}" 2>&1
    else
        echo "$(date '+%F %T') ERROR thread dump skipped: jstack/jcmd not found (PID=${pid})" >> "${target_log}"
        return 1
    fi

    # 보관 기간이 지난 오래된 덤프 파일 정리
    find "${THREAD_DUMP_DIR}" -type f -mtime "+${THREAD_DUMP_RETENTION_DAYS}" -delete 2>/dev/null

    echo "$(date '+%F %T') Thread dump saved: PID=${pid} FILE=${dump_file}" >> "${target_log}"
    echo "${dump_file}"
}

# 메트릭 조회/파싱 실패 시 호출. 연속 실패 횟수가 임계치에 도달하는 시점에 1회만 알림
record_metric_failure() {
    local reason="$1"
    local fail_count=0

    if [ -f "${FAIL_COUNT_FILE}" ]; then
        fail_count=$(cat "${FAIL_COUNT_FILE}")
    fi
    fail_count=$((fail_count + 1))
    echo "${fail_count}" > "${FAIL_COUNT_FILE}"

    echo "$(date '+%F %T') ERROR ${reason} (연속 실패 ${fail_count}회)" >> "${WARN_LOG}"

    if [ "${fail_count}" -eq "${METRIC_FAIL_THRESHOLD}" ]; then
        send_teams_alert "CRITICAL" "메트릭 조회 실패" \
            "시간=$(date '+%F %T')" \
            "서버=${SERVER_HOSTNAME}" \
            "사유=${reason}" \
            "연속 실패 횟수=${fail_count}"
    fi
}

# 메트릭 조회/파싱이 정상으로 확인된 시점에 호출. 실패가 누적돼 있었다면 복구 알림 후 카운터 초기화
record_metric_success() {
    if [ -f "${FAIL_COUNT_FILE}" ]; then
        local fail_count
        fail_count=$(cat "${FAIL_COUNT_FILE}")
        if [ "${fail_count}" -ge "${METRIC_FAIL_THRESHOLD}" ]; then
            send_teams_alert "RECOVERED" "메트릭 조회 정상 복구" \
                "시간=$(date '+%F %T')" \
                "서버=${SERVER_HOSTNAME}" \
                "이전 연속 실패 횟수=${fail_count}"
        fi
        rm -f "${FAIL_COUNT_FILE}"
    fi
}

# JMX Exporter 조회
METRICS=$(curl -s --max-time 5 "${METRIC_URL}")

if [ -z "${METRICS}" ]; then
    record_metric_failure "JMX Exporter metrics unavailable"
    exit 1
fi

# AJP Thread Pool metric
AJP_BUSY=$(printf '%s\n' "${METRICS}" |
    grep 'catalina_threadpool_currentthreadsbusy{name=' |
    grep 'ajp-' |
    head -1 |
    awk '{print int($2)}')

AJP_CURR=$(printf '%s\n' "${METRICS}" |
    grep 'catalina_threadpool_currentthreadcount{name=' |
    grep 'ajp-' |
    head -1 |
    awk '{print int($2)}')

AJP_MAX=$(printf '%s\n' "${METRICS}" |
    grep 'catalina_threadpool_maxthreads{name=' |
    grep 'ajp-' |
    head -1 |
    awk '{print int($2)}')

AJP_CONN=$(printf '%s\n' "${METRICS}" |
    grep 'catalina_threadpool_connectioncount{name=' |
    grep 'ajp-' |
    head -1 |
    awk '{print int($2)}')

# AJP Connector 이름
AJP_NAME=$(printf '%s\n' "${METRICS}" |
    grep 'catalina_threadpool_currentthreadsbusy{name=' |
    grep 'ajp-' |
    head -1 |
    sed 's/.*name="\\"\(.*\)\\"".*/\1/')

# Metric 확인
if [[ ! "$AJP_BUSY" =~ ^[0-9]+$ ]] || [[ ! "$AJP_MAX" =~ ^[0-9]+$ ]]; then
    record_metric_failure "metric parse failed AJP=${AJP_NAME} BUSY=[${AJP_BUSY}] MAX=[${AJP_MAX}]"
    exit 1
fi

if [ "${AJP_MAX}" -eq 0 ]; then
    record_metric_failure "AJP maxThreads is 0"
    exit 1
fi

record_metric_success

# Thread Pool 사용률
USAGE=$((AJP_BUSY * 100 / AJP_MAX))

LOG_MSG="$(date '+%F %T') HOST=${SERVER_HOSTNAME} AJP=${AJP_NAME} BUSY=${AJP_BUSY}/${AJP_MAX}(${USAGE}%) CURRENT=${AJP_CURR} CONNECTION=${AJP_CONN}"

# 일반 로그
echo "${LOG_MSG}" >> "${INFO_LOG}"

# 현재 상태 판정
CURRENT_STATE="OK"
if [ "${USAGE}" -ge "${CRIT_THRESHOLD}" ]; then
    CURRENT_STATE="CRITICAL"
elif [ "${USAGE}" -ge "${WARN_THRESHOLD}" ]; then
    CURRENT_STATE="WARN"
fi

# 직전 상태 조회 (없으면 OK로 간주)
PREV_STATE="OK"
if [ -f "${STATE_FILE}" ]; then
    PREV_STATE=$(cat "${STATE_FILE}")
fi

if [ "${CURRENT_STATE}" != "OK" ]; then

    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4}')
    MEM=$(free -m | awk '/Mem:/ {printf "%.1f",$3/$2*100}')
    LOAD=$(uptime | awk -F'load average:' '{print $2}')

    DETAIL="${LOG_MSG} CPU=${CPU}% MEM=${MEM}% LOAD=${LOAD}"

    if [ "${CURRENT_STATE}" = "CRITICAL" ]; then
        echo "[CRITICAL] ${DETAIL}" >> "${CRIT_LOG}"
    else
        echo "[WARN] ${DETAIL}" >> "${WARN_LOG}"
    fi

    # 쿨다운: 직전 실행과 상태가 동일하면(같은 WARN/CRITICAL 지속) 알림을 다시 보내지 않음
    if [ "${CURRENT_STATE}" != "${PREV_STATE}" ]; then
        # 새로 WARN/CRITICAL에 진입한 시점에만 Thread Dump를 뜬다 (반복 전송 방지와 동일한 시점)
        DUMP_FILE=$(take_thread_dump "${CURRENT_STATE}")

        send_teams_alert "${CURRENT_STATE}" "Thread Pool 사용률 ${CURRENT_STATE}" \
            "시간=$(date '+%F %T')" \
            "서버=${SERVER_HOSTNAME}" \
            "AJP 커넥터=${AJP_NAME}" \
            "사용률=${USAGE}% (${AJP_BUSY}/${AJP_MAX})" \
            "Current Threads=${AJP_CURR}" \
            "Connection Count=${AJP_CONN}" \
            "CPU=${CPU}%" \
            "MEM=${MEM}%" \
            "Load Avg=${LOAD}" \
            "Thread Dump=${DUMP_FILE:-N/A}"
    fi

else
    # WARN/CRITICAL 상태였다가 정상으로 돌아온 경우에만 복구 알림
    if [ "${PREV_STATE}" != "OK" ]; then
        send_teams_alert "RECOVERED" "Thread Pool 정상 복구" \
            "시간=$(date '+%F %T')" \
            "서버=${SERVER_HOSTNAME}" \
            "AJP 커넥터=${AJP_NAME}" \
            "사용률=${USAGE}% (${AJP_BUSY}/${AJP_MAX})" \
            "Current Threads=${AJP_CURR}" \
            "Connection Count=${AJP_CONN}" \
            "이전 상태=${PREV_STATE}"
    fi
fi

echo "${CURRENT_STATE}" > "${STATE_FILE}"

