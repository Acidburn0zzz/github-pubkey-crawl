#!/bin/sh

dub build -b release

retcode=-1
while [ "$retcode" -ne 0 ]; do
	./github-pubkey-crawl -w 20
	retcode=$?
	if [ "$retcode" -ne 0 ]; then
		sleep 1h
	fi
done