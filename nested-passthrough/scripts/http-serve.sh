#!/bin/bash
set -e

ACTION="${1:-start}"
ZONE="${ZONE:-libvirt}"
BIND="${BIND:-192.168.130.1}"
PORT="${PORT:-80}"

if [[ -e out/http.pid ]] && grep http.server /proc/$(cat out/http.pid)/cmdline 2>/dev/null; then
    GOOD_PID=true
fi

# Find the available Python version
if command -v python3 &> /dev/null; then
    PYTHON="python3"
elif command -v python &> /dev/null; then
    PYTHON="python"
else
    echo "Neither python nor python3 is available"
    exit 1
fi

if [[ "${ACTION}" == "start" ]]; then
	# Even if it's already open, it's better to be sure
	sudo firewall-cmd --zone=${ZONE} --add-port=${PORT}/tcp
    if [[ -z "${GOOD_PID}" ]]; then
        echo 'Serving the image via HTTP to avoid copying it'
        if [[ -n "$BIND" ]]; then
            BIND_ARG="-b $BIND"
        fi
        sudo $PYTHON -m http.server $PORT -d ./out ${BIND_ARG} &
        echo $! > out/http.pid
    else
        echo 'HTTP server already running'
    fi

elif [[ "${ACTION}" == "stop" ]]; then
    sudo firewall-cmd --zone=${ZONE} --remove-port=${PORT}/tcp
    if [[ -n "${GOOD_PID}" ]]; then
        sudo kill $(cat out/http.pid)
    fi
    rm out/http.pid 2>/dev/null || true
else
    echo "Unknown action: Please use start or stop"
    exit 1
fi
