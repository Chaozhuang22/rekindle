#!/bin/sh
# Name: KUAL
# Author: rekindle
#
# Library entry that opens KUAL (run by the jailbreak's shell integration when tapped).
#
# Equivalent to PEKI's KUAL.sh (https://github.com/KindleTweaks/PEKI) minus its final
# `nohup`, which FW 5.8.x does not ship, so tapping PEKI's launcher silently did nothing.
# First run installs the KUAL booklet from /mnt/us/documents/KUAL.jar; later runs just open it.

JAR=/opt/amazon/ebook/booklet/KUALBooklet.jar
APP=com.mobileread.ixtab.kindlelauncher

if [ ! -f "$JAR" ]; then
	if [ ! -f /mnt/us/documents/KUAL.jar ]; then
		eips 1 25 "KUAL.jar missing from documents/" 2>/dev/null
		exit 1
	fi
	eips 1 25 "Installing KUAL..." 2>/dev/null
	mntroot rw
	cp -f /mnt/us/documents/KUAL.jar "$JAR"
	sqlite3 /var/local/appreg.db <<EOF
INSERT OR IGNORE INTO "handlerIds" VALUES('$APP');
INSERT OR IGNORE INTO "properties" VALUES('$APP','lipcId','$APP');
INSERT OR IGNORE INTO "properties" VALUES('$APP','jar','$JAR');
INSERT OR IGNORE INTO "properties" VALUES('$APP','maxUnloadTime','45');
INSERT OR IGNORE INTO "properties" VALUES('$APP','maxGoTime','60');
INSERT OR IGNORE INTO "properties" VALUES('$APP','maxPauseTime','60');
INSERT OR IGNORE INTO "properties" VALUES('$APP','default-chrome-style','NH');
INSERT OR IGNORE INTO "properties" VALUES('$APP','unloadPolicy','unloadOnPause');
INSERT OR IGNORE INTO "properties" VALUES('$APP','extend-start','Y');
INSERT OR IGNORE INTO "properties" VALUES('$APP','searchbar-mode','transient');
INSERT OR IGNORE INTO "properties" VALUES('$APP','supportedOrientation','U');
EOF
	mntroot ro
	rm -f /mnt/us/documents/KUAL.jar
fi

(
	sleep 1
	lipc-set-prop com.lab126.appmgrd start "app://$APP"
) >/dev/null 2>&1 &
