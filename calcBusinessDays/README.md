# 営業日計算スクリプト

日本の祝日を考慮した営業日計算を行うPythonスクリプトです。土日と祝日を非営業日として扱い、営業日数の計算や特定の営業日数後の日付を計算することができます。

## 機能

- 指定された期間内の営業日数を計算
- 開始日から指定された営業日数後の日付を計算
- 期間をシフトして新しい終了日を計算

## 前提条件

- 以下がインストールされている
  - Python >3.9.0

## 必要条件

- 以下のPythonパッケージ:
  - jpholiday
  - python-dateutil

## インストール方法

```bash
# リポジトリをクローンまたはダウンロード
git clone https://github.com/hnishim/Calc-Business-Days.git
cd calcBusinessDays

# 端末固有の仮想環境を作成
./setup.sh
```

## 使用方法

### 1. 期間内の営業日数を計算

```bash
./run.sh count --start 2025-05-01 --end 2025-05-10
```

### 2. N営業日後の日付を計算

```bash
./run.sh find_date --start 2025-04-26 --days 5
```

### 3. 期間をシフトして新しい終了日を計算

```bash
./run.sh shift_period --original-start 2025-05-01 --original-end 2025-05-10 --new-start 2025-06-01
```

## 注意事項

- 日付はYYYY-MM-DD形式で入力することを推奨します。
- 営業日数は1以上の整数で指定してください。
- 開始日は終了日以前の日付を指定してください。
- 仮想環境は各Macの `~/Library/Application Support/my.script.calc-business-days` に作成されます。
- `run.sh` は環境がなければ初回実行時に自動構築します。
