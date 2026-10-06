#!/usr/bin/env python3
"""Re-verify models/catalog.json against the live Hugging Face API (metadata only, no downloads).

For every file in every build it checks that the file still exists in the repo and that its
size and LFS sha256 match the catalog. It also checks the tier budgets, multi-part
completeness and that each tier has exactly one default.

    python3 models/check.py [path/to/catalog.json]

Set HF_TOKEN to avoid anonymous rate limits. Exit code 0 = all good, 1 = mismatch.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

GB = 1e9
TIERS = ("pro", "max", "ultra")
PART = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$")


def fetch_siblings(repo):
    url = f"https://huggingface.co/api/models/{repo}?blobs=true"
    headers = {"User-Agent": "lecore-plus-models-check"}
    if os.environ.get("HF_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["HF_TOKEN"]
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
                return {s["rfilename"]: s for s in json.load(r)["siblings"]}
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog.json")
    with open(path) as fh:
        cat = json.load(fh)
    tiers = cat["tiers"]
    errors, cache, n_files = [], {}, 0
    defaults = {t: [] for t in TIERS}

    for m in cat["models"]:
        mid = m["id"]
        if len(m.get("notes", "")) > 80:
            errors.append(f"{mid}: notes longer than 80 chars")
        for t in m.get("default_for", []):
            defaults[t].append(mid)
            if not m["builds"].get(t):
                errors.append(f"{mid}: default_for {t} but no {t} build")
        for tier in TIERS:
            b = m["builds"].get(tier)
            if b is None:
                continue
            repo = b["repo"]
            if repo not in cache:
                try:
                    cache[repo] = fetch_siblings(repo)
                except Exception as e:  # noqa: BLE001
                    cache[repo] = None
                    errors.append(f"{repo}: API error {e}")
            sib = cache[repo]
            total = 0
            parts = []
            for f in b["files"]:
                n_files += 1
                total += f["bytes"]
                mp = PART.search(f["path"])
                if mp:
                    parts.append((int(mp.group(1)), int(mp.group(2))))
                if sib is None:
                    continue
                s = sib.get(f["path"])
                if s is None:
                    errors.append(f"{mid}/{tier}: {repo}/{f['path']} no longer exists")
                    continue
                lfs = s.get("lfs") or {}
                if s.get("size") != f["bytes"]:
                    errors.append(f"{mid}/{tier}: {f['path']} size {s.get('size')} != catalog {f['bytes']}")
                if lfs.get("sha256") != f["sha256"]:
                    errors.append(f"{mid}/{tier}: {f['path']} sha256 {lfs.get('sha256')} != catalog {f['sha256']}")
            if parts:
                n = parts[0][1]
                if sorted(p for p, _ in parts) != list(range(1, n + 1)) or any(k != n for _, k in parts):
                    errors.append(f"{mid}/{tier}: incomplete multi-part set {parts}")
            gb = total / GB
            if gb > tiers[tier]["budget_gb"]:
                errors.append(f"{mid}/{tier}: {gb:.2f} GB over budget {tiers[tier]['budget_gb']} GB")
            if tier == "ultra":
                want = "fast" if gb <= tiers["ultra"]["fast_gb"] else "offload"
                if b["speed"] != want:
                    errors.append(f"{mid}/ultra: speed {b['speed']} but {gb:.2f} GB implies {want}")

    for t in TIERS:
        if len(defaults[t]) != 1:
            errors.append(f"tier {t}: expected exactly one default, got {defaults[t]}")

    for e in errors:
        print("FAIL", e)
    print(f"checked {len(cat['models'])} models, {n_files} file entries, {len(cache)} repos: "
          f"{'OK' if not errors else str(len(errors)) + ' problem(s)'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
