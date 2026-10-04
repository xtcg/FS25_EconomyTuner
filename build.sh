#!/bin/sh
# Packs the mod into ../FS25_EconomyTuner.zip (runtime files only).
cd "$(dirname "$0")" || exit 1
rm -f ../FS25_EconomyTuner.zip
zip -r -X ../FS25_EconomyTuner.zip modDesc.xml LICENSE icon_EconomyTuner.dds scripts config -x '*.DS_Store'
