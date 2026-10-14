#!/usr/bin/env python3
"""把 ECDICT（MIT 许可，https://github.com/skywind3000/ECDICT）转换为 Globtype 使用的精简词典。

输出：Sources/Globtype/Resources/dictionary.sqlite
表结构：dict(word TEXT PRIMARY KEY, phonetic TEXT, translation TEXT, tag TEXT, frq INTEGER)

只保留带考试标签（zk gk cet4 cet6 ky toefl ielts gre）或词频排名（frq/bnc）前 5 万的单个英文单词。

用法：
    python3 Scripts/build_dictionary.py                # 自动下载 ecdict.csv 到 build/
    python3 Scripts/build_dictionary.py path/to/ecdict.csv
"""
import csv
import os
import re
import sqlite3
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV_URL = "https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv"
DEFAULT_CSV = os.path.join(ROOT, "build", "ecdict.csv")
OUTPUT = os.path.join(ROOT, "Sources", "Globtype", "Resources", "dictionary.sqlite")
MAX_RANK = 50000
WORD_RE = re.compile(r"^[a-z][a-z'-]*$")


def download(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print(f"下载 {CSV_URL} …")
    try:
        urllib.request.urlretrieve(CSV_URL, path)
    except Exception:
        # python.org 安装的 Python 可能缺少根证书，改用系统 curl
        import subprocess
        subprocess.run(["curl", "-fL", "-o", path, CSV_URL], check=True)


def rank(value):
    try:
        n = int(value or 0)
    except ValueError:
        return 0
    return n


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CSV
    if not os.path.exists(source):
        download(source)

    csv.field_size_limit(10 * 1024 * 1024)
    rows = {}
    with open(source, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            word = (r.get("word") or "").strip()
            key = word.lower()
            if not WORD_RE.match(key):
                continue
            translation = (r.get("translation") or "").strip()
            if not translation:
                continue
            tag = (r.get("tag") or "").strip()
            frq, bnc = rank(r.get("frq")), rank(r.get("bnc"))
            ranks = [x for x in (frq, bnc) if x > 0]
            best = min(ranks) if ranks else 0
            if not tag and not (0 < best <= MAX_RANK):
                continue
            # 同一单词大小写不同的多个词条：保留有标签或词频更高的那个
            prev = rows.get(key)
            if prev and (prev[3] and not tag):
                continue
            rows[key] = (key, (r.get("phonetic") or "").strip(), translation, tag, best)

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    if os.path.exists(OUTPUT):
        os.remove(OUTPUT)
    db = sqlite3.connect(OUTPUT)
    db.execute("CREATE TABLE dict(word TEXT PRIMARY KEY COLLATE NOCASE, phonetic TEXT, translation TEXT, tag TEXT, frq INTEGER)")
    db.executemany("INSERT INTO dict VALUES (?, ?, ?, ?, ?)", rows.values())
    db.commit()
    db.execute("VACUUM")
    db.close()
    size = os.path.getsize(OUTPUT) / 1024 / 1024
    print(f"已写入 {len(rows)} 个词条到 {OUTPUT}（{size:.1f} MB）")


if __name__ == "__main__":
    main()
