#!/usr/bin/env bash

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

# placeholder

######################################
# Do NOT modify code below           #
######################################

watch 'echo "show stat" | nc -U '"$(dirname "$0")"'/../sockets/haproxy.socket | grep -e svname -e ^grest -e ^ogmios -e ^submitapi | sed -e '"'"'s#no check#NoCheck#'"'"' | cut -d, -f 1,2,18,19,20,74 | tr "," " " | column -t'
