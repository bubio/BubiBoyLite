# フェーズ 17: ioctl(TIOCGWINSZ) の可変引数ABIバグ修正(最下部固定の真因)

## 前提

- 依存フェーズ: 16(Now Playingパネル簡素化+最下部固定バグ調査、完了済み)。
- 経緯: フェーズ16でDECSTBMスクロール領域リセットを追加したにもかかわらず、ユーザーの
  実機(macOS Terminal.app、119x44、Apple Silicon Mac)で「コマンドエリアが最下部に
  ならない」問題が再現した(2026-07-19、2枚目のスクリーンショット)。しかも119x41→
  119x44にリサイズしても区切り線の絶対位置がほぼ変わらないという不審な挙動だった。
  フェーズ16のT16-3で見つかっていた「コンパイル済みバイナリからの
  ioctl(TIOCGWINSZ)呼び出しが常に失敗する」という現象を「このサンドボックス固有の
  制約で本番には影響しない」と誤って片付けていたが、**これが真因だった**。

## 根本原因(実機同等環境で再現・特定・修正確認済み)

`src/app/tui_posix.odin` の `ioctl` 宣言:

```odin
foreign libc_ioctl {
	ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}
```

`ioctl` はCの可変引数関数(`int ioctl(int fd, unsigned long request, ...)`)。
Apple Silicon(ARM64/AAPCS64)のABIでは、可変引数呼び出しの可変部分は**必ずスタック
経由**で渡す規約になっており、固定引数として素朴に宣言すると(このABIでは)レジスタ
経由で渡してしまい、実際の `ioctl` 実装(可変引数として `va_arg` でスタックから
読み出す)側とズレて、3番目の引数(`&ws` へのポインタ)が正しく渡らない。結果 `ioctl`
は常に失敗し(`EFAULT`)、`tui_plat_term_size` は常に `ok=false` を返し、
`tui_term_size()` は毎回 `TERM_FALLBACK_COLS=80`/`TERM_FALLBACK_ROWS=24` に
フォールバックしていた。これが「ターミナルの実サイズに関わらずコマンドエリアが
24行目付近で止まる」という現象の直接の原因。

対照実験として、同じ pty で Python の `fcntl.ioctl` は常に正しくサイズを返す
ことも確認済み(pty自体や `TIOCGWINSZ` 定数値・`Winsize` 構造体のレイアウトは
問題ない。FFI宣言の呼び出し規約だけが誤っていた)。

フェーズ16のDECSTBMリセット(`ALT_SCREEN_ENTER`)自体は無害な防御策として残すが、
それだけでは今回の問題は解決しない。**本フェーズの修正が真因への対応。**

## ゴール

`ioctl` の FFI 宣言を可変引数対応に修正し、`tui_plat_term_size` が実際の端末サイズを
常に正しく返すようにする。他の `foreign import` 宣言に同様のバグが無いか横展開で
確認する。フェーズ13〜16のpty回帰確認は、このバグにより実際には常にフォールバック値
(80x24)で動いていた可能性が高いため、複数の実サイズ(80x24、119x41、119x44等)で
再実行し、固定レイアウトが本当に画面最下部まで届くことを直接確認する。

## フェーズ完了の検証コマンド

```sh
odin test tests -collection:bbl=src   # 既存テスト全パス(このバグはSDL/pty非依存の
                                       # 単体テストでは検出できないため新規テストは
                                       # pty経由の直接検証で行う)
./scripts/build_macos.sh --test       # -o:speed ビルド+全テスト成功
```

pty 検証(既知のwinsizeを設定 → 実バイナリ実行 → 返り値が設定値と一致することを
直接確認)を複数サイズ(80x24、119x41、119x44、100x30等)で実施する。

## 修正内容

```odin
foreign libc_ioctl {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}
```

呼び出し側(`tui_plat_term_size`)は `ioctl(c.int(posix.STDOUT_FILENO), c.ulong(TIOCGWINSZ), &ws)`
のまま変更不要。

