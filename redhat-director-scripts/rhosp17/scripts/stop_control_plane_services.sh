#!/bin/bash -x

systemctl disable tripleo_triliovault_wlm_api.service
systemctl stop tripleo_triliovault_wlm_api.service

systemctl disable tripleo_triliovault_wlm_scheduler.service
systemctl stop tripleo_triliovault_wlm_scheduler.service

systemctl disable tripleo_triliovault_wlm_cron.service
systemctl stop tripleo_triliovault_wlm_cron.service

systemctl disable tripleo_triliovault_wlm_workloads.service
systemctl stop tripleo_triliovault_wlm_workloads.service

systemctl disable tripleo_triliovault_dms.service
systemctl stop tripleo_triliovault_dms.service

## Legacy (<= 6.1) object-store units, if still present
for unit in $(systemctl list-units --all --plain --no-legend 'tripleo_triliovault_object_store*' | awk '{print $1}'); do
    systemctl disable --now "$unit"
done
