# 授權與第三方聲明

## MoPanel

MoPanel 的原創程式以 GNU General Public License version 3 or later（GPL-3.0-or-later）發佈，完整第 3 版授權文字見 `LICENSE`。下列沿用資料仍依其上游授權與聲明。原始碼、建置腳本及相應修改必須與散佈的 binary 一同提供，或依 GPL 第 6 條提供合規來源取得方式。此交付流程在 App ZIP 內附上 `Source/`。

MoPanel 是獨立、非官方的 Mole 操作介面。Mole 名稱用於說明 CLI 相容性，不表示 tw93 或任何 Mole 商業產品對本程式背書。MoPanel 未採用 Mole 的商標圖案、付費 GUI 圖示或私有素材，App 圖示為原創幾何圖形。

## 官方 Mole CLI

來源：<https://github.com/tw93/Mole>。基準版本 V1.62.0。授權：GPL-3.0。

Mole CLI 由使用者獨立安裝及更新，未隨 MoPanel App bundle 散佈。MoPanel 呼叫外部官方執行檔。預設可勾選的使用者檔案清理與精確 App ID 相關檔案，另以 macOS 原生移至垃圾桶處理；這與 Mole 的官方完整清理／永久刪除模式是不同的操作。命令及資料格式的實作依官方公開介面；公開來源參考與固定 commit 記載於相容性文件。

`Tests/MoPanelCoreTests/Fixtures/help-contract.json` 中的官方 help 文字抽取自 Tw93／Mole contributors 的 V1.62.0 GPL-3.0 來源；該測試資料保留其來源與授權。history fixture 由官方 GPL-3.0 renderer 對合成日誌生成。這些文字與測試輸出僅作相容性驗證，並非隨 App 內建另一套清理核心。

## 第三方 GUI 研究

研究來源：<https://github.com/michaelcspeed/mole-ui>。本程式參考其架構和安全問題，未使用其圖示、品牌素材、Node.js 服務或 Web UI。若未直接複製程式碼，沒有把該 repository 當成 binary 相依；詳細取捨見 `docs/THIRD_PARTY_REVIEW.md`（若該評估文件有列出直接沿用片段，其原授權與著作權聲明亦須保留）。

## SwiftTerm 1.20.0

來源：<https://github.com/migueldeicaza/SwiftTerm/tree/v1.20.0>。

SwiftTerm 用於 AppKit 原生嵌入終端，避免自製不完整 VT 解析器影響官方互動選擇。此為唯一必要的 UI 程式庫相依。已核對 v1.20.0 tag commit 為 `5d14406844143538cd8f8851d2d8a67c1fe443e5`；macOS 建置流程會檢查 SwiftPM 實際解析 revision 並記錄在 `Package.resolved` 和 `Reports/dependencies.json`，目前僅有來源時不可宣稱已完成 dependency build。MIT 授權與 GPL-3.0 相容，原聲明如下。

```text
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## 建置工具相依來源

成功建置的發行包會在 `Source/Vendor` 放入實際 SwiftPM checkout 的完整來源與原始授權。SwiftTerm 的 manifest 還會解析 Swift Argument Parser、Swift DocC plugin 等建置／工具依賴；它們不因出現在 resolver 中就被宣稱連結進 MoPanel。確切來源以 Package.resolved 與各 checkout 授權檔為準。僅原始碼審閱包尚未在 macOS resolve 時，不會假造這些相依下載結果。

## Stats 唯讀 SMC 參考實作

來源：<https://github.com/exelban/stats>，研究版本 `7d3f70dcd6a07177d0a529a1b907021eef740158`，`SMC/smc.swift`。上游 MIT，`Copyright (c) 2019 Serhiy Mytrovtsiy`，完整授權隨附於 `ThirdParty/Stats-LICENSE.txt`。

`Sources/MoPanelApp/NativeSystemReadings.swift` 的 SMC 封包結構、讀取協定與 M1 溫度 key 參考並改寫自該來源。MoPanel 只使用讀取 key 資訊及數值的命令，不包含 SMC 寫入、風扇控制、提權 helper 或 Stats App。記憶體壓力、單一 GPU 使用率、網路介面及 App 程序彙整由 MoPanel 透過 macOS 系統 API 自行實作。這是有限的感測補充，並非整合完整 Stats 模組。

## Apple 系統元件

SwiftUI、AppKit、Charts、SF Symbols 與 Liquid Glass API 為 macOS/Xcode 提供的系統能力，使用須遵循 Apple 的適用條款。MoPanel 沒有把 Apple SDK 或系統 framework 複製進交付內容。

此文件是發行內容盤點，並不宣稱 Apple 公證或 Mole 官方認證。
