"""Pack catalog for Runemind: the core catalog (catalog/packs.json) merged with every grimorio.

Run with `python3 -I lib/catalog.py <command>`. Standard library only; compatible with Python 3.8+.

The core catalog holds the sources, the trusted grimorio owners and the public packs. A grimorio is a
private repo cloned by rune into grimorios/<repo>/ with a grimorio.json listing its packs (same format,
no sources of its own; they may use the core's). In the old single-repo layout this checkout itself has a
grimorio.json and is read as one. RUNEMIND_GRIMORIOS=<dir> replaces both (tests).

A local pack lives in `dir` (a Claude plugin, relative to its repo). Its `skills` list names its own
skills, kept in <dir>/skills/<name>, and upstream skills ({"source": ID, "skills": [...]}) that `sync`
copies from the pinned clone of `sources[ID]` (.vendor/<ID>@<ref>) into <dir>/upstream/<name>. Vendor
packs (core only, Shopify) are a whole cloned repo instead. The Claude marketplace (.claude-plugin/
marketplace.json in this checkout) is generated from the merged catalog; every plugin dir is inside it.

Commands:
  packs [MODE...]       pack ids, one per line (optionally only the given modes)
  table                 one row per pack, fields separated by \\x1f: id, claude_name, mode, link_prefix,
                        count, vendor_dir, vendor_repo, label, description, grimorio, legacy_prefix
  field PACK KEY        a raw field (dotted keys like vendor.repo; objects print as JSON)
  path PACK             absolute directory that every skill link of the pack points into
  count PACK            number of skills in a pack
  skills PACK...        one line per skill: pack, name, absolute path its .agents/skills link points to (TAB separated)
  detect ROOT           packs whose detect rules match the project at ROOT (space separated)
  grimorios             one line per grimorio: name, root, pack ids (TAB separated; packs space separated)
  owners                trusted grimorio owners (GitHub logins), one per line
  sources               one line per source: id, repo, ref, clone dir (TAB separated)
  fetch [--refresh] [--present] [SOURCE...]
                        clone sources at their pinned ref into .vendor (all by default); an existing clone is
                        reused, --refresh re-checks it against the remote tag, --present skips sources never
                        cloned. Exit 3: offline, existing clone kept; exit 4: a source is missing and could not
                        be cloned
  sync [--force] [--present] (PACK...|--all)
                        copy the upstream skills of the packs into <dir>/upstream (needs fetch first; exit 4 if
                        a source is missing; --present skips packs whose sources were never cloned)
  outdated [--present]  sources whose remote has a newer version tag than the pin: id, ref, newest (TAB separated)
  marketplace           print the generated Claude marketplace
  write-marketplace     write it to .claude-plugin/marketplace.json (only when it changed)
  validate              check the core catalog and every grimorio (exit 1 on any problem)
  check-marketplace     check each local pack's .claude-plugin/plugin.json against the catalog
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

LIB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(LIB, "catalog", "packs.json")
VENDOR = os.path.join(LIB, ".vendor")
MARKETPLACE = os.path.join(LIB, ".claude-plugin", "marketplace.json")
GRIMORIO_FILE = "grimorio.json"
MARKET_NAME = "runemind"

ID_RE = re.compile(r"^[a-z0-9-]+$")
SKILL_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
REF_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
VERSION_RE = re.compile(r"^v?(\d+(?:\.\d+)*)$")
VENDOR_DIR_RE = re.compile(r"^[A-Za-z0-9._-]+$")
MODES = ("auto", "manual", "global")
DETECT_LISTS = ("manifest_keys", "manifest_builders", "files", "package_deps", "dirs_all")
DEP_FIELDS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")
SCAN_SKIP = ("node_modules", ".git", ".agents", ".claude")
SCAN_MAX_DEPTH = 3
UPSTREAM = "upstream"
UPSTREAM_SKILLS = "./upstream/"
STAMP = ".stamp"
KEEP = ".gitkeep"
GIT_TIMEOUT = 120
SEP = "\x1f"

OK, OFFLINE, MISSING = 0, 3, 4


class CatalogError(Exception):
    pass


def fail(msg, code=2):
    sys.stderr.write("catalog: %s\n" % msg)
    sys.exit(code)


def warn(msg):
    sys.stderr.write("catalog: %s\n" % msg)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def is_rel_path(p):
    return isinstance(p, str) and p != "" and not os.path.isabs(p) and ".." not in p.replace("\\", "/").split("/")


def is_text(v):
    return isinstance(v, str) and v.strip() != "" and not any(c in v for c in "\n\r\t" + SEP)


class Seen:
    """Names already taken while merging catalogs (pack ids, Claude plugin names, skills, fallbacks)."""

    def __init__(self):
        self.ids, self.names, self.skills, self.fallbacks = set(), set(), {}, []

    def copy(self):
        c = Seen()
        c.ids, c.names, c.skills, c.fallbacks = set(self.ids), set(self.names), dict(self.skills), list(self.fallbacks)
        return c


def validate_packs(packs, root, grimorio, sources, seen):
    """Validate a pack list read from root; tags each pack with _root and _grimorio."""
    if not isinstance(packs, list):
        raise CatalogError("'packs' must be a list")
    for i, p in enumerate(packs):
        where = "packs[%d]" % i
        if not isinstance(p, dict):
            raise CatalogError("%s must be an object" % where)
        pid = p.get("id")
        if not isinstance(pid, str) or not ID_RE.match(pid):
            raise CatalogError("%s: id must match ^[a-z0-9-]+$" % where)
        where = "pack '%s'" % pid
        if pid in seen.ids:
            raise CatalogError("%s: duplicate id" % where)
        seen.ids.add(pid)
        name = p.get("claude_name")
        if not isinstance(name, str) or not ID_RE.match(name):
            raise CatalogError("%s: claude_name must match ^[a-z0-9-]+$" % where)
        if name in seen.names:
            raise CatalogError("%s: duplicate claude_name '%s'" % (where, name))
        seen.names.add(name)
        if p.get("mode") not in MODES:
            raise CatalogError("%s: mode must be one of %s" % (where, ", ".join(MODES)))
        for key in ("label", "description"):
            if not is_text(p.get(key)):
                raise CatalogError("%s: %s must be a non-empty single-line string" % (where, key))
        has_dir, vendor = "dir" in p, p.get("vendor")
        if has_dir == (vendor is not None):
            raise CatalogError("%s: needs exactly one of dir (with skills) or vendor" % where)
        p["_root"], p["_grimorio"] = root, grimorio
        if has_dir:
            validate_skills(p, where, sources, seen.skills)
        else:
            if grimorio:
                raise CatalogError("%s: vendor packs belong to the core catalog" % where)
            if "skills" in p:
                raise CatalogError("%s: vendor packs cannot list skills" % where)
            if not isinstance(vendor, dict) or not isinstance(vendor.get("repo"), str) or not is_rel_path(vendor.get("path")):
                raise CatalogError("%s: vendor needs repo and a relative path" % where)
            if not VENDOR_DIR_RE.match(vendor_name(vendor)) or vendor_name(vendor) in (".", ".."):
                raise CatalogError("%s: cannot derive a vendor directory from repo" % where)
        validate_detect(p, where, seen.fallbacks)
        market = p.get("marketplace")
        if market is not None:
            if not isinstance(market, dict) or not is_text(market.get("description")):
                raise CatalogError("%s: marketplace.description is required" % where)
            if vendor is not None and "source" not in market:
                raise CatalogError("%s: vendor packs need marketplace.source" % where)
            if has_dir and "source" in market:
                raise CatalogError("%s: local packs get their marketplace source from dir" % where)
    return packs


def grimorio_roots():
    """(name, root) of every grimorio to merge, in order."""
    env = os.environ.get("RUNEMIND_GRIMORIOS")
    roots = []
    if env is None and os.path.isfile(os.path.join(LIB, GRIMORIO_FILE)):
        roots.append((os.path.basename(LIB), LIB))
    base = env if env is not None else os.path.join(LIB, "grimorios")
    try:
        entries = sorted(os.listdir(base))
    except OSError:
        entries = []
    for d in entries:
        root = os.path.join(base, d)
        if not d.startswith(".") and os.path.isfile(os.path.join(root, GRIMORIO_FILE)):
            roots.append((d, os.path.abspath(root)))
    return roots


def load_data(strict=False):
    """The merged catalog. A grimorio that fails validation is left out with a warning (strict: exit)."""
    try:
        data = read_json(CATALOG)
    except (OSError, ValueError) as e:
        fail("cannot read %s: %s" % (CATALOG, e))
    seen = Seen()
    try:
        if not isinstance(data, dict):
            raise CatalogError("packs.json must be an object")
        sources = validate_sources(data.get("sources", {}))
        owners = data.get("grimorio_owners", [])
        if not isinstance(owners, list) or not all(isinstance(o, str) and re.match(r"^[A-Za-z0-9-]+$", o) for o in owners):
            raise CatalogError("grimorio_owners must be a list of GitHub logins")
        core = validate_packs(data.get("packs"), LIB, "", sources, seen)
    except CatalogError as e:
        fail(str(e))
    merged, grimorios, problems = [], [], []
    for name, root in grimorio_roots():
        trial = seen.copy()
        try:
            g = read_json(os.path.join(root, GRIMORIO_FILE))
            if not isinstance(g, dict):
                raise CatalogError("%s must be an object" % GRIMORIO_FILE)
            if "sources" in g:
                raise CatalogError("sources belong to the core catalog")
            packs = validate_packs(g.get("packs"), root, name, sources, trial)
        except (OSError, ValueError, CatalogError) as e:
            problems.append("grimorio '%s' left out: %s" % (name, e))
            continue
        seen = trial
        merged.extend(packs)
        grimorios.append({"name": name, "root": root, "packs": [p["id"] for p in packs]})
    if len(seen.fallbacks) > 1:
        fail("only one pack can be the detect fallback (%s)" % ", ".join(seen.fallbacks))
    for msg in problems:
        if strict:
            fail(msg)
        warn(msg)
    return {"sources": sources, "owners": owners, "packs": merged + core, "grimorios": grimorios}


def load():
    return load_data()["packs"]


def validate_sources(sources):
    if not isinstance(sources, dict):
        raise CatalogError("sources must be an object")
    for sid, src in sources.items():
        where = "source '%s'" % sid
        if not ID_RE.match(sid):
            raise CatalogError("%s: id must match ^[a-z0-9-]+$" % where)
        if not isinstance(src, dict) or not isinstance(src.get("repo"), str) or not src["repo"]:
            raise CatalogError("%s: repo is required" % where)
        ref = src.get("ref")
        if not isinstance(ref, str) or not REF_RE.match(ref) or ".." in ref or ref.startswith("-"):
            raise CatalogError("%s: ref must be a tag name" % where)
        if not is_rel_path(src.get("path")):
            raise CatalogError("%s: path must be a relative path inside the repo" % where)
    return sources


def validate_skills(p, where, sources, owners):
    root = p["_root"]
    if not is_rel_path(p["dir"]):
        raise CatalogError("%s: dir must be a relative path inside the repo" % where)
    entries = p.get("skills")
    if not isinstance(entries, list):
        raise CatalogError("%s: skills must be a list" % where)
    listed = []
    for e in entries:
        if isinstance(e, str):
            listed.append(e)
        elif isinstance(e, dict) and set(e) == {"source", "skills"}:
            if e["source"] not in sources:
                raise CatalogError("%s: unknown source '%s'" % (where, e["source"]))
            if not isinstance(e["skills"], list) or not e["skills"]:
                raise CatalogError("%s: skills of source '%s' must be a non-empty list" % (where, e["source"]))
            listed.extend(e["skills"])
        else:
            raise CatalogError("%s: each skills entry is a name or {\"source\", \"skills\"}" % where)
    for s in listed:
        if not isinstance(s, str) or not SKILL_RE.match(s):
            raise CatalogError("%s: skill name %s must be lowercase-hyphenated" % (where, json.dumps(s)))
        if s in owners:
            raise CatalogError("%s: skill '%s' is already in pack '%s'" % (where, s, owners[s]))
        owners[s] = p["id"]
    base = os.path.join(root, p["dir"], "skills")
    for s in own(p):
        if not os.path.isfile(os.path.join(base, s, "SKILL.md")):
            raise CatalogError("%s: own skill '%s' has no %s/skills/%s/SKILL.md" % (where, s, p["dir"], s))
    try:
        present = [d for d in os.listdir(base) if not d.startswith(".") and os.path.isdir(os.path.join(base, d))]
    except OSError:
        present = []
    for d in sorted(set(present) - set(own(p))):
        raise CatalogError("%s: %s/skills/%s is not listed in the pack's skills" % (where, p["dir"], d))


def validate_detect(p, where, fallbacks):
    detect = p.get("detect")
    if detect is None:
        return
    if p["mode"] != "auto":
        raise CatalogError("%s: only auto packs can have detect rules" % where)
    if not isinstance(detect, dict):
        raise CatalogError("%s: detect must be an object" % where)
    for key, val in detect.items():
        if key == "fallback":
            if not isinstance(val, bool):
                raise CatalogError("%s: detect.fallback must be true or false" % where)
            if val:
                fallbacks.append(p["id"])
        elif key in DETECT_LISTS:
            if not isinstance(val, list) or not val or not all(isinstance(v, str) and v for v in val):
                raise CatalogError("%s: detect.%s must be a non-empty list of strings" % (where, key))
            if key in ("files", "dirs_all") and not all(is_rel_path(v) for v in val):
                raise CatalogError("%s: detect.%s must hold relative paths" % (where, key))
        else:
            raise CatalogError("%s: unknown detect rule '%s'" % (where, key))


def find(packs, pid):
    for p in packs:
        if p["id"] == pid:
            return p
    fail("unknown pack '%s'" % pid)


# ---------- skills ----------

def own(p):
    return [e for e in p.get("skills", []) if isinstance(e, str)]


def upstream(p):
    """(source id, skill name) pairs of a pack, in catalog order."""
    return [(e["source"], s) for e in p.get("skills", []) if isinstance(e, dict) for s in e["skills"]]


def vendor_name(vendor):
    name = vendor["repo"].rstrip("/").rsplit("/", 1)[-1]
    return name[:-4] if name.endswith(".git") else name


def vendor_dir(p):
    return os.path.join(VENDOR, vendor_name(p["vendor"])) if "vendor" in p else ""


def link_prefix(p):
    if "vendor" in p:
        return os.path.join(vendor_dir(p), p["vendor"]["path"])
    return os.path.join(p["_root"], p["dir"])


def legacy_prefix(p):
    """Where a grimorio pack lived in the old single-repo layout (links made then point there)."""
    if "vendor" in p or p["_root"] == LIB:
        return ""
    return os.path.join(LIB, p["dir"])


def skill_links(p):
    """(name, absolute link target) for every skill of a pack."""
    if "vendor" in p:
        d = link_prefix(p)
        try:
            entries = sorted(os.listdir(d))
        except OSError:
            return []
        return [(e, os.path.join(d, e)) for e in entries if os.path.isfile(os.path.join(d, e, "SKILL.md"))]
    base = link_prefix(p)
    return ([(s, os.path.join(base, "skills", s)) for s in own(p)]
            + [(s, os.path.join(base, UPSTREAM, s)) for _, s in upstream(p)])


def count(p):
    if "vendor" in p:
        return len(skill_links(p))
    return len(own(p)) + len(upstream(p))


def plugin_source(p):
    market = p.get("marketplace") or {}
    if "source" in market:
        return market["source"]
    return "./" + os.path.relpath(link_prefix(p), LIB).replace(os.sep, "/")


# ---------- sources (fetch, sync, outdated) ----------

def source_dir(sid, src):
    return os.path.join(VENDOR, "%s@%s" % (sid, src["ref"].replace("/", "_")))


def source_ready(sid, src):
    d = source_dir(sid, src)
    return os.path.isdir(os.path.join(d, ".git")) and os.path.isdir(os.path.join(d, src["path"]))


def git(args, cwd=None):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=GIT_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def remote_tag_commit(src):
    ref = src["ref"]
    code, out, _ = git(["ls-remote", src["repo"], "refs/tags/%s" % ref, "refs/tags/%s^{}" % ref])
    if code != 0:
        return None
    shas = dict(reversed(line.split("\t", 1)) for line in out.splitlines() if "\t" in line)
    return shas.get("refs/tags/%s^{}" % ref) or shas.get("refs/tags/%s" % ref) or ""


def rmtree(path):
    shutil.rmtree(path, ignore_errors=True)


def swap_in(new, dest):
    """Atomically-enough replace dest with the directory new (both on the same filesystem)."""
    old = None
    if os.path.lexists(dest):
        old = tempfile.mkdtemp(dir=os.path.dirname(dest), prefix=".old-")
        try:
            os.rename(dest, os.path.join(old, "x"))
        except OSError:
            pass
    try:
        os.rename(new, dest)
    except OSError:
        rmtree(new)  # another run won the race
    if old:
        rmtree(old)


def fetch(sid, src, refresh=False):
    d = source_dir(sid, src)
    have = source_ready(sid, src)
    if have and not refresh:
        return OK
    if have:
        want = remote_tag_commit(src)
        if want is None:
            warn("%s: cannot reach %s; keeping the clone at %s" % (sid, src["repo"], src["ref"]))
            return OFFLINE
        code, head, _ = git(["rev-parse", "HEAD"], cwd=d)
        if code == 0 and head.strip() == want:
            prune_sources(sid, d)
            return OK
    os.makedirs(VENDOR, exist_ok=True)
    tmp = tempfile.mkdtemp(dir=VENDOR, prefix=".clone-")
    code, _, err = git(["-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1",
                        "--branch", src["ref"], src["repo"], os.path.join(tmp, "repo")])
    if code != 0:
        rmtree(tmp)
        lines = err.strip().splitlines()
        warn("%s: cannot clone %s at %s: %s" % (sid, src["repo"], src["ref"], lines[-1] if lines else "git failed"))
        return OFFLINE if have else MISSING
    if not os.path.isdir(os.path.join(tmp, "repo", src["path"])):
        rmtree(tmp)
        raise CatalogError("%s: %s at %s has no '%s' directory" % (sid, src["repo"], src["ref"], src["path"]))
    swap_in(os.path.join(tmp, "repo"), d)
    rmtree(tmp)
    prune_sources(sid, d)
    return OK


def prune_sources(sid, keep):
    """Drop clones of other refs of the same source (they are a cache under .vendor)."""
    try:
        entries = os.listdir(VENDOR)
    except OSError:
        return
    for e in entries:
        path = os.path.join(VENDOR, e)
        if e.startswith(sid + "@") and path != keep and os.path.isdir(path):
            rmtree(path)


def stamp_for(p, sources):
    return "\n".join("%s@%s/%s" % (sid, sources[sid]["ref"], s) for sid, s in upstream(p)) + "\n"


def sync(p, sources, force=False):
    if "dir" not in p:
        return OK
    dest = os.path.join(link_prefix(p), UPSTREAM)
    pairs = upstream(p)
    if not pairs and not os.path.isdir(dest):
        return OK
    stamp = stamp_for(p, sources)
    if not force:
        try:
            with open(os.path.join(dest, STAMP), encoding="utf-8") as f:
                if f.read() == stamp:
                    return OK
        except OSError:
            pass
    missing = sorted({sid for sid, _ in pairs if not source_ready(sid, sources[sid])})
    if missing:
        warn("pack '%s': source %s not fetched (run: python3 -I lib/catalog.py fetch)" % (p["id"], ", ".join(missing)))
        return MISSING
    for sid, s in pairs:
        if not os.path.isfile(os.path.join(source_dir(sid, sources[sid]), sources[sid]["path"], s, "SKILL.md")):
            raise CatalogError("pack '%s': skill '%s' does not exist in %s at %s" % (p["id"], s, sid, sources[sid]["ref"]))
    tmp = tempfile.mkdtemp(dir=link_prefix(p), prefix=".upstream-")
    try:
        for sid, s in pairs:
            shutil.copytree(os.path.join(source_dir(sid, sources[sid]), sources[sid]["path"], s), os.path.join(tmp, s))
        open(os.path.join(tmp, KEEP), "w").close()
        with open(os.path.join(tmp, STAMP), "w", encoding="utf-8") as f:
            f.write(stamp)
        os.chmod(tmp, 0o755)
    except OSError:
        rmtree(tmp)
        raise
    swap_in(tmp, dest)
    return OK


def version_key(tag):
    m = VERSION_RE.match(tag)
    return tuple(int(x) for x in m.group(1).split(".")) if m else None


def newest_tag(src):
    code, out, _ = git(["ls-remote", "--tags", "--refs", src["repo"]])
    if code != 0:
        return None
    tags = [line.split("refs/tags/", 1)[1] for line in out.splitlines() if "refs/tags/" in line]
    tags = [t for t in tags if version_key(t)]
    return max(tags, key=version_key) if tags else ""


# ---------- detection ----------

def manifests(root):
    """Every JSON-object manifest.json up to SCAN_MAX_DEPTH levels below root."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP]
        depth = 0 if dirpath == root else os.path.relpath(dirpath, root).count(os.sep) + 1
        if depth >= SCAN_MAX_DEPTH:
            dirnames[:] = []
        if "manifest.json" in filenames:
            try:
                d = read_json(os.path.join(dirpath, "manifest.json"))
            except (OSError, ValueError):
                continue
            if isinstance(d, dict):
                out.append(d)
    return out


