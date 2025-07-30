#!/bin/sh
# run this with sudo to install
cp ~/.config/kanata/*.plist /Library/LaunchDaemons

launchctl bootstrap system /Library/LaunchDaemons/com.example.kanata.plist
launchctl bootstrap system /Library/LaunchDaemons/com.example.karabiner-vhiddaemon.plist
launchctl bootstrap system /Library/LaunchDaemons/com.example.karabiner-vhidmanager.plist

launchctl enable system/com.example.kanata
launchctl enable system/com.example.karabiner-vhiddaemon
launchctl enable system/com.example.karabiner-vhidmanager

launchctl start com.example.karabiner-vhiddaemon
launchctl start com.example.karabiner-vhidmanager
launchctl start com.example.kanata
