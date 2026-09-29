#!/bin/sh
# Packs the mod into ../FS25_SellPrices.zip (runtime files only).
cd "$(dirname "$0")" || exit 1
rm -f ../FS25_SellPrices.zip
zip -r -X ../FS25_SellPrices.zip modDesc.xml LICENSE icon_SellPrices.dds scripts config -x '*.DS_Store'
