# AGENTS.md

## Python 環境規範

不管執行任何 Python 相關的任務，一律使用專案根目錄下的 `.venv` 虛擬環境。

- 執行 Python 腳本：`.venv/bin/python script.py`
- 安裝套件：`.venv/bin/pip install <package>`
- 執行 pandoc 或其他透過 Python 呼叫的工具，也應確保環境一致

禁止使用系統 Python (`python3`、`python`) 或其他虛擬環境。若 `.venv` 尚未建立，先執行：

```bash
python3 -m venv .venv
```

再繼續後續操作。
