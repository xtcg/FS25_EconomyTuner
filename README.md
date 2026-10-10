# FS25_EconomyTuner

[中文](#中文) | [English](#english)

Formerly `FS25_SellPrices`. Since 0.2.0.0: buy prices, harvest yield and seed usage, a default table that works out of the box, per-savegame overrides. 0.3.0.0 adds shop consumable pricing (`<shopItem>`), the `etCheck` / `etInfo` verification commands and the filled-in default table.

---

## 中文

用 XML 表调整 Farming Simulator 25 的农场经济：任意货物（fillType）的卖价、季节曲线、买价，以及任意作物（fruitType）的收获产量和种子用量。本体、地图和其他 mod 的货物和作物都可以，不用改地图文件。

不涉及车辆（价格、维护费、租赁）和动物产出。

### 安装

1. 从 [Releases](https://github.com/xtcg/FS25_EconomyTuner/releases) 下载 `FS25_EconomyTuner.zip`，**不要解压**，直接放进 mods 文件夹。
2. 在存档的 mod 列表里勾选 **Economy Tuner**。

装上即生效：mod 里自带一张默认表（`config/economy.xml`），每次启动都读，随 mod 更新。默认表是本体 1.23.1 + Hof Bergmann 1.5.0.0 Beta2 的价格快照，表里的价格是玩家在游戏里实际看到的价格，**在 EASY、NORMAL、HARD 下都成立**（mod 会把难度倍率除掉，见下面的 `normalizeDifficulty`）。

默认表已按《非草料价格与产量调整方案》（2026-10-04）填好：粮油、甜菜、牛奶售价，粮油产量系数，各作物耗种量，种子（BayWa 成交 300 £/1000 L）和固体化肥（BayWa 成交 350 £/1000 L）买价。草料类售价（青草 16、三叶草 18、干草 20、青贮 44、秸秆 9，£/1000 L）也已写入，产量保持不变；块根和蔬菜产量、肉价未改，详见 `config/economy.xml` 里的注释。

### 自己改：三层覆盖

不要改 mod 里的默认表。自己的改动写进下面的覆盖文件，只写想改的条目，其余沿用下层。优先级从低到高：

| 层 | 位置 | 作用范围 |
|---|---|---|
| 1 | mod 内 `config/economy.xml` | 默认表，所有人 |
| 2 | `文档/My Games/FarmingSimulator2025/modSettings/FS25_EconomyTuner/global.xml` | 你所有的存档 |
| 3 | 同目录下 `savegame1.xml`（数字是存档槽号） | 只这一个存档 |
| 4 | 存档文件夹里的 `FS25_EconomyTuner.xml` | 只这一个存档，随存档备份和拷贝走 |

第一次进游戏会自动生成一份带说明的空 `global.xml`。同一货物在高层写了 `price`，就整体替换低层的 `price`/`average`/`scale`；`buy`/`buyScale`、`factors` 同理各自独立覆盖。`<settings>` 里没写的项沿用低层。联机时读服务器上的文件。

改完后重新载入存档，或在开发者控制台（`game.xml` 里设置 `<development><controls>true</controls></development>`，按 `~`）输入 `etReload`，立即生效（单机或服务器）。

### 货物：`<fillType>`

```xml
<fillType name="WHEAT"  price="400"/>     <!-- 卖价：€/1000 L -->
<fillType name="WHEAT"  average="400"/>   <!-- 全年平均卖价：€/1000 L -->
<fillType name="SILAGE" scale="0.5"/>     <!-- 在原价基础上乘系数 -->
<fillType name="MILK"   price="500" factors="1.06 1.01 0.96 0.90 0.95 0.95 1.03 1.09 0.98 0.96 1.08 1.07"/>
<fillType name="SEEDS"  buy="1200"/>      <!-- 买价：€/1000 L -->
<fillType name="FERTILIZER" buyScale="0.8"/>
```

单位是 € 每 1000 升；按件计的货物（鸡蛋、羊毛等）是 € 每 1000 件。

- `price` / `average` / `scale` 三选一，设定卖价。`factors` 是 12 个季节系数，不写则沿用原曲线。
- `buy` / `buyScale` 二选一，设定**买价**：买入站（种子、化肥、柴油等）的价格，以及播种、施肥、加油的消耗成本。不写时，改过卖价的货物买价仍保持游戏原价（`keepBuyPrices`）。
- 买价和卖价共用 `pricePerLiter`，所以买价通过额外的换算实现，不会影响卖价。

### 商店消耗品跟随市价：`<shopItem>`

商店（P 键）里的消耗品是固定标价，例如小麦大袋 1500 £/1000 L、青贮草捆 598、干草草捆 192。`<shopItem>` 让它们的单价随市场走：

```xml
<shopItem xmlFilename="objects/buyableBales/buyableBales_silage.xml" fillType="SILAGE"/>
```

单价 = 容量（L）÷ 1000 × **当月最高收购价** × `markup`（默认 1）。

- `basis="best"`（默认）：所有收购点里这种货物当月出价最高的那个（基础价 × 该点倍率 × 当前月份的季节系数，含难度，不含随机波动、大订单、压价）。没有任何收购点收这种货物时，保持游戏原价。
- `basis="market"`：货物自身的当月卖价，不乘收购点倍率。
- `price="N"`（固定价，不需要 fillType）：每 1000 L 固定 N，全年不变，不受月份、收购点和难度影响。
- 同一个月内价格不变，换月才变；一次买多件（2 到 8 件）同比缩放。`xmlFilename` 按路径结尾匹配。

默认表包含所有跟动物饲养相关的商店商品：小麦和燕麦大袋（含托盘）、青贮、干草、秸秆草捆（方形和圆形）按当月最高收购价；HB 上没有收购点收的猪饲料、矿物饲料、代乳粉、仔猪料、木屑、鱼饲料、猫粮、狗粮用固定价，锚点是 英国策划价（£/吨）× 农业价格倍率 K_p 2.1603 × 密度，各项的 £/吨 写在 `config/economy.xml` 的注释里（猪料 330、仔猪料 650、矿物饲料 800、代乳粉 1900、木屑 250、鱼饲料 1200、猫粮 1600、狗粮 1000，都是策划假设，不是实时报价）。`etCheck` 会逐项列出实际生效的价格。

不阻止低买高卖：玩家在价格低的月份屯粮、价格高的月份卖掉，是允许的。

### 作物：`<fruitType>`

```xml
<fruitType name="WHEAT" yieldScale="1.2"/>              <!-- 产量 +20% -->
<fruitType name="BARLEY" yield="9000"/>                  <!-- 产量 9000 L/ha -->
<fruitType name="WHEAT" windrowScale="1.2" seedScale="0.8"/>
```

- `yield`（L/ha）或 `yieldScale`：收割产量。游戏里存的是 L/m²，`etDump` 写出的 `yieldDump.csv` 以 L/ha 列出每种作物的原值和现值。
- `windrowScale`：割草、晒干草、秸秆条（windrow）的产量，只对有 windrow 的作物有效。
- `seedScale`：每公顷种子用量。
- 联合收割机产出的秸秆是按谷物比例折算的，不随 `yield` 变；要改秸秆产量用 `windrowScale`。
- 精准农业（PF）的产量潜力基于同一个字段，所以会一起变。

### 游戏里的实际卖价怎么算

```
实际卖价 = (基准价 × 收购点倍率 × 季节系数 + 随机波动) × 大订单倍率 × 难度倍率
```

| 项 | 说明 |
|---|---|
| **基准价** | 表里的 `price`（换算后的 `pricePerLiter`） |
| **收购点倍率** | 每个收购点在自己的 xml 里对每种货物设的 priceScale，例如 HB 的草捆 ×0.8。可以用 `<station>` 改 |
| **季节系数** | 12 个 period，每个对应一个月，period 1 是早春（3 月），period 12 是晚冬（2 月）。period 开始时的价格是 基准价 × 当月系数，期间平滑插值 |
| **随机波动** | 每个收购点各自一条正弦波动，最多约 ±7%，通常 ±2~4%，长期平均 0 |
| **大订单倍率** | 偶尔出现的"大量需求"事件，临时加价 |
| **难度倍率** | 卖价：HARD ×1，NORMAL ×1.8，EASY ×3。买入站同样按这组倍率（柴油和 DEF 除外）；播种、施肥、加油的消耗成本按另一组：HARD ×1，NORMAL ×0.7，EASY ×0.4 |

`normalizeDifficulty`（默认开）会把难度倍率除掉，所以表里写多少，玩家就看到多少。关掉后表里的值按 HARD 价算，EASY/NORMAL 照常乘倍率。

**`price` 是平均价吗？** 大多数情况下接近：全年平均价 = 基准价 × 12 个季节系数的均值，本体和 HB 大部分作物的均值是 1.00~1.02。例外是芦笋（0.63~0.87）、葡萄、橄榄、橄榄油、米糠油（0.97）。想直接按全年平均价定，用 `average`，mod 会算成 `average ÷ 系数均值`。

### 单独改某个收购点

```xml
<station xmlFilename="placeables/sellingStations/animalDealer/sellingStation_animalDealer.xml"
         fillType="SILAGE" priceScale="0.2"/>
```

替换该收购点对这种货物的 priceScale。`xmlFilename` 按路径结尾匹配，完整路径见 `priceDump.csv`。后面的层对同一收购点同一货物的规则会替换前面的。

### 设置项

写在 `<settings .../>` 里：

| 设置 | 默认 | 作用 |
|---|---|---|
| `normalizeDifficulty` | true | 表里的数是最终价格，任何难度下都成立 |
| `keepBuyPrices` | true | 改过卖价的货物，买价仍按原价算 |
| `rescaleHistory` | true | 把存档里的价格历史曲线按新价格等比缩放 |
| `dumpOnStart` | false | 每次进档写一份 `priceDump.csv` 和 `yieldDump.csv` |
| `checkOnStart` | false | 每次进档自动跑一遍 `etCheck` |

### 控制台命令

| 命令 | 作用 |
|---|---|
| `etReload` | 重新读所有层，立即更新价格、收购点和产量（单机或服务器） |
| `etDump` | 写出 `modSettings/FS25_EconomyTuner/priceDump.csv` 和 `yieldDump.csv` |
| `etCheck` | 校验：把表里每一项和正在运行的游戏对照（卖价、买价、季节曲线、产量、耗种量、收购点规则），逐项列出期望值和实际值，结果写进日志和 `etCheck.txt`，控制台只显示失败项 |
| `etInfo 名称` | 查看一种货物或作物：当前价格、原价、季节系数、买价、各收购点价格、产量 |

`priceDump.csv`（分号分隔）：货物名；标题；原价；现价；全年平均价；是否改过；买价；12 个季节系数；收购点（名称、倍率、xml 路径）。`yieldDump.csv`：作物名；原/现产量（L/ha）；原/现 windrow 产量；原/现种子用量；是否改过。

### 影响范围

价格改的是货物本身的定义，所以收购点卖价、生产点"直接出售"、HB 农场商店、草捆估值、收割任务赔偿额、RLRM 的肉价下限都会跟着变。另外：

- 存档里的价格历史按新旧价格的比例缩放，所用价格记在 `economy.xml` 里，反复读档不会重复缩放。也认得旧版 `FS25_SellPrices` 写的记录。
- 收购点的随机波动幅度跟着新价格缩放。

### 注意

- 买价覆盖的路径：买入站（`BuyingStation`）和消耗成本（播种、施肥、加油，`getCostPerLiter`）。直接读 `pricePerLiter` 的少数界面（如加料对话框、牲畜饮水）不受 `buy` 影响，会跟卖价走。
- 联机时每台机器读自己的覆盖文件，必须保持一致；收购点价格由服务器同步。
- 单价上限是 65.5 €/L（游戏网络同步的限制）。
- 暂时不能禁止某个收购点收某种货物，只能用很低的 `priceScale` 代替。
- 从 `FS25_SellPrices` 升级：删掉旧 mod，旧的 `modSettings/FS25_SellPrices/prices.xml` 不再被读取，把里面改过的条目搬进新的 `global.xml`（根元素由 `<sellPrices>` 改成 `<economyTuner>`，`requireHardDifficulty` 去掉）。

---

## English

Tunes the farm economy of Farming Simulator 25 from XML tables: sell price, seasonal curve and buy price of any fillType, and harvest yield and seed usage of any fruitType. This works for the base game, the map and other mods, without editing map files.

Vehicles (prices, upkeep, leasing) and animal output are not covered.

### Install

1. Download `FS25_EconomyTuner.zip` from [Releases](https://github.com/xtcg/FS25_EconomyTuner/releases) and put it into your mods folder **without unzipping**.
2. Enable **Economy Tuner** for your savegame.

It works right away: the mod ships a default table (`config/economy.xml`) that is read on every start and updated with the mod. It is a snapshot of base game 1.23.1 and Hof Bergmann 1.5.0.0 Beta2. Table prices are the prices the player sees, and **hold on EASY, NORMAL and HARD** (the mod divides the difficulty multiplier out, see `normalizeDifficulty`).

The default table is filled in according to the non-forage price and yield plan of 2026-10-04: sell prices of grains, oilseeds, sugar beet and milk, yield factors of grains and oilseeds, seed usage per crop, and buy prices of seed (300 per 1000 L at BayWa) and solid fertilizer (350 per 1000 L at BayWa). Forage sell prices (grass 16, clover 18, hay 20, silage 44, straw 9 per 1000 L) are set too with yields unchanged; root-crop and vegetable yields and meat prices are unchanged; see the comments in `config/economy.xml`.

### Your own changes: three override layers

Do not edit the default table. Put your changes into override files, listing only the entries you change; everything else falls through to the layer below. Lowest priority first:

| Layer | Location | Scope |
|---|---|---|
| 1 | `config/economy.xml` inside the mod | defaults, everyone |
| 2 | `Documents/My Games/FarmingSimulator2025/modSettings/FS25_EconomyTuner/global.xml` | all your savegames |
| 3 | `savegame1.xml` in the same folder (the number is the savegame slot) | that savegame only |
| 4 | `FS25_EconomyTuner.xml` inside the savegame folder | that savegame only; travels with savegame backups and copies |

On first start an empty, commented `global.xml` is created. If a higher layer sets `price` for a fillType it replaces the lower layer's `price`/`average`/`scale` as a group; `buy`/`buyScale` and `factors` override independently. Settings you do not list keep the lower layer's value. In multiplayer the server's files are read.

Apply changes by reloading the savegame, or open the developer console (`<development><controls>true</controls></development>` in `game.xml`, then `~`) and type `etReload` (single player or server).

### fillType

```xml
<fillType name="WHEAT"  price="400"/>     <!-- sell price, EUR per 1000 L -->
<fillType name="WHEAT"  average="400"/>   <!-- year-round average sell price, EUR per 1000 L -->
<fillType name="SILAGE" scale="0.5"/>     <!-- multiply the original price -->
<fillType name="MILK"   price="500" factors="1.06 1.01 0.96 0.90 0.95 0.95 1.03 1.09 0.98 0.96 1.08 1.07"/>
<fillType name="SEEDS"  buy="1200"/>      <!-- buy price, EUR per 1000 L -->
<fillType name="FERTILIZER" buyScale="0.8"/>
```

Units are EUR per 1000 litres, or per 1000 pieces for piece goods such as eggs and wool.

- `price` / `average` / `scale`: pick one to set the sell price. `factors` are the 12 seasonal factors; without them the original curve is kept.
- `buy` / `buyScale`: pick one to set the **buy** price: buying stations (seed, fertilizer, diesel, ...) and the running cost of sowing, spraying and refuelling. Without them, a fillType with a changed sell price keeps the game's original buy price (`keepBuyPrices`).
- The game uses one `pricePerLiter` for both directions, so the buy price is implemented as a separate conversion and does not affect the sell price.

### Shop consumables that follow the market: `<shopItem>`

Consumables in the shop (P key) have fixed prices, e.g. wheat big bag 1500 per 1000 L, silage bales 598, hay bales 192. `<shopItem>` makes their unit price follow the market:

```xml
<shopItem xmlFilename="objects/buyableBales/buyableBales_silage.xml" fillType="SILAGE"/>
```

Unit price = capacity (L) / 1000 × **the highest price paid this month** × `markup` (default 1).

- `basis="best"` (default): the selling point that pays the most for the fillType this month (base price × its priceScale × the seasonal factor of the current period, difficulty included, without random fluctuation, great demand or price drop). If no selling point buys the fillType the game price stays.
- `basis="market"`: the fillType's own sell price this month, without selling point scale.
- `price="N"` (fixed, no fillType needed): a fixed N per 1000 L all year, independent of month, selling points and difficulty.
- The price is constant within a month and changes with the month; buying several units (2 to 8) scales along. `xmlFilename` is matched against the end of the path.

The default table covers every animal husbandry item in the shop: wheat and oat big bags (and pallets), silage, hay and straw bales (square and round). Items that no selling point buys on the Hof Bergmann map (pig food, mineral feed, milk powder, piglet food, wood shavings, fish feed, cat food, dog food) get a fixed price instead. Anchor: planning price in GBP per tonne × agricultural price factor K_p 2.1603 × density; the GBP/t values are in the comments of `config/economy.xml` (pig feed 330, piglet feed 650, mineral feed 800, milk replacer 1900, wood shavings 250, fish feed 1200, cat food 1600, dog food 1000), planning assumptions, not quotes. `etCheck` lists the prices actually in effect.

Buying cheap and selling dear is not prevented: stocking up in a low month and selling in a high month is allowed.

### fruitType

```xml
<fruitType name="WHEAT" yieldScale="1.2"/>              <!-- +20% yield -->
<fruitType name="BARLEY" yield="9000"/>                  <!-- 9000 L/ha -->
<fruitType name="WHEAT" windrowScale="1.2" seedScale="0.8"/>
```

- `yield` (L/ha) or `yieldScale`: harvest yield. The game stores L/m²; the `yieldDump.csv` written by `etDump` lists original and applied values in L/ha for every crop.
- `windrowScale`: yield of windrows (mown grass, hay, straw swaths), only for crops that have a windrow.
- `seedScale`: seed usage per ha.
- Combine straw is derived from the grain ratio and does not change with `yield`; use `windrowScale` for straw.
- Precision Farming's yield potential is based on the same field, so it moves along.

### How the in-game price is calculated

```
sell price = (base price × selling point scale × seasonal factor + random fluctuation) × great demand × difficulty
```

| Term | Meaning |
|---|---|
| **base price** | `price` from the table (converted to the game's `pricePerLiter`) |
| **selling point scale** | the priceScale each selling point sets per fillType in its own xml, e.g. HB bales ×0.8. Override it with `<station>` |
| **seasonal factor** | 12 periods, one per month: period 1 is early spring (March), period 12 is late winter (February). The price at the start of period n is base × factor n, smoothly interpolated |
| **random fluctuation** | each selling point has its own sine-shaped fluctuation, at most about ±7% and usually ±2–4%, averaging 0 |
| **great demand** | occasional temporary price bonus events |
| **difficulty** | sell: HARD ×1, NORMAL ×1.8, EASY ×3. Buying stations use the same set (except diesel and DEF); running costs of sowing, spraying and refuelling use another: HARD ×1, NORMAL ×0.7, EASY ×0.4 |

`normalizeDifficulty` (on by default) divides the difficulty multiplier out, so the player sees exactly what the table says. With it off, table values are HARD prices and EASY/NORMAL multiply them as in the base game.

**Is `price` the average?** Almost always: the yearly average is base × the mean of the 12 seasonal factors, which is 1.00–1.02 for most base game and HB crops. Exceptions are asparagus (0.63–0.87) and grapes, olives, olive oil, rice oil (0.97). To set the yearly average directly use `average`; the mod sets the base to `average / mean(factors)`.

### Overriding one selling point

```xml
<station xmlFilename="placeables/sellingStations/animalDealer/sellingStation_animalDealer.xml"
         fillType="SILAGE" priceScale="0.2"/>
```

Replaces that selling point's priceScale for that fillType. `xmlFilename` is matched against the end of the path; full paths are listed in `priceDump.csv`. A rule in a higher layer replaces the same station+fillType rule of a lower layer.

### Settings

These go in `<settings .../>`:

| Setting | Default | Effect |
|---|---|---|
| `normalizeDifficulty` | true | table values are final prices and hold on every difficulty |
| `keepBuyPrices` | true | fillTypes with a changed sell price keep their original buy price |
| `rescaleHistory` | true | rescale the saved price history to the new prices |
| `dumpOnStart` | false | write `priceDump.csv` and `yieldDump.csv` every time a savegame starts |
| `checkOnStart` | false | run `etCheck` every time a savegame starts |

### Console commands

| Command | Effect |
|---|---|
| `etReload` | re-read all layers and update prices, selling points and yields immediately (single player or server) |
| `etDump` | write `modSettings/FS25_EconomyTuner/priceDump.csv` and `yieldDump.csv` |
| `etCheck` | verify: checks every table entry against the running game (sell price, buy price, seasonal curve, yield, seed usage, station rules), lists expected vs actual per entry in the log and `etCheck.txt`, and shows only the failures in the console |
| `etInfo NAME` | show one fillType or fruitType: current price, original price, seasonal factor, buy price, prices at every selling point, yield |

`priceDump.csv` (semicolon-separated): fillType; title; original price; applied price; yearly average; changed; buy price; 12 seasonal factors; selling points (name, scale, xml path). `yieldDump.csv`: fruitType; original/applied yield (L/ha); original/applied windrow yield; original/applied seed usage; changed.

### What changes

The mod changes the fillType definition itself, so selling point prices, production "sell directly", the HB farm shop, bale values, harvest mission penalties and the RLRM meat price floor all follow. In addition:

- The saved price history is rescaled by the ratio of old to new price. The price used is stored in `economy.xml`, so reloading never rescales twice. Markers written by the old `FS25_SellPrices` are understood.
- The random fluctuation of each selling point is rescaled to the new price.

### Notes

- `buy` covers buying stations (`BuyingStation`) and running costs (sowing, spraying, refuelling via `getCostPerLiter`). A few screens that read `pricePerLiter` directly (the refill dialog, animal water) are not covered and follow the sell price.
- In multiplayer every machine reads its own override files, so they must match. Selling point prices are synced by the server.
- Maximum unit price is 65.5 EUR/L, a limit of the game's network sync.
- A selling point cannot yet be blocked from buying a fillType; use a very low `priceScale` instead.
- Upgrading from `FS25_SellPrices`: remove the old mod. The old `modSettings/FS25_SellPrices/prices.xml` is no longer read; move your changed entries into the new `global.xml` (root element `<economyTuner>` instead of `<sellPrices>`, drop `requireHardDifficulty`).

### Development

```sh
pip install lupa
python tests/run.py
sh build.sh        # -> ../FS25_EconomyTuner.zip
```

License: MIT
