#!/usr/bin/env bash

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

# HAPROXY_MON_PORT=8055       # Port where HAProxy stats can be connected to, corresponds to "stats socket" line in haproxy.cfg file

######################################
# Do NOT modify code below           #
######################################

[[ -z ${HAPROXY_MON_PORT} ]] && HAPROXY_MON_PORT=8055

watch "echo 'show stat' | nc 127.0.0.1 ${HAPROXY_MON_PORT} | grep -e svname -e ^grest | cut -d, -f 2,18,20,74 | tr ',' ' ' | column -t"
