#!/bin/sh

marker=$1

sh -c '
marker=$1
trap "(sleep 0.15; printf survived > \"$marker\") &" TERM
while :; do sleep 1; done
' kangaroo-child "$marker" &

printf ready
while :; do sleep 1; done
