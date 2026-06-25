#!/bin/bash 


if [ -f "/root/slurm_data/${HOSTNAME}/start.sh" ]; then
    nohup sh /root/slurm_data/${HOSTNAME}/start.sh &
    echo "run ${HOSTNAME}" >> /root/login.txt
else
    echo "pass ${HOSTNAME}" >> /root/login.txt
fi
