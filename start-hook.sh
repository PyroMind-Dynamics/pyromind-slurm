#!/bin/bash 


if [ -f "/root/slurm_data/${HOSTNAME}/start.sh" ]; then
    nohup sh /root/slurm_data/${HOSTNAME}/start.sh &
    echo "run ${HOSTNAME}"
else
    echo "pass ${HOSTNAME}"
fi