**なぜ既存の pty 検証(T13〜T16)で見つからなかったか**: いずれも「ioctl 失敗時の
フォールバック挙動」や `printf` によるwinsize事前設定など間接的な手法が中心で、
`tui_plat_term_size` が実際に正しい値を返すかどうかを直接アサートするテストが
無かった(構造的な画面レイアウトの正しさは検証していたが、それが「たまたま
フォールバック値80x24で動いていたから正しく見えていただけ」という可能性を検証時に
確認していなかった)。**今後の教訓**: 疑似端末を使うテストでは、「アプリが実際に
検出したサイズ」を直接アサートする検証を最低1つは用意すること(間接的な構造検証
だけでは、サイズ検出自体が壊れていても気づけない)。

## 追加確認事項(横展開)

1. 他の `foreign import` 宣言に同様の可変引数バグが無いか確認する
2. Linux(aarch64)側でも同じ問題が起き得るため、`#c_vararg` 修正はプラットフォーム
   分岐せず全ビルドに一律適用する(x86_64でも正しい可変引数呼び出しになるだけで
   害はない)

## 壊してはいけない既存資産

- `Winsize` 構造体・`TIOCGWINSZ` 定数値は無変更(レイアウト・値自体は正しいことを
  確認済み)
- opt-none 属性(`tui_plat_term_size` 自体に付与済み)は無変更
- macOS以外のビルド(Linux/Windows)への影響: `foreign import libc_ioctl "system:c"`
  経路(非Darwin)も同じ `ioctl` シグネチャを共有するため同様に修正されるが、
  Windows(`tui_windows.odin`)はこのファイル自体の対象外
  (`#+build linux, darwin, netbsd, openbsd, freebsd` なので無関係)

---

### T17-1: ioctl 宣言を #c_vararg 対応に修正

- [x] 完了

**目的**: ARM64/AAPCS64での可変引数ABIバグを修正し、`tui_plat_term_size` が常に
正しい端末サイズを返すようにする。
**作るもの**: `src/app/tui_posix.odin`:
- `ioctl` 宣言を `proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int`
  に変更、背景をコメントに記録
**参照**: Fableの実機同等環境での検証結果(pty + `fcntl.ioctl(TIOCSWINSZ)` によるサイズ
設定→子プロセス実行→戻り値比較)
**完了条件 (DoD)**: pty検証で複数winsize(80x24、119x41、119x44、100x30)全てで
`tui_term_size()` 相当の呼び出しが設定値と完全一致する値を返すことを直接確認できる。
**検証方法**: pty(既知のwinsizeを設定した状態で一時的なデバッグ計装付きバイナリを
実行し `ok`/`c`/`r` を直接確認、検証後は計装を削除)+ `odin test`
**落とし穴**: 修正前の症状(常に `ok=false`)を対照実験として同じ手法で再現し、
修正前後の違いを明確に記録すること(フェーズ16のT16-3の反省点)。
**依存**: なし

---

### T17-2: 他の foreign import 宣言の横展開チェック

- [x] 完了(該当なし。修正が必要な箇所は見つからなかった)

**目的**: 同種の可変引数ABIバグが他に無いか確認する。
**作るもの**: 調査のみ(`grep -n "foreign" src/app/*.odin` で全 `foreign` ブロックを
洗い出し、可変引数のlibc関数(`fcntl`, `open`(モード可変), `printf`系等)を固定引数で
誤って宣言していないか確認)。
**完了条件 (DoD)**: 調査結果を検証ログに記録する。修正が必要な箇所が見つかった場合は
同様のpty検証を実施した上で修正する。
**検証方法**: grep調査 + (該当があれば)pty検証。
**落とし穴**: `core:sys/posix` 標準パッケージ内の宣言は対象外(Odin本体のメンテナが
管理、今回のバグは自前の `foreign import libc_ioctl` ブロックに限定)。
**依存**: T17-1

