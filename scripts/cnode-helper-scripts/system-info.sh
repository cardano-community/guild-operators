#!/bin/bash

# pHTN testnet watchdog
# 2020-04-09 v0.1  initial proposal

echo -e "-------------------------------System Information----------------------------"
echo -e "Hostname:\t\t""$(hostname)"
echo -e "uptime:\t\t\t""$(uptime | awk '{print $3,$4}' | sed 's/,//')"
echo -e "Manufacturer:\t\t""$(cat /sys/class/dmi/id/chassis_vendor)"
echo -e "Product Name:\t\t""$(cat /sys/class/dmi/id/product_name)"
echo -e "Version:\t\t""$(cat /sys/class/dmi/id/product_version)"
#echo -e "Serial Number:\t\t""$(cat /sys/class/dmi/id/product_serial)"
echo -e "Machine Type:\t\t""$(vserver=$(lscpu | grep -c Hypervisor); if [ "$vserver" -gt 0 ]; then echo "VM"; else echo "Physical"; fi)"
echo -e "Operating System:\t""$(hostnamectl | grep "Operating System" | cut -d ' ' -f5-)"
echo -e "Kernel:\t\t\t""$(uname -r)"
echo -e "Architecture:\t\t""$(arch)"
echo -e "Processor Name:\t\t""$(awk -F':' '/^model name/ {print $2}' /proc/cpuinfo | uniq | sed -e 's/^[ \t]*//')"
echo -e "Active User:\t\t""$(w | cut -d ' ' -f1 | grep -v USER | xargs -n1)"
#echo -e "System Main IP:\t\t""$(hostname -I)"
echo ""
echo -e "-------------------------------CPU/Memory Usage------------------------------"
echo -e "Memory Usage:\t""$(free | awk '/Mem/{printf("%.2f%"), $3/$2*100}')"
echo -e "Swap Usage:\t""$(free | awk '/Swap/{if($2=="0")v=0;else v=$3/$2*100;printf(" %.2f\n",$v)}')"
echo -e "CPU Usage:\t""$(awk '/cpu/{printf("%.2f%\n"), ($2+$4)*100/($2+$4+$5)}' < /proc/stat |  awk '{print $0}' | head -1)"
echo ""
echo -e "-------------------------------Disk Usage >80%-------------------------------"
df -Ph | sed s/%//g | awk '{ if($5 > 80) print $0;}'
echo ""

while :
do
        echo -e "$(date '+%H:%M:%S') MEM-total\t""$(free | awk '/Mem/{printf("%.2f%"), $3/$2*100}')"
        sleep 10
done
