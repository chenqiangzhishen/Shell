#!/bin/bash
#
# The script is used for mesos cluster maintenance.
#
LOG_FILE=/tmp/.$(basename $0 .sh)
MAINTENANCE_CANCEL_LOG=$LOG_FILE.cancel.log
MAINTENANCE_DRAIN_LOG=$LOG_FILE.drain.log
MAINTENANCE_DOWN_LOG=$LOG_FILE.down.log
MAINTENANCE_UP_LOG=$LOG_FILE.up.log

CURL_HEAD="Content-type: application/json"
MAINTENANCE_SCHEDULE="maintenance/schedule"
MAINTENANCE_STATUS="maintenance/status"
MACHINE_DOWN="machine/down"
MACHINE_UP="machine/up"

function usage () {
    cat << EOF
Usage: $(basename $0) <command> <cluster> <host-pattern> [duration]

Supported command:
    drain                               put the specified nodes to DRAIN mode
    down                                put the specified nodes to DOWN mode
    up                                  put the specified nodes to UP mode
    cancel                              cancel maintenance
    status                              get maintenance status
    help                                display help info

Required argument:
    cluster                             the cluster operated on, ansible inventory file
    host-pattern                        host-pattern that contains part slaves in the cluster

Optional argument:
    duration                            maintenance duration time, unit is hour, default is 2 hours

Examples:
    # use default maintenance duration time (2 hours)
    ./bin/maintenance.sh status hosts/cqdx-dev-chenqiang part-slaves

    # set 4 hours for the maintenance duration time
    ./bin/maintenance.sh status hosts/cqdx-dev-chenqiang part-slaves 4
EOF

    exit 1
}

function fail() {
    echo "$@"
    exit 1
}

function get_leader_master_url() {
    read masters <<< $(awk '/\[masters\]/ && $0!="" { while(1) { getline; if($0 != "" && !/^#/) { print $0; break } } }' $CLUSTER)
    machine_seq=$(echo $masters | grep -o -P '(?<=\[).*(?=\:)')
    one_master=$(echo $masters $machine_seq | awk '{ gsub(/\[.*\]/, $2, $1); print $1}')
    [[ $one_master == -1 ]] && fail "[FAIL]: check masters host pattern"
    read leader_master_url <<< $(python <<CODE
import urllib2
from urlparse import urlparse
req = urllib2.Request("http://" + "$one_master" + ":5050/master/redirect")
leader_master_url = urllib2.urlopen(req).geturl()
print leader_master_url
CODE
)
    echo $leader_master_url
}

function get_machine_ids() {
    read machine_ids <<< $(
    ansible $SLAVES_PATTERN -i $CLUSTER -m shell -a \
    "grep IPADDR /etc/sysconfig/network-scripts/ifcfg-eth0 | cut -d= -f2" |
    sed -e '/^\s*$/d' -e '/rc=0/N; s#\n# #g' -e 's/"//g' |
    awk '{
        machine_ids[++machine_cnt] = "{\"hostname\":\""$1"\",\"ip\":\""$NF"\"}"
    }
    END {
        if (machine_cnt <= 0) {
            print -1
            exit -1
        }
        print "["
        printf "%s", machine_ids[1]
        for (i=2; i<=machine_cnt; ++i) {
            printf ",\n%s", machine_ids[i]
        }
        print "]"
    }')
    [[ $machine_ids == -1 ]] && fail "[FAIL]: check maintenance nodes host pattern"
}

function drain_json() {
    schedule_json="{\"windows\":[{\"machine_ids\":$machine_ids, \
                    \"unavailability\":{\"start\":{\"nanoseconds\":"$(date +%s%N)"},\"duration\":{\"nanoseconds\":$DURATION_TIME}}}]}"
}

function drain() {
    drain_json
    curl -X POST \
         -H "$CURL_HEAD" \
         -d "$schedule_json" \
         $leader_master_url$MAINTENANCE_SCHEDULE \
         1>>$MAINTENANCE_DRAIN_LOG 2>&1
    [[ $? == 0 ]] && echo "[SUCCESS]: in DRAIN mode" || echo "[FAIL]: in DRAIN mode"
}

function down() {
    curl -X POST \
         -H "$CURL_HEAD" \
         -d "$machine_ids" \
         $leader_master_url$MACHINE_DOWN \
         1>>$MAINTENANCE_DOWN_LOG 2>&1
    [[ $? == 0 ]] && echo "[SUCCESS]: in DOWN mode" || echo "[FAIL]: in DOWN mode"
}

function up() {
    curl -X POST \
         -H "$CURL_HEAD" \
         -d "$machine_ids" \
         $leader_master_url$MACHINE_UP \
         1>>$MAINTENANCE_UP_LOG 2>&1
    [[ $? == 0 ]] && echo "[SUCCESS]: in UP mode" || echo "[FAIL]: in UP mode"
}

function cancel() {
    curl -X POST \
         -H "$CURL_HEAD" \
         -d "{}" \
         $leader_master_url$MAINTENANCE_SCHEDULE \
         1>>$MAINTENANCE_CANCEL_LOG 2>&1
    [[ $? == 0 ]] && echo "[SUCCESS]: cancel maintenance" || echo "[FAIL]: cancel maintenance"
}

function status() {
    read status_json <<< $(curl -X GET \
        $leader_master_url$MAINTENANCE_STATUS)
    [[ $? == 0 ]] && echo "[SUCCESS]: get job status" || echo "[FAIL]: get job status"
    echo $status_json | python -m json.tool
}

if [ $# -lt 3 -o $# -gt 4 ]; then
    usage
else
    CLUSTER=$2
    SLAVES_PATTERN=$3
    # note: should use nanseconds and set 2 hours as default maintenance time.
    if [ "x$4" = "x" ]; then
        DURATION_TIME=7200000000000
    else
        DURATION_TIME=$(bc<<<"$4*3600000000000")
    fi
    get_machine_ids
    get_leader_master_url
    case "$1" in
        "drain")
            drain
            ;;
        "down")
            down
            ;;
        "up")
            up
            ;;
        "cancel")
            cancel
            ;;
        "status")
            status
            ;;
        *)
            usage
            ;;
    esac
fi
