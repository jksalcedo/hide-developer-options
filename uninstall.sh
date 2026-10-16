#!/system/bin/sh
pkill -f hide-developer-options.sh   # daemon restores real settings on TERM
sleep 3
rm -rf /data/adb/hide_developer_options
