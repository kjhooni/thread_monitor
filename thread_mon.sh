#!/bin/bash

METRIC_URL="http://localhost:9404/metrics"

LOG_DIR="/var/log/threadpool"

INFO_LOG="${LOG_DIR}/threadpool_$(date +%Y%m%d).log"
WARN_LOG="${LOG_DIR}/threadpool_warn_$(date +%Y%m%d).log"
CRIT_LOG="${LOG_DIR}/threadpool_critical_$(date +%Y%m%d).log"

WARN_THRESHOLD=80
CRIT_THRESHOLD=90

mkdir -p "${LOG_DIR}"

# JMX Exporter 조회
METRICS=$(curl -s --max-time 5 "${METRIC_URL}")

if [ -z "${METRICS}" ]; then
    echo "$(date '+%F %T') ERROR JMX Exporter metrics unavailable" >> "${WARN_LOG}"
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
    echo "$(date '+%F %T') ERROR metric parse failed AJP=${AJP_NAME} BUSY=[${AJP_BUSY}] MAX=[${AJP_MAX}]" >> "${WARN_LOG}"
    exit 1
fi

if [ "${AJP_MAX}" -eq 0 ]; then
    echo "$(date '+%F %T') ERROR AJP maxThreads is 0" >> "${WARN_LOG}"
    exit 1
fi

# Thread Pool 사용률
USAGE=$((AJP_BUSY * 100 / AJP_MAX))

LOG_MSG="$(date '+%F %T') AJP=${AJP_NAME} BUSY=${AJP_BUSY}/${AJP_MAX}(${USAGE}%) CURRENT=${AJP_CURR} CONNECTION=${AJP_CONN}"

# 일반 로그
echo "${LOG_MSG}" >> "${INFO_LOG}"

# Critical
if [ "${USAGE}" -ge "${CRIT_THRESHOLD}" ]; then

    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4}')
    MEM=$(free -m | awk '/Mem:/ {printf "%.1f",$3/$2*100}')
    LOAD=$(uptime | awk -F'load average:' '{print $2}')

    echo "[CRITICAL] ${LOG_MSG} CPU=${CPU}% MEM=${MEM}% LOAD=${LOAD}" >> "${CRIT_LOG}"

# Warning
elif [ "${USAGE}" -ge "${WARN_THRESHOLD}" ]; then

    CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4}')
    MEM=$(free -m | awk '/Mem:/ {printf "%.1f",$3/$2*100}')
    LOAD=$(uptime | awk -F'load average:' '{print $2}')

    echo "[WARN] ${LOG_MSG} CPU=${CPU}% MEM=${MEM}% LOAD=${LOAD}" >> "${WARN_LOG}"

fi

