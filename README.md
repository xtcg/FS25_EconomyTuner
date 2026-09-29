# FS25_SellPrices

[中文](#中文) | [English](#english)

---

## 中文

用一张 XML 价格表设定 Farming Simulator 25 里任意货物（fillType）的卖价，本体、地图和其他 mod 加的货物都可以。不用改地图文件。

表里的价格就是 **HARD 经济难度**下游戏里显示的价格。默认只在 HARD 存档生效。

### 安装

1. 从 [Releases](https://github.com/xtcg/FS25_SellPrices/releases) 下载 `FS25_SellPrices.zip`，**不要解压**，直接放进 mods 文件夹。
2. 在存档的 mod 列表里勾选 **Sell Price Table**。
3. 进一次存档。价格表会自动复制到：
   `文档/My Games/FarmingSimulator2025/modSettings/FS25_SellPrices/prices.xml`
   以后**只改这一份**，zip 里的那份只是默认模板。

默认表是本体 1.23.1 + Hof Bergmann 1.5.0.0 Beta2 的当前价格快照，共 121 项。装上后价格不变，日志里会显示 `0 fillTypes changed, 121 already at table value`。

### 改价格

用文本编辑器打开 `prices.xml`，改数字，保存。生效方式有两种：

- 重新载入存档；
- 或者在游戏里打开开发者控制台（需要在 `game.xml` 里设置 `<development><controls>true</controls></development>`，然后按 `~`），输入 `spReload`，立即生效。

每一行对应一种货物，三种写法选一种：

```xml
<fillType name="WHEAT"  price="400"/>     <!-- 基准价：€/1000 L -->
<fillType name="WHEAT"  average="400"/>   <!-- 全年平均价：€/1000 L -->
<fillType name="SILAGE" scale="0.5"/>     <!-- 在原价基础上乘系数 -->
```

还可以加上季节曲线：

```xml
<fillType name="MILK" price="500" factors="1.06 1.01 0.96 0.90 0.95 0.95 1.03 1.09 0.98 0.96 1.08 1.07"/>
```

单位都是 € 每 1000 升。按件计的货物（鸡蛋、羊毛等）是 € 每 1000 件。每一行后面的注释写着来源（本体、HB，或 HB 改过的本体价），以及折算后的 €/吨。

### 游戏里的实际卖价怎么算

```
实际卖价 = (基准价 × 收购点倍率 × 季节系数 + 随机波动) × 大订单倍率 × 难度倍率
```

| 项 | 说明 |
|---|---|
| **基准价** | 表里的 `price`，也就是游戏里的 `pricePerLiter` |
| **收购点倍率** | 每个收购点在自己的 xml 里对每种货物设的 priceScale。例如 HB 的草捆 ×0.8，糖厂的块根 ×1.1。可以用 `<station>` 改 |
| **季节系数** | 一年 12 个 period，每个 period 对应一个月。period 1 是早春（3 月），period 12 是晚冬（2 月）。每个 period 开始时的价格等于 基准价 × 当月系数，period 内部平滑插值 |
| **随机波动** | 每个收购点各自有一条正弦波动曲线，最多约 ±7%，通常 ±2~4%，长期平均为 0。周期大约是真实时间 2 天和 7 天，有时会停在平台期不动 |
| **大订单倍率** | 偶尔出现的"大量需求"事件，临时加价 |
| **难度倍率** | HARD ×1，NORMAL ×1.8，EASY ×3。所以表里的价格只在 HARD 下与游戏显示一致 |

**`price` 是平均价吗？** 大多数情况下接近。全年平均价等于 基准价 × 12 个季节系数的平均值。本体和 HB 的大部分作物，季节系数平均下来是 1.00~1.02，所以 `price` 基本就是全年平均价。例外：

| 货物 | 季节系数均值 | 原因 |
|---|---|---|
| 芦笋（ASPARAGUS*） | 0.63~0.87 | 淡季系数只有 0.01 |
| 葡萄、橄榄、橄榄油、米糠油 | 0.97 | |
| 块根（土豆、甜菜等） | 1.02 | |

想直接按全年平均价来定，就用 `average`。mod 会把基准价算成 `average ÷ 系数均值`，12 个月的价格平均下来正好等于你填的数。`priceDump.csv` 里的 `averagePer1000` 列就是每种货物当前的全年平均价。

`factors` 不写时沿用本体或地图的原曲线。写了就要写满 12 个数，从 period 1 排到 period 12。

### 单独改某个收购点

```xml
<station xmlFilename="placeables/sellingStations/animalDealer/sellingStation_animalDealer.xml"
         fillType="SILAGE" priceScale="0.2"/>
```

这会把这个收购点对这种货物的 priceScale 替换掉。`xmlFilename` 按路径结尾匹配，各收购点的完整路径可以在 `priceDump.csv` 里找到。

### 设置项

写在 `<settings .../>` 里：

| 设置 | 默认 | 作用 |
|---|---|---|
| `requireHardDifficulty` | true | 只在 HARD 存档生效；其他难度会再乘 1.8 或 3 |
| `keepBuyPrices` | true | 改过价的货物，在买入站的买价和消耗成本仍按原价算 |
| `rescaleHistory` | true | 把存档里的价格历史曲线按新价格等比缩放 |
| `dumpOnStart` | true | 每次进档写一份 `priceDump.csv` |

### 控制台命令

| 命令 | 作用 |
|---|---|
| `spReload` | 重新读 `prices.xml`，立即更新所有收购点（单机或服务器） |
| `spDump` | 写出 `modSettings/FS25_SellPrices/priceDump.csv` |

`priceDump.csv` 用分号分隔，列依次是：货物名；标题；原价；现价；全年平均价；是否被改过；12 个季节系数；收购这种货物的收购点（名称、倍率、xml 路径）。可以直接用 Excel 打开。

### 影响范围

价格改的是货物本身的定义，所以下面这些都会跟着变：

- 收购点卖价
- 生产点"直接出售"
- HB 农场商店
- 草捆估值
- 收割任务的赔偿额
- RLRM 的肉价下限

另外：

- 买价不变（见 `keepBuyPrices`）。
- 存档里的价格历史会按新旧价格的比例缩放。所用的价格记在 `economy.xml` 里，反复读档不会重复缩放。
- 收购点的随机波动幅度会跟着新价格缩放。

### 注意

- 表里的数只对 HARD 成立。游戏中途把难度改成其他档，价格会再乘 1.8 或 3。
- 联机时每台机器都读自己的 `prices.xml`，必须保持一致。收购点价格由服务器同步。
- 单价上限是 65.5 €/L（游戏网络同步的限制）。
- 暂时不能禁止某个收购点收某种货物，只能用很低的 `priceScale` 代替。

---

## English

Sets the sell price of any fillType in Farming Simulator 25 from one XML table. This works for the base game, the map and other mods, without editing map files.

Prices are the in-game price on **HARD economic difficulty**. By default the mod only applies them on HARD savegames.

### Install

1. Download `FS25_SellPrices.zip` from [Releases](https://github.com/xtcg/FS25_SellPrices/releases) and put it into your mods folder **without unzipping**.
2. Enable **Sell Price Table** for your savegame.
3. Load the savegame once. The table is copied to
   `Documents/My Games/FarmingSimulator2025/modSettings/FS25_SellPrices/prices.xml`.
   **Edit only that copy.** The one inside the zip is just the default.

The default table is a snapshot of the current prices from base game 1.23.1 and Hof Bergmann 1.5.0.0 Beta2 (121 fillTypes). Installing the mod changes no prices; the log shows `0 fillTypes changed, 121 already at table value`.

### Changing prices

Edit `prices.xml` in a text editor and save it. To apply the changes, either:

- reload the savegame, or
- open the developer console and type `spReload`. The console needs `<development><controls>true</controls></development>` in `game.xml`; then press `~`.

Each line sets one fillType. Use one of three forms:

```xml
<fillType name="WHEAT"  price="400"/>     <!-- base price, EUR per 1000 L -->
<fillType name="WHEAT"  average="400"/>   <!-- year-round average, EUR per 1000 L -->
<fillType name="SILAGE" scale="0.5"/>     <!-- multiply the original price -->
```

You can also add a seasonal curve:

```xml
<fillType name="MILK" price="500" factors="1.06 1.01 0.96 0.90 0.95 0.95 1.03 1.09 0.98 0.96 1.08 1.07"/>
```

Units are EUR per 1000 litres, or per 1000 pieces for piece goods such as eggs and wool. The comment after each line says where the price comes from (base game, HB, or a base price HB changed) and gives the price in EUR per tonne.

### How the in-game price is calculated

```
sell price = (base price × selling point scale × seasonal factor + random fluctuation) × great demand × difficulty
```

| Term | Meaning |
|---|---|
| **base price** | `price` from the table, i.e. the game's `pricePerLiter` |
| **selling point scale** | the priceScale each selling point sets per fillType in its own xml, e.g. HB bales ×0.8. Override it with `<station>` |
| **seasonal factor** | 12 periods, one per month: period 1 is early spring (March), period 12 is late winter (February). The price at the start of period n is base × factor n; the game interpolates smoothly between periods |
| **random fluctuation** | each selling point has its own sine-shaped fluctuation, at most about ±7% and usually ±2–4%, averaging 0. Cycles last about 2 and 7 days of real time, with occasional flat plateaus |
| **great demand** | occasional temporary price bonus events |
| **difficulty** | HARD ×1, NORMAL ×1.8, EASY ×3. This is why table prices only match the display on HARD |

**Is `price` the average?** Almost always. The year-round average is base × the mean of the 12 seasonal factors. For most base game and HB crops that mean is 1.00–1.02, so `price` is effectively the yearly average. Exceptions:

| fillType | Mean factor | Reason |
|---|---|---|
| Asparagus (ASPARAGUS*) | 0.63–0.87 | off-season factor is 0.01 |
| Grapes, olives, olive oil, rice oil | 0.97 | |
| Root crops (potato, sugar beet, …) | 1.02 | |

To set the yearly average directly, use `average`. The mod sets the base price to `average / mean(factors)`, so the 12 monthly prices average out to exactly your number. The `averagePer1000` column of `priceDump.csv` shows the current yearly average of every fillType.

Without `factors`, the curve of the base game or map is kept. If you give `factors`, list all 12 values, from period 1 to period 12.

### Overriding one selling point

```xml
<station xmlFilename="placeables/sellingStations/animalDealer/sellingStation_animalDealer.xml"
         fillType="SILAGE" priceScale="0.2"/>
```

This replaces that selling point's priceScale for that fillType. `xmlFilename` is matched against the end of the path; the full path of every selling point is listed in `priceDump.csv`.

### Settings

These go in `<settings .../>`:

| Setting | Default | Effect |
|---|---|---|
| `requireHardDifficulty` | true | only apply on HARD; other difficulties would multiply prices by 1.8 or 3 |
| `keepBuyPrices` | true | changed fillTypes keep their original price at buying stations and in consumption costs |
| `rescaleHistory` | true | rescale the saved price history to the new prices |
| `dumpOnStart` | true | write `priceDump.csv` every time a savegame starts |

### Console commands

| Command | Effect |
|---|---|
| `spReload` | re-read `prices.xml` and update every selling point immediately (single player or server) |
| `spDump` | write `modSettings/FS25_SellPrices/priceDump.csv` |

`priceDump.csv` is semicolon-separated and opens in Excel. Its columns are: fillType; title; original price; applied price; yearly average; changed; 12 seasonal factors; the selling points that buy it (name, scale, xml path).

### What changes

The mod changes the fillType definition itself, so all of these follow:

- selling point prices
- production "sell directly"
- the HB farm shop
- bale values
- harvest mission penalties
- the RLRM meat price floor

In addition:

- Buy prices stay unchanged (see `keepBuyPrices`).
- The saved price history is rescaled by the ratio of old to new price. The price used is stored in `economy.xml`, so reloading the savegame never rescales twice.
- The random fluctuation of each selling point is rescaled to the new price.

### Notes

- Table prices only hold on HARD. If you switch difficulty mid-game, prices are multiplied by 1.8 or 3.
- In multiplayer every machine reads its own `prices.xml`, so all copies must match. Selling point prices are synced by the server.
- Maximum unit price is 65.5 EUR/L, a limit of the game's network sync.
- A selling point cannot yet be blocked from buying a fillType; use a very low `priceScale` instead.

### Development

```sh
pip install lupa
python tests/run.py
sh build.sh        # -> ../FS25_SellPrices.zip
```

License: MIT
