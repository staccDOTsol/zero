"""leCore+ (Zero) offline defaults for the embedded Python. Imported automatically at startup.

Zero egress: nothing in this Python may try to download at runtime.
  * Hugging Face libraries (not used by leCore today) are put in offline mode.
  * nltk.download() becomes an offline no-op: it reports True when the package is already staged
    (leCore+ pre-stages the corpora leCore references under C:\\Program Files\\leCore+\\nltk_data, see
    NLTK_DATA) and False otherwise, without touching the network.
"""
import os
import sys

for _k in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE"):
    os.environ.setdefault(_k, "1")


def _offline_download(self=None, info_or_id=None, download_dir=None, quiet=False, *args, **kwargs):
    ids = info_or_id if isinstance(info_or_id, (list, tuple)) else [info_or_id]
    try:
        import nltk.data
    except Exception:
        return False
    found = True
    for pkg in ids:
        if pkg is None or not isinstance(pkg, str):
            found = False
            continue
        hit = False
        for cat in ("corpora", "tokenizers", "taggers", "chunkers", "models", "misc", "stemmers", "grammars", "sentiment", "help"):
            for name in (pkg, pkg + ".zip"):
                try:
                    nltk.data.find("%s/%s" % (cat, name))
                    hit = True
                    break
                except LookupError:
                    pass
            if hit:
                break
        if not hit:
            found = False
            if not quiet:
                print("[leCore+] nltk.download(%r) skipped: zero-egress laptop, package not pre-staged" % pkg, file=sys.stderr)
    return found


class _NltkOfflineFinder(object):
    """Patches nltk.downloader right after it is imported (meta path hook, no import of nltk here)."""

    def find_spec(self, fullname, path=None, target=None):
        if fullname != "nltk.downloader":
            return None
        import importlib.machinery
        spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if spec is None or spec.loader is None or not hasattr(spec.loader, "exec_module"):
            return spec
        real_exec = spec.loader.exec_module

        def exec_module(module, _real=real_exec):
            _real(module)
            import types
            module.Downloader.download = _offline_download
            if hasattr(module, "_downloader"):
                module._downloader.download = types.MethodType(_offline_download, module._downloader)
                module.download = module._downloader.download

        spec.loader.exec_module = exec_module
        return spec

    # Python < 3.4 API, unused
    def find_module(self, fullname, path=None):
        return None


sys.meta_path.insert(0, _NltkOfflineFinder())
