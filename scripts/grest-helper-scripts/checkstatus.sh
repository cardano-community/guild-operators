#!/usr/bin/env bash

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

# placeholder

######################################
# Do NOT modify code below           #
######################################

watch 'echo "show stat" | nc -U '"$(dirname "$0")"'/../sockets/haproxy.socket | grep -e svname -e ^grest | cut -d, -f 2,18,20,74 | tr "," " " | column -t'
