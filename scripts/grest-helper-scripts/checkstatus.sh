#!/usr/bin/env bash

watch 'echo "show stat" | nc 127.0.0.1 8055 | grep -e svname -e ^grest | cut -d, -f 2,18,20,74 | tr "," " " | column -t'