def has_builder(manifest, names):
    """A VTEX IO manifest (vendor + builders object) declaring any of the builders."""
    builders = manifest.get("builders")
    return "vendor" in manifest and isinstance(builders, dict) and any(n in builders for n in names)


def package_deps(root):
    try:
        d = read_json(os.path.join(root, "package.json"))
    except (OSError, ValueError):
        return set()
    deps = set()
    if isinstance(d, dict):
        for field in DEP_FIELDS:
            if isinstance(d.get(field), dict):
                deps.update(d[field])
    return deps


def dep_matches(pattern, deps):
    if pattern.endswith("*"):
        return any(dep.startswith(pattern[:-1]) for dep in deps)
    return pattern in deps


def detect(root, packs):
    root = os.path.abspath(root)
    cache = {}

    def found_manifests():
        if "m" not in cache:
            cache["m"] = manifests(root)
        return cache["m"]

    def deps():
        if "d" not in cache:
            cache["d"] = package_deps(root)
        return cache["d"]

    found, fallback = [], None
    for p in packs:
        rules = p.get("detect") or {}
        if rules.get("fallback"):
            fallback = p["id"]
        hit = (
            ("files" in rules and any(os.path.isfile(os.path.join(root, f)) for f in rules["files"]))
            or ("dirs_all" in rules and all(os.path.isdir(os.path.join(root, d)) for d in rules["dirs_all"]))
            or ("package_deps" in rules and any(dep_matches(x, deps()) for x in rules["package_deps"]))
            or ("manifest_keys" in rules and any(set(rules["manifest_keys"]) <= set(m) for m in found_manifests()))
            or ("manifest_builders" in rules and any(has_builder(m, rules["manifest_builders"]) for m in found_manifests()))
        )
        if hit:
            found.append(p["id"])
    if not found and fallback:
        found.append(fallback)
    return found


