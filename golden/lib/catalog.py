#!/usr/bin/env python3
"""Catalog helper for the golden-image builds (models/catalog.json -> what goes into a tier's image).

    catalog.py [--catalog FILE] plan TIER              TSV: id repo path name bytes sha256 speed
    catalog.py [--catalog FILE] summary TIER           JSON: models, files, bytes, default id + file
    catalog.py [--catalog FILE] aria2 TIER DIR [--provision-layout]
                                                       aria2c input file (URL, dir=, out=, checksum=sha-256=)
    catalog.py [--catalog FILE] verify TIER DIR [-j N] sha256 + size of every tier file found in DIR
    catalog.py [--catalog FILE] windows-inventory TIER DATA_DIR
                                                       writes DATA_DIR/model.txt + DATA_DIR/models.json in
                                                       the format provision/windows-add-models.ps1 writes

Every model with a build for the tier is included: the golden image ships the whole tier, and the
default is the model whose "default_for" lists the tier.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path):
    with open(path) as f:
        return json.load(f)


def tier_files(cat, tier):
    """[(model, build, file)] for every model with a build for the tier, in catalog order; a file
    shared by two models (same name, same sha256) is listed once."""
    out, seen = [], {}
    for m in cat["models"]:
        b = (m.get("builds") or {}).get(tier)
        if not b:
            continue
        for f in b["files"]:
            name = os.path.basename(f["path"])
            if name in seen:
                if seen[name] != f["sha256"].lower():
                    sys.exit("two different files are both named %s" % name)
                continue
            seen[name] = f["sha256"].lower()
            out.append((m, b, f))
    if not out:
        sys.exit("no model in the catalog has a build for tier %s" % tier)
    return out


def default_for(cat, tier):
    for m in cat["models"]:
        if tier in (m.get("default_for") or []) and (m.get("builds") or {}).get(tier):
            files = [os.path.basename(f["path"]) for f in m["builds"][tier]["files"]]
            first = sorted(files, key=lambda n: (0 if "-00001-of-" in n else 1, files.index(n)))[0]
            return m["id"], first
    sys.exit("no model in the catalog has default_for including %s" % tier)


def sha256_file(path, bufsize=16 << 20):
    h = hashlib.sha256()
    with open(path, "rb", buffering=0) as f:
        while True:
            b = f.read(bufsize)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def cmd_plan(cat, a):
    for m, b, f in tier_files(cat, a.tier):
        print("\t".join([m["id"], b["repo"], f["path"], os.path.basename(f["path"]), str(int(f["bytes"])),
                         f["sha256"].lower(), b.get("speed") or ""]))


def cmd_summary(cat, a):
    files = tier_files(cat, a.tier)
    did, dfile = default_for(cat, a.tier)
    print(json.dumps({
        "tier": a.tier,
        "catalog_updated": cat.get("updated"),
        "models": sorted({m["id"] for m, _, _ in files}, key=[x["id"] for x in cat["models"]].index),
        "files": len(files),
        "bytes": sum(int(f["bytes"]) for _, _, f in files),
        "default": did,
        "default_file": dfile,
    }))


def cmd_aria2(cat, a):
    for m, b, f in tier_files(cat, a.tier):
        print("https://huggingface.co/%s/resolve/main/%s" % (b["repo"], f["path"]))
        if a.provision_layout:  # provision/linux-add-models.sh's cache: <cache>/<repo>/<path>
            d = os.path.join(a.dir, b["repo"], os.path.dirname(f["path"]))
        else:
            d = a.dir
        print("  dir=%s" % d.rstrip("/"))
        print("  out=%s" % os.path.basename(f["path"]))
        print("  checksum=sha-256=%s" % f["sha256"].lower())


def cmd_verify(cat, a):
    files = tier_files(cat, a.tier)
    jobs = []
    bad = 0
    for m, b, f in files:
        p = os.path.join(a.dir, os.path.basename(f["path"]))
        if not os.path.isfile(p):
            print("MISSING  %s  %s" % (m["id"], p), flush=True)
            bad += 1
            continue
        if os.path.getsize(p) != int(f["bytes"]):
            print("SIZE     %s  %s  have %d want %d" % (m["id"], p, os.path.getsize(p), int(f["bytes"])), flush=True)
            bad += 1
            continue
        jobs.append((m["id"], p, f["sha256"].lower(), int(f["bytes"])))
    with concurrent.futures.ProcessPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(sha256_file, p): (mid, p, want, n) for mid, p, want, n in jobs}
        for fu in concurrent.futures.as_completed(futs):
            mid, p, want, n = futs[fu]
            got = fu.result()
            ok = got == want
            bad += 0 if ok else 1
            print("%s  %s  %s  %.2f GB  %s" % ("OK      " if ok else "SHA256  ", mid, os.path.basename(p), n / 1e9, got), flush=True)
    total = sum(int(f["bytes"]) for _, _, f in files)
    print("%s: %d file(s), %d model(s), %.1f GB; %d problem(s)" % (
        "VERIFY OK" if not bad else "VERIFY FAILED", len(files), len({m["id"] for m, _, _ in files}), total / 1e9, bad))
    sys.exit(1 if bad else 0)


def cmd_windows_inventory(cat, a):
    """model.txt + models.json exactly as provision/windows-add-models.ps1 -All <tier> writes them."""
    files = tier_files(cat, a.tier)
    did, dfile = default_for(cat, a.tier)
    os.makedirs(a.data_dir, exist_ok=True)
    with open(os.path.join(a.data_dir, "model.txt"), "w", encoding="utf-8", newline="") as f:
        f.write(dfile + "\r\n")
    inv = {
        "tier": a.tier,
        "default": did,
        "model_txt": dfile,
        "written_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "catalog_updated": cat.get("updated"),
        "models": sorted({m["id"] for m, _, _ in files}, key=[x["id"] for x in cat["models"]].index),
        "files": [{"id": m["id"], "file": os.path.basename(f["path"]), "bytes": int(f["bytes"]),
                   "sha256": f["sha256"].lower()} for m, _, f in files],
    }
    with open(os.path.join(a.data_dir, "models.json"), "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(inv, indent=4).replace("\n", "\r\n"))
    print("model.txt -> %s (%s); models.json: %d models, %d files" % (dfile, did, len(inv["models"]), len(inv["files"])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=os.path.join(HERE, "..", "..", "models", "catalog.json"))
    sp = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "summary"):
        p = sp.add_parser(name)
        p.add_argument("tier", choices=("pro", "max", "ultra"))
    p = sp.add_parser("aria2")
    p.add_argument("tier", choices=("pro", "max", "ultra"))
    p.add_argument("dir")
    p.add_argument("--provision-layout", action="store_true",
                   help="DIR/<repo>/<path>, the cache layout of provision/linux-add-models.sh")
    p = sp.add_parser("verify")
    p.add_argument("tier", choices=("pro", "max", "ultra"))
    p.add_argument("dir")
    p.add_argument("-j", "--jobs", type=int, default=8)
    p = sp.add_parser("windows-inventory")
    p.add_argument("tier", choices=("pro", "max", "ultra"))
    p.add_argument("data_dir")
    a = ap.parse_args()
    cat = load(a.catalog)
    {"plan": cmd_plan, "summary": cmd_summary, "aria2": cmd_aria2, "verify": cmd_verify,
     "windows-inventory": cmd_windows_inventory}[a.cmd](cat, a)


if __name__ == "__main__":
    main()
