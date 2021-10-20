#!/usr/bin/env bash

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################

# placeholder

######################################
# Do NOT modify code below           #
######################################

watch 'echo "show stat" | nc 127.0.0.1 8055 | grep -e svname -e ^koios | cut -d, -f 2,18,20,74 | tr "," " " | column -t'