# ---------- marketplace ----------

def marketplace(packs):
    return {
        "name": MARKET_NAME,
        "owner": {"name": "Runemind"},
        "description": "Runemind: grimorios de skills que rune graba por tipo de proyecto (generado por rune; no editar)",
        "plugins": [{"name": p["claude_name"], "source": plugin_source(p), "description": p["marketplace"]["description"]}
                    for p in packs if "marketplace" in p],
    }


def write_marketplace(packs):
    text = json.dumps(marketplace(packs), indent=2, ensure_ascii=False) + "\n"
    try:
        with open(MARKETPLACE, encoding="utf-8") as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(MARKETPLACE), exist_ok=True)
    tmp = MARKETPLACE + ".tmp%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, MARKETPLACE)
    return True


def check_marketplace(packs):
    problems = []
    for p in packs:
        if "marketplace" in p and "dir" in p:
            problems.extend(check_plugin(p, p["claude_name"]))
    return problems


def check_plugin(p, name):
    manifest = os.path.join(link_prefix(p), ".claude-plugin", "plugin.json")
    rel = os.path.relpath(manifest, LIB)
    try:
        data = read_json(manifest)
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except (OSError, ValueError) as e:
        return ["cannot read %s: %s" % (rel, e)]
    problems = []
    if data.get("name") != name:
        problems.append("%s: name must be '%s'" % (rel, name))
    if upstream(p):
        if data.get("skills") != UPSTREAM_SKILLS:
            problems.append("%s: needs \"skills\": \"%s\" (the pack has upstream skills)" % (rel, UPSTREAM_SKILLS))
        if not os.path.isfile(os.path.join(link_prefix(p), UPSTREAM, KEEP)):
            problems.append("%s/%s/%s is missing (Claude fails on a missing skills path)" % (p["dir"], UPSTREAM, KEEP))
    elif "skills" in data:
        problems.append("%s: \"skills\" is set but the pack has no upstream skills" % rel)
    return problems