---

### T17-3: フェーズ13〜16 の pty 回帰確認を正しいwinsizeで再実行

- [ ] 完了

**目的**: これまでの回帰確認がフォールバック値(80x24)前提で行われていた可能性が
高いため、複数の実サイズで固定レイアウトが本当に機能することを直接確認する。
**作るもの**: 検証のみ(スクラッチパッドのpty検証スクリプトで実施、リポジトリには
含めない)。
**完了条件 (DoD)**: 80x24、119x41、119x44、100x30等の複数サイズで、ホーム画面・
ゲーム中シェルとも区切り線+ステータス行+入力行が正しく画面最下部(rows行目)に
来ることを直接確認する。
**検証方法**: pty(既知のwinsize設定→実バイナリ起動→描画されたコンテンツの最終行
位置を直接検証)。
**落とし穴**: これまでの「pty検証」の多くは構造(区切り線・ステータス行・入力行の
存在、ALT_SCREEN_EXITのタイミング等)を見ていただけで、正確な行位置の一致は
見ていなかった。今回は行位置そのものを検証すること。
**依存**: T17-1

---

### T17-4: 仕上げ(-o:speed/-debug 往復、docs記録)

- [ ] 完了

**目的**: フェーズ17のマイルストーン。
**作るもの**: デバッグと検証のみ。
**完了条件 (DoD)**: `odin test` 全パス + 両ビルド成功 + 複数サイズでのpty最終確認。
実機 macOS Terminal.app での最終確認はユーザー側で実施(残項目として記録)。
**検証方法**: `./scripts/build_macos.sh --test` / `--debug --test` / pty一式。
**落とし穴**: なし。
**依存**: T17-1, T17-2, T17-3

---

## 検証ログ

（タスク完了ごとに 1 行追記）

2026-07-19 T17-1 完了: `odin test tests -collection:bbl=src` 474件全パス(このバグは
SDL/pty非依存の単体テストでは検出できないため新規テストは無し)。`ioctl` 宣言を
`proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int` に変更、背景を
コメントに記録。`./scripts/build_macos.sh`(-o:speed)成功。
pty検証(一時的なデバッグ計装 `fmt.eprintfln("DEBUG tui_term_size: c=%d r=%d ok=%v", ...)`
を `tui_term_size` に追加した検証専用バイナリを2種ビルドし比較。検証後は
`git checkout --`/ファイル復元で完全に削除、コミットへの混入なし):
- **修正前**(コミット053d180時点の固定引数宣言): 80x24, 119x41, 119x44, 100x30 の
  4サイズ全てで `ok=false`(`c=0 r=0`)— サイズによらず常に失敗、フェーズ16のT16-3で
  観測した症状と完全に一致
- **修正後**(`#c_vararg`): 同じ4サイズ全てで `ok=true` かつ返り値が設定値と完全一致
  (例: 119x44指定 → `c=119 r=44 ok=true`)
Fableの実機での発見・検証結果と完全に一致することを本開発環境のpty上でも再現・確認した。

2026-07-19 T17-2 完了: `grep -n "foreign import\|foreign .*{" src/app/*.odin` および
`src/` 全体(core パッケージ含む)を横展開調査した結果、自前の `foreign import` ブロックは
`src/app/tui_posix.odin` の `libc_ioctl`(T17-1で修正済みの `ioctl` 1関数のみ)であることを
確認した。`tui_windows.odin` は Windows API 呼び出しに `core:sys/windows`(Odin公式の
バインディング、`win` エイリアス)を使っており自前の `foreign import` は無い。SDL関連は
`vendor:sdl2`(Odin公式vendorライブラリ)経由でのみ呼び出しており、こちらも自前のFFI
宣言ではない。**結論: T17-1で修正した `ioctl` 以外に同種の可変引数ABIバグは存在しない**
(修正が必要な追加箇所なし)。
