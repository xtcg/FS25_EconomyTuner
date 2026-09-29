# FS25_SellPrices

用一张 XML 价格表覆盖任意 fillType 的卖价（游戏本体 + 地图 + 其他 mod）。价格按 **HARD 经济难度**（难度倍率 1）定义；默认只在 HARD 存档生效。

## 用法

1. 把本目录打包成 `FS25_SellPrices.zip`（`sh build.sh`）放进 mods，存档里启用。
2. 第一次进存档后，价格表会复制到
   `Documents/My Games/FarmingSimulator2025/modSettings/FS25_SellPrices/prices.xml`。
   以后改这份，不用重新打包。
3. 改完后重进存档，或在开发者控制台输入 `spReload` 立即生效（单机或服务器）。
4. `spDump` 会写出 `modSettings/FS25_SellPrices/priceDump.csv`，内容是全部 fillType 的原价、现价、季节系数，以及每个收购点的倍率和 xml 路径。默认表里的 `dumpOnStart="true"` 会让每次开档自动写一次。

## 价格表格式

```xml
<fillType name="WHEAT"  price="337"/>                 <!-- €/1000 L，HARD 下的游戏内价格 -->
<fillType name="SILAGE" scale="0.5"/>                 <!-- 在原价（本体或地图定义的）基础上乘系数 -->
<fillType name="MILK"   price="500" factors="1.06 1.01 0.96 0.90 0.95 0.95 1.03 1.09 0.98 0.96 1.08 1.07"/>
<station xmlFilename="placeables/animalDealer/animalDealer.xml" fillType="SILAGE" priceScale="0.2"/>
```

- `factors`：12 个季节系数，按 period 1..12 排列（早春到晚冬）。不写就沿用原曲线。
- `<station>`：替换某个收购点对某个 fillType 的 priceScale。`xmlFilename` 按路径后缀匹配，完整路径可以在 dump 里查到。
- 默认表是 1.23.1 本体 + HB 1.5.0.0 Beta2 的当前价格快照（121 项），装上后不会改变任何价格。

## 生效范围（已对照 1.23.1 源码核实）

改动的是 `fillType.pricePerLiter` 和 `economy.factors`，在所有收购点加载之前写入（挂在 `FillTypeManager:loadModFillTypes` 之后）。下面这些都会跟着变：

- 收购点卖价，各收购点自己的 priceScale 照常乘上
- 生产点"直接出售"
- HB 农场商店
- 草捆估值、收割任务的赔偿额
- RLRM 的肉价下限（它读收购点价格）

不跟着变的：

- **买价**（`keepBuyPrices="true"`）：`BuyingStation` 和 `EconomyManager:getCostPerLiter` 仍按原价计算。
- **存档价格历史**（`economy.xml`）：会按"存档时的价格 → 新价格"的比例缩放。所用价格记录在 `economy.xml` 的 `<sellPrices>` 下，所以反复读档不会重复缩放。
- **收购点的随机波动曲线**：存档里保存的是绝对振幅（€/L），读档后会按新价格缩放，否则大幅降价后波动会超过价格本身。

## 限制

- 难度倍率在游戏中途可以改。表里的值只对 HARD 成立，改成 EASY 或 NORMAL 后会再乘 3 或 1.8。
- 联机时每台机器读自己的 `prices.xml`，必须保持一致。收购点价格由服务器同步。
- 收购点价格同步用 UInt16/1000，单价上限 65.5 €/L。
- 没有提供"禁止某收购点收某 fillType"的功能（原计划的 E 层）。

## 测试

```sh
pip install lupa
python tests/run.py
```