# ---------- main ----------

def flags(args, *names):
    return [a for a in args if a not in names], {n: n in args for n in names}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(__doc__)
        return 0
    cmd, args = argv[0], argv[1:]
    data = load_data(strict=cmd == "validate")
    packs, sources = data["packs"], data["sources"]
    if cmd == "packs":
        for p in packs:
            if not args or p["mode"] in args:
                print(p["id"])
    elif cmd == "table":
        for p in packs:
            print(SEP.join([p["id"], p["claude_name"], p["mode"], link_prefix(p), str(count(p)), vendor_dir(p),
                            p.get("vendor", {}).get("repo", ""), p["label"], p["description"], p["_grimorio"],
                            legacy_prefix(p)]))
    elif cmd == "field" and len(args) == 2:
        val = {k: v for k, v in find(packs, args[0]).items() if not k.startswith("_")}
        for part in args[1].split("."):
            if not isinstance(val, dict) or part not in val:
                return 1
            val = val[part]
        print(val if isinstance(val, str) else json.dumps(val, ensure_ascii=False))
    elif cmd == "path" and len(args) == 1:
        print(link_prefix(find(packs, args[0])))
    elif cmd == "count" and len(args) == 1:
        print(count(find(packs, args[0])))
    elif cmd == "skills" and args:
        for pid in args:
            for name, target in skill_links(find(packs, pid)):
                print("%s\t%s\t%s" % (pid, name, target))
    elif cmd == "detect" and len(args) == 1:
        if not os.path.isdir(args[0]):
            fail("not a directory: %s" % args[0])
        print(" ".join(detect(args[0], packs)))
    elif cmd == "grimorios" and not args:
        for g in data["grimorios"]:
            print("\t".join([g["name"], g["root"], " ".join(g["packs"])]))
    elif cmd == "owners" and not args:
        for o in data["owners"]:
            print(o)
    elif cmd == "marketplace" and not args:
        print(json.dumps(marketplace(packs), indent=2, ensure_ascii=False))
    elif cmd == "write-marketplace" and not args:
        if "RUNEMIND_GRIMORIOS" in os.environ:
            fail("RUNEMIND_GRIMORIOS is set (tests): not writing the real marketplace")
        write_marketplace(packs)
    elif cmd == "sources" and not args:
        for sid, src in sources.items():
            print("\t".join([sid, src["repo"], src["ref"], source_dir(sid, src)]))
    elif cmd == "fetch":
        args, opt = flags(args, "--refresh", "--present")
        for sid in args:
            if sid not in sources:
                fail("unknown source '%s'" % sid)
        status = OK
        try:
            for sid in args or list(sources):
                if opt["--present"] and not source_ready(sid, sources[sid]):
                    continue
                status = max(status, fetch(sid, sources[sid], opt["--refresh"]))
        except CatalogError as e:
            fail(str(e))
        return status
    elif cmd == "sync" and args:
        args, opt = flags(args, "--force", "--all", "--present")
        if opt["--all"] == bool(args):
            fail("sync takes pack ids or --all")
        status = OK
        try:
            for p in packs if opt["--all"] else [find(packs, a) for a in args]:
                if opt["--present"] and not all(source_ready(sid, sources[sid]) for sid, _ in upstream(p)):
                    continue
                status = max(status, sync(p, sources, opt["--force"]))
        except (CatalogError, OSError) as e:
            fail(str(e))
        return status
    elif cmd == "outdated" and args in ([], ["--present"]):
        status = OK
        for sid, src in sources.items():
            if args and not source_ready(sid, src):
                continue
            newest = newest_tag(src)
            if newest is None:
                warn("%s: cannot list tags of %s" % (sid, src["repo"]))
                status = OFFLINE
            elif newest and version_key(src["ref"]) and version_key(newest) > version_key(src["ref"]):
                print("\t".join([sid, src["ref"], newest]))
        return status
    elif cmd == "validate" and not args:
        print("catalog ok (%d packs, %d sources, grimorios: %s)" % (
            len(packs), len(sources), ", ".join(g["name"] for g in data["grimorios"]) or "none"))
    elif cmd == "check-marketplace" and not args:
        problems = check_marketplace(packs)
        for msg in problems:
            sys.stderr.write("marketplace: %s\n" % msg)
        if problems:
            return 1
        print("plugin.json files match the catalog (%d plugins)" % len(marketplace(packs)["plugins"]))
    else:
        fail("unknown command or wrong arguments: %s (see --help)" % " ".join(argv))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
