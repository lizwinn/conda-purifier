# SPDX-License-Identifier: MIT
"""conda-purifier: lock a conda environment for Nix, and use it offline.

`conda-purifier lock` records every file a conda environment needs in
conda-purifier.lock.json: the conda packages of each platform, and the
packages of the environment's `pip:` section with what their builds need.
`buildCondaProject` (nix/lib/build-conda-project.nix) builds the
environment from that lockfile in the Nix sandbox. `conda-purifier env`,
`run` and `shell` use the same build outside the sandbox.

The wrapper that installs this script sets CONDA_PURIFIER_* variables to
the tools it uses: micromamba, patchelf, the nix-prefetch scripts, the
dynamic linker and glibc version of the package set, and the Nix library.
"""

import argparse
import base64
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
import urllib.request
import zipfile

import yaml

LOCKFILE = "conda-purifier.lock.json"
FORMAT = 1
ENVIRONMENT_FILES = ("environment.yml", "environment.yaml")
CONDA_LOCK_FILE = "conda-lock.yml"
DEFAULT_PLATFORMS = ("linux-64", "linux-aarch64")

MICROMAMBA = os.environ.get("CONDA_PURIFIER_MICROMAMBA", "micromamba")
PATCHELF = os.environ.get("CONDA_PURIFIER_PATCHELF", "patchelf")
DYNAMIC_LINKER = os.environ.get("CONDA_PURIFIER_DYNAMIC_LINKER", "")
GLIBC = os.environ.get("CONDA_PURIFIER_GLIBC", "")
PREFETCH = {
    "git": os.environ.get("CONDA_PURIFIER_PREFETCH_GIT", "nix-prefetch-git"),
    "hg": os.environ.get("CONDA_PURIFIER_PREFETCH_HG", "nix-prefetch-hg"),
    "svn": os.environ.get("CONDA_PURIFIER_PREFETCH_SVN", "nix-prefetch-svn"),
    "bzr": os.environ.get("CONDA_PURIFIER_PREFETCH_BZR", "nix-prefetch-bzr"),
}
NIX_LIB = os.environ.get("CONDA_PURIFIER_NIX_LIB", "")
NIXPKGS = os.environ.get("CONDA_PURIFIER_NIXPKGS", "")

# The CPU names of conda subdirs, as they appear in wheel platform tags.
WHEEL_ARCH = {
    "linux-64": "x86_64",
    "linux-aarch64": "aarch64",
    "linux-ppc64le": "ppc64le",
}


class Failure(Exception):
    """An error the user can act on; main() prints it without a traceback."""


def die(message):
    raise Failure(message)


def log(message):
    print(f"conda-purifier: {message}", file=sys.stderr)


def sri(hex_digest, algorithm="sha256"):
    return f"{algorithm}-" + base64.b64encode(bytes.fromhex(hex_digest)).decode()


def host_subdir():
    machine = platform.machine()
    if sys.platform.startswith("linux"):
        return {"x86_64": "linux-64", "aarch64": "linux-aarch64", "ppc64le": "linux-ppc64le"}.get(
            machine, f"linux-{machine}"
        )
    if sys.platform == "darwin":
        return "osx-arm64" if machine == "arm64" else "osx-64"
    die(f"conda-purifier runs on Linux and macOS, not {sys.platform}.")


def vcs_env(work):
    """The environment for commands that may run svn, as pip does.

    git, Mercurial and Bazaar take a proxy from https_proxy, and Subversion
    only from ~/.subversion/servers. With a proxy set, the lock run writes
    that file in its work directory and gives those commands a home there.
    pip keeps its own configuration in the real config directory.
    """
    env = dict(os.environ)
    proxy = env.get("https_proxy") or env.get("HTTPS_PROXY")
    if not proxy:
        return env
    parts = urllib.parse.urlsplit(proxy)
    home = os.path.join(work, "svn-home")
    config = os.path.join(home, ".subversion")
    os.makedirs(config, exist_ok=True)
    lines = ["[global]", f"http-proxy-host = {parts.hostname}", f"http-proxy-port = {parts.port or 80}"]
    if parts.username:
        lines.append(f"http-proxy-username = {urllib.parse.unquote(parts.username)}")
    if parts.password:
        lines.append(f"http-proxy-password = {urllib.parse.unquote(parts.password)}")
    with open(os.path.join(config, "servers"), "w") as f:
        f.write("\n".join(lines) + "\n")
    real_home = os.path.expanduser("~")
    env.setdefault("XDG_CONFIG_HOME", os.path.join(real_home, ".config"))
    env.setdefault("XDG_CACHE_HOME", os.path.join(real_home, ".cache"))
    env["HOME"] = home
    return env


def run(cmd, **kwargs):
    """Runs a command; a failure stops the lock run with its output."""
    result = subprocess.run(cmd, text=True, capture_output=True, **kwargs)
    if result.returncode != 0:
        die(
            f"{' '.join(cmd[:4])} ... failed with exit code {result.returncode}:\n"
            + result.stderr[-4000:]
            + result.stdout[-2000:]
        )
    return result.stdout


def download(url, target):
    """Downloads a URL to a file and returns its SHA-256 as hex."""
    digest = hashlib.sha256()
    request = urllib.request.Request(url, headers={"User-Agent": "conda-purifier"})
    with urllib.request.urlopen(request) as response, open(target, "wb") as out:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
            out.write(chunk)
    return digest.hexdigest()


def basename(url):
    return urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])


# Inputs ------------------------------------------------------------------


def inputs_hash(root, inputs):
    """The hash of the lock's inputs; nix/lib/lock.nix computes the same."""
    text = ""
    for name in inputs:
        # newline="" keeps the bytes builtins.readFile sees.
        with open(os.path.join(root, name), encoding="utf-8", newline="") as f:
            text += name + "\n" + f.read() + "\n"
    return hashlib.sha256(text.encode()).hexdigest()


def lock_hash(lock):
    """The hash of a lockfile without its lockHash; nix/lib/lock.nix computes the same.

    The JSON is the form builtins.toJSON writes: sorted keys, no spaces and
    characters as they are.
    """
    body = {k: v for k, v in lock.items() if k != "lockHash"}
    text = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode()).hexdigest()


def read_lock(root):
    """Reads a project's lockfile, refusing a malformed or edited one."""
    path = os.path.join(root, LOCKFILE)
    try:
        with open(path, encoding="utf-8") as f:
            lock = json.load(f)
    except json.JSONDecodeError as e:
        die(f"{path} is not valid JSON ({e}); run `conda-purifier lock` to write it again.")
    if lock.get("lockHash") != lock_hash(lock):
        die(f"{path} was changed after conda-purifier wrote it; run `conda-purifier lock` to write it again.")
    return lock


def find_source(root, files):
    """Returns (kind, [files]) for what the lock is made from.

    Without --file, a project that has a lockfile is locked again from the
    files it was made from, so `conda-purifier lock` keeps working on an
    environment-dev.yml or on explicit spec files.
    """
    if not files and os.path.exists(os.path.join(root, LOCKFILE)):
        try:
            with open(os.path.join(root, LOCKFILE), encoding="utf-8") as f:
                previous = json.load(f)
            if previous.get("source") == "environment":
                files = previous["inputs"][:1]
            elif previous.get("source") in ("conda-lock", "explicit"):
                files = previous["inputs"]
        except (json.JSONDecodeError, KeyError, OSError):
            files = []
    if files:
        kinds = {source_kind(os.path.join(root, f)) for f in files}
        if len(kinds) > 1:
            die("--file names files of different kinds; pass one environment.yml, one conda-lock.yml, or explicit spec files.")
        kind = kinds.pop()
        if kind != "explicit" and len(files) > 1:
            die(f"--file takes one {kind} file.")
        return kind, list(files)
    if os.path.exists(os.path.join(root, CONDA_LOCK_FILE)):
        return "conda-lock", [CONDA_LOCK_FILE]
    for name in ENVIRONMENT_FILES:
        if os.path.exists(os.path.join(root, name)):
            return "environment", [name]
    die(f"{root} has no {CONDA_LOCK_FILE} or environment.yml; pass --file.")


def previous_platforms(root):
    """The platforms an existing lockfile covers, which a relock keeps."""
    try:
        with open(os.path.join(root, LOCKFILE), encoding="utf-8") as f:
            return sorted(json.load(f).get("platforms", {}))
    except (json.JSONDecodeError, OSError, AttributeError):
        return []


def check_fresh(root, lock):
    """Refuses a lock whose inputs changed, naming them as the project does."""
    if inputs_hash(root, lock["inputs"]) != lock.get("inputsHash"):
        die(f"{', '.join(lock['inputs'])} changed after {LOCKFILE} was written; run `conda-purifier lock` again.")


def source_kind(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if re.search(r"^@EXPLICIT\s*$", text, re.M):
        return "explicit"
    data = yaml.safe_load(text)
    if isinstance(data, dict) and "package" in data and "metadata" in data:
        return "conda-lock"
    return "environment"


# Conda packages ----------------------------------------------------------


def without_token(url):
    """A channel URL without the access token of a private channel.

    anaconda.org and other servers put the token in the path, as
    /t/<token>/. The lockfile is committed, so the token stays out of it;
    the build fetches such a file with credentials of its own (the
    `fetchurl` argument of buildCondaProject).
    """
    return re.sub(r"/t/[^/]+/", "/", url, count=1)


# The URLs with their tokens, which the lock run itself downloads from.
_token_urls: dict[str, str] = {}


def lock_run_url(url):
    return _token_urls.get(url, url)


def conda_entry(url, sha256_hex, name, version):
    public = without_token(url)
    if public != url:
        _token_urls[public] = url
    url = public
    return {
        "name": name,
        "version": version,
        "path": f"pkgs/{basename(url)}",
        "url": url,
        "mirrors": [],
        "hash": sri(sha256_hex),
    }


class Micromamba:
    """micromamba with its own root, package cache and caches."""

    def __init__(self, work):
        self.work = work
        # The user's own conda settings stay out of the lock run, which
        # passes --no-rc for the same reason. micromamba records every
        # environment it creates under ~/.conda; the lock run's environments
        # stay out of the user's home.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CONDA_", "MAMBA_"))}
        self.env.update(
            HOME=os.path.join(work, "home"),
            MAMBA_ROOT_PREFIX=os.path.join(work, "root"),
            CONDA_PKGS_DIRS=os.path.join(work, "pkgs"),
            XDG_CACHE_HOME=os.path.join(work, "cache"),
        )
        os.makedirs(self.env["HOME"], exist_ok=True)

    def solve(self, environment, subdir):
        env = dict(self.env)
        if subdir.startswith("linux-") and GLIBC:
            # The environment runs on the glibc of the Nix package set.
            env.setdefault("CONDA_OVERRIDE_GLIBC", GLIBC)
        out = run(
            [MICROMAMBA, "create", "--yes", "--dry-run", "--json", "--no-rc",
             "--platform", subdir, "--prefix", os.path.join(self.work, "solve", subdir),
             "--file", environment],
            env=env,
        )
        actions = json.loads(out).get("actions", {})
        packages = actions.get("LINK") or actions.get("FETCH") or []
        if not packages:
            die(f"micromamba solved no packages for {subdir}.")
        return [conda_entry(p["url"], p["sha256"], p["name"], p["version"]) for p in packages]

    def create(self, prefix, entries):
        """Creates an environment from locked packages, for the lock run's pip."""
        explicit = self.explicit("host-explicit.txt", entries)
        run([MICROMAMBA, "create", "--yes", "--no-rc", "--prefix", prefix,
             "--file", explicit], env=self.env)
        patch_interpreters(prefix)

    def explicit(self, name, entries):
        """An explicit spec of locked packages, with the URLs the lock run uses."""
        path = os.path.join(self.work, name)
        with open(path, "w") as f:
            f.write("@EXPLICIT\n")
            f.writelines(
                f"{lock_run_url(e['url'])}#sha256:{base64.b64decode(e['hash'].split('-', 1)[1]).hex()}\n"
                for e in entries
            )
        return path

    def programs(self, subdir, entries):
        """The executables a platform's packages put in bin/.

        micromamba downloads and extracts the packages of any platform
        without running them, so the programs of every platform are known.
        """
        explicit = self.explicit(f"programs-{subdir}.txt", entries)
        run([MICROMAMBA, "create", "--yes", "--no-rc", "--download-only",
             "--platform", subdir, "--prefix", os.path.join(self.work, f"programs-{subdir}"),
             "--file", explicit], env=self.env)
        extracted = self.extracted()
        names = set()
        for e in entries:
            stem = re.sub(r"\.(conda|tar\.bz2)$", "", basename(e["url"]))
            key = (lock_run_url(e["url"]), stem)
            if key not in extracted:
                die(f"micromamba did not extract {e['url']}.")
            with open(os.path.join(extracted[key], "info", "paths.json")) as f:
                for p in json.load(f)["paths"]:
                    parts = p["_path"].split("/")
                    if len(parts) == 2 and parts[0] == "bin" and not parts[1].startswith("."):
                        names.add(parts[1])
        return names

    def extracted(self):
        """The extracted packages of micromamba's caches, by URL and name.

        micromamba 2 keeps them under the root prefix, in directories laid
        out after their URLs; older versions keep them flat in
        CONDA_PKGS_DIRS. Each one records its URL in info/repodata_record.json.
        """
        found = {}
        for cache in (os.path.join(self.env["MAMBA_ROOT_PREFIX"], "pkgs"), self.env["CONDA_PKGS_DIRS"]):
            for directory, subdirs, files in os.walk(cache):
                if "info" in subdirs and os.path.exists(os.path.join(directory, "info", "paths.json")):
                    subdirs.clear()
                    record = os.path.join(directory, "info", "repodata_record.json")
                    url = ""
                    if os.path.exists(record):
                        with open(record) as f:
                            url = json.load(f).get("url", "")
                    found[(url, os.path.basename(directory))] = directory
        return found


def patch_interpreters(prefix):
    """Points the ELF files of an environment at the package set's linker.

    conda's binaries name /lib64/ld-linux-*.so.2, which NixOS and the Nix
    sandbox do not have. build-conda-project.nix does the same.
    """
    if not sys.platform.startswith("linux") or not DYNAMIC_LINKER:
        return
    for directory, _, names in os.walk(prefix):
        for name in names:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                if f.read(4) != b"\x7fELF":
                    continue
            probe = subprocess.run([PATCHELF, "--print-interpreter", path], capture_output=True)
            if probe.returncode == 0:
                os.chmod(path, os.stat(path).st_mode | 0o200)
                run([PATCHELF, "--set-interpreter", DYNAMIC_LINKER, path])


# Where the lock run keeps the files it downloads to hash or read them; set
# by cmd_lock for the length of the run.
_download_dir: str = ""


def download_hash(url):
    target = os.path.join(_download_dir, hashlib.sha256(url.encode()).hexdigest())
    return download(url, target)


def verify_md5(url, md5):
    """Downloads a package that is known only by MD5 and returns its SHA-256."""
    target = os.path.join(_download_dir, hashlib.sha256(url.encode()).hexdigest())
    sha = download(url, target)
    with open(target, "rb") as f:
        actual = hashlib.md5(f.read()).hexdigest()
    if actual != md5:
        die(f"{url} has MD5 {actual}, and the spec says {md5}.")
    return sha


def lock_conda_lock(root, name, platforms):
    with open(os.path.join(root, name), encoding="utf-8") as f:
        data = yaml.safe_load(f)
    version = data.get("version")
    if version != 1:
        die(f"{name} is conda-lock format {version}; conda-purifier reads format 1.")
    result = {}
    for p in data["package"]:
        subdir = p["platform"]
        if platforms and subdir not in platforms:
            continue
        target = result.setdefault(subdir, {"conda": [], "pip": [], "pipBuild": []})
        sha = p.get("hash", {}).get("sha256")
        if p["manager"] == "conda":
            if not sha:
                sha = verify_md5(p["url"], p["hash"]["md5"])
            target["conda"].append(conda_entry(p["url"], sha, p["name"], p["version"]))
        elif p["manager"] == "pip":
            if not sha:
                sha = download_hash(p["url"])
            target["pip"].append(pip_file_entry(p["url"], sha, p["name"], p["version"]))
        else:
            die(f"{name}: package {p['name']} has manager {p['manager']}.")
    return result


def lock_explicit(root, names, platforms):
    result = {}
    for name in names:
        subdir = None
        entries = []
        with open(os.path.join(root, name), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                m = re.match(r"#\s*platform:\s*(\S+)", line)
                if m:
                    subdir = m.group(1)
                if not line or line.startswith("#") or line.startswith("@"):
                    continue
                url, _, fragment = line.partition("#")
                if fragment.startswith("sha256:"):
                    sha = fragment[len("sha256:"):]
                elif re.fullmatch(r"[0-9a-f]{64}", fragment):
                    sha = fragment
                elif re.fullmatch(r"[0-9a-f]{32}", fragment):
                    sha = verify_md5(url, fragment)
                else:
                    sha = download_hash(url)
                stem = re.sub(r"\.(conda|tar\.bz2)$", "", basename(url))
                pkg, version, _build = stem.rsplit("-", 2)
                entries.append(conda_entry(url, sha, pkg, version))
        if subdir is None:
            if len(platforms) == 1:
                subdir = platforms[0]
            else:
                die(f"{name} has no '# platform:' line; pass the one --platform it is for.")
        if subdir in result:
            die(f"two explicit spec files are for {subdir}.")
        result[subdir] = {"conda": entries, "pip": [], "pipBuild": []}
    return result


# pip packages ------------------------------------------------------------


def pip_file_entry(url, sha256_hex, name, version):
    return {
        "name": name,
        "version": version,
        "path": f"pip/{basename(url)}",
        "url": url,
        "mirrors": [],
        "hash": sri(sha256_hex),
    }


def prefetch_vcs(vcs, url, rev):
    """Returns (hash, store path) of a checkout, as the Nix fetchers make it."""
    if vcs == "git":
        out = run([PREFETCH["git"], "--quiet", "--url", url, "--rev", rev, "--fetch-submodules"])
        data = json.loads(out)
        return data.get("hash") or nix_sri(data["sha256"]), data["path"]
    if vcs == "svn":
        # nix-prefetch-svn runs svn without a home, so it cannot reach a
        # repository through a proxy. The export below is the one nixpkgs'
        # fetchsvn makes, and its NAR hash is the hash fetchsvn checks.
        work = os.path.dirname(_download_dir)
        target = os.path.join(work, "svn-export-" + hashlib.sha256(f"{url}@{rev}".encode()).hexdigest()[:16])
        if not os.path.exists(target):
            # svn expands keywords such as $Date$ in the local time zone and
            # locale; the sandbox has UTC and no locale archive.
            run(["svn", "export", "--trust-server-cert", "--non-interactive", "--quiet",
                 "-r", rev, url, target], env=dict(vcs_env(work), TZ="UTC", LC_ALL="C"))
        digest = run(["nix", "hash", "path", "--algo", "sha256", target]).strip()
        return digest, target
    if vcs in ("hg", "bzr"):
        # With PRINT_PATH set, these scripts print the hash and then the
        # store path of the checkout.
        result = subprocess.run([PREFETCH[vcs], url, rev], text=True, capture_output=True,
                                env=dict(vcs_env(os.path.dirname(_download_dir)), PRINT_PATH="1"))
        if result.returncode != 0:
            die(f"nix-prefetch-{vcs} {url} {rev} failed:\n{result.stderr[-3000:]}")
        digest, path = result.stdout.split()[:2]
        return nix_sri(digest), path
    die(f"{url} is a {vcs} repository; conda-purifier fetches git, Mercurial, Subversion and Bazaar.")


def nix_sri(digest):
    """Converts a Nix base-32 SHA-256 to SRI."""
    if digest.startswith("sha256-"):
        return digest
    out = run(["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", digest])
    return out.strip()


def wheel_platform_specific(filename):
    if not filename.endswith(".whl"):
        return False
    tags = filename[:-4].split("-")[-1]
    return any(t != "any" for t in tags.split("."))


def pyproject_build_requires(text):
    """The build requirements a pyproject.toml declares, or pip's default."""
    if text is None:
        return ["setuptools>=40.8.0"]
    data = tomllib.loads(text)
    build = data.get("build-system")
    if not build:
        return ["setuptools>=40.8.0"]
    return build.get("requires", [])


def read_pyproject_from_archive(path):
    """Reads the top-level pyproject.toml of an sdist."""
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as z:
                names = [n for n in z.namelist() if n.count("/") == 1 and n.endswith("/pyproject.toml")]
                return z.read(names[0]).decode() if names else None
        with tarfile.open(path) as t:
            for member in t.getmembers():
                if member.name.count("/") == 1 and member.name.endswith("/pyproject.toml"):
                    data = t.extractfile(member)
                    return data.read().decode() if data else None
    except (tarfile.TarError, zipfile.BadZipFile) as e:
        die(f"cannot read {path}: {e}")
    return None


class Pip:
    """pip of the lock run's host environment."""

    def __init__(self, python, cwd, index_options, work):
        self.python = python
        self.cwd = cwd
        self.index_options = index_options
        self.work = work
        self.count = 0

    def report(self, args, isolated=True):
        """What pip would install, as its installation report.

        The pip: section resolves against the conda packages already in the
        environment (isolated=False), so pip adds only what conda does not
        provide. Build requirements and single wheels resolve on their own.
        """
        self.count += 1
        report = os.path.join(self.work, f"report-{self.count}.json")
        isolation = ["--ignore-installed"] if isolated else []
        run([self.python, "-m", "pip", "install", "--disable-pip-version-check", "--dry-run",
             *isolation, "--quiet", "--report", report, *self.index_options, *args],
            cwd=self.cwd, env=vcs_env(self.work))
        with open(report) as f:
            return json.load(f)["install"]

    def python_version(self):
        out = run([self.python, "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"])
        return out.strip()


def index_options_of(lines):
    options = []
    for line in lines:
        for flag in ("--index-url", "-i", "--extra-index-url", "--find-links", "-f"):
            if line.startswith(flag + " ") or line.startswith(flag + "="):
                options.extend(re.split(r"[ =]", line, maxsplit=1))
    return options


def manylinux_tags(subdir):
    arch = WHEEL_ARCH.get(subdir)
    if not arch:
        die(f"conda-purifier resolves pip packages for Linux platforms, not {subdir}.")
    major, minor = (int(x) for x in (GLIBC or "2.17").split("."))
    tags = [f"manylinux_{major}_{m}_{arch}" for m in range(minor, 16, -1)]
    return tags + [f"manylinux2014_{arch}", f"linux_{arch}"]


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None


def lock_pip(root, env_dir, requirements, host_python, host, platforms, work):
    """Locks an environment.yml `pip:` section for every platform."""
    lines = [str(r).strip() for r in requirements]
    reqs = os.path.join(work, "requirements.txt")
    with open(reqs, "w") as f:
        f.write("\n".join(lines) + "\n")
    pip = Pip(host_python, env_dir, index_options_of(lines), work)
    items = pip.report(["-r", reqs], isolated=False)
    pyver = pip.python_version()

    shared = []  # entries every platform shares
    specific = []  # platform-specific wheels, as (name, version, entry)
    pending_builds = []  # the pyproject.toml text of what is built from source
    for item in items:
        name = item["metadata"]["name"]
        version = item["metadata"]["version"]
        info = item["download_info"]
        url = info["url"]
        if "vcs_info" in info:
            vcs = info["vcs_info"]["vcs"]
            rev = info["vcs_info"]["commit_id"]
            digest, path = prefetch_vcs(vcs, url, rev)
            source = {"url": url, "rev": rev}
            if vcs == "git":
                # pip checks out a git requirement's submodules.
                source.update(submodules=True, leaveDotGit=False, commitObject=None)
            shared.append({"name": name, "version": version, "path": f"pip-{vcs}/{name}",
                           "hash": digest, vcs: source})
            pending_builds.append(read_text(os.path.join(path, "pyproject.toml")))
        elif "dir_info" in info or url.startswith("file:"):
            local = urllib.request.url2pathname(urllib.parse.urlsplit(url).path)
            rel = os.path.relpath(local, root)
            if rel.startswith(".."):
                die(f"{name} comes from {local}, outside the project at {root}.")
            shared.append({"name": name, "version": version, "local": rel})
            if os.path.isdir(local):
                pending_builds.append(read_text(os.path.join(local, "pyproject.toml")))
            elif not local.endswith(".whl"):
                pending_builds.append(read_pyproject_from_archive(local))
        else:
            sha = info.get("archive_info", {}).get("hashes", {}).get("sha256") or download_hash(url)
            entry = pip_file_entry(url, sha, name, version)
            if wheel_platform_specific(basename(url)):
                specific.append((name, version, entry))
            else:
                shared.append(entry)
                if not basename(url).endswith(".whl"):
                    target = os.path.join(_download_dir, sha)
                    if not os.path.exists(target):
                        download(url, target)
                    pending_builds.append(read_pyproject_from_archive(target))

    # What the builds from source need, as wheels. pip builds each package
    # in its own isolated environment, so each one's requirements resolve
    # on their own.
    build_shared, build_specific = [], []
    seen = set()
    for text in pending_builds:
        requires = pyproject_build_requires(text)
        if not requires:
            continue
        for b in pip.report(["--only-binary=:all:", *requires]):
            url = b["download_info"]["url"]
            if url in seen:
                continue
            seen.add(url)
            sha = b["download_info"]["archive_info"]["hashes"]["sha256"]
            entry = pip_file_entry(url, sha, b["metadata"]["name"], b["metadata"]["version"])
            if wheel_platform_specific(basename(url)):
                build_specific.append((entry["name"], entry["version"], entry))
            else:
                build_shared.append(entry)

    result = {}
    for subdir in platforms:
        if subdir == host:
            result[subdir] = {
                "pip": shared + [e for _, _, e in specific],
                "pipBuild": build_shared + [e for _, _, e in build_specific],
            }
            continue
        pip_entries = list(shared)
        build_entries = list(build_shared)
        sdist_builds = []
        for name, version, _ in specific:
            entry = foreign_wheel(pip, name, version, subdir, pyver)
            if entry is None:
                # pip builds the package from its sdist on that platform.
                entry, pyproject = sdist_of(pip, name, version)
                sdist_builds.append(pyproject)
            pip_entries.append(entry)
        for name, version, _ in build_specific:
            build_entries.append(required_foreign_wheel(pip, name, version, subdir, pyver))
        for text in sdist_builds:
            for b in pip.report(["--only-binary=:all:", *pyproject_build_requires(text)]):
                url = b["download_info"]["url"]
                name, version = b["metadata"]["name"], b["metadata"]["version"]
                if wheel_platform_specific(basename(url)):
                    build_entries.append(required_foreign_wheel(pip, name, version, subdir, pyver))
                else:
                    sha = b["download_info"]["archive_info"]["hashes"]["sha256"]
                    build_entries.append(pip_file_entry(url, sha, name, version))
        unique = {e["url"]: e for e in build_entries}
        result[subdir] = {"pip": pip_entries, "pipBuild": list(unique.values())}
    return result


def foreign_wheel(pip, name, version, subdir, pyver):
    """The wheel of name==version for another platform, or None."""
    args = ["--only-binary=:all:", "--no-deps", "--python-version", pyver,
            "--implementation", "cp", "--abi", "cp" + pyver.replace(".", "")]
    for tag in manylinux_tags(subdir):
        args += ["--platform", tag]
    try:
        found = pip.report(args + [f"{name}=={version}"])
    except Failure:
        return None
    info = found[0]["download_info"]
    return pip_file_entry(info["url"], info["archive_info"]["hashes"]["sha256"], name, version)


def required_foreign_wheel(pip, name, version, subdir, pyver):
    """The wheel of a build requirement for another platform.

    pip installs build requirements only as wheels here, as it does on
    this machine, so a build requirement needs a wheel for each platform.
    """
    entry = foreign_wheel(pip, name, version, subdir, pyver)
    if entry is None:
        die(f"the build requirement {name} {version} has no wheel for {subdir}.")
    return entry


def sdist_of(pip, name, version):
    """The sdist of name==version, and the pyproject.toml it holds."""
    found = pip.report(["--no-binary", name, "--no-deps", f"{name}=={version}"])
    info = found[0]["download_info"]
    url = info["url"]
    sha = info.get("archive_info", {}).get("hashes", {}).get("sha256")
    target = os.path.join(_download_dir, hashlib.sha256(url.encode()).hexdigest())
    actual = download(url, target)
    if sha and sha != actual:
        die(f"{url} does not match the hash its index gives.")
    return pip_file_entry(url, actual, name, version), read_pyproject_from_archive(target)


def verify_pip(root, env_dir, python, entries, build_entries, work):
    """Installs the pip packages offline from the locked files only."""
    files = os.path.join(work, "verify-files")
    build = os.path.join(work, "verify-build")
    os.makedirs(files, exist_ok=True)
    os.makedirs(build, exist_ok=True)
    targets = []
    for e in entries:
        if "url" in e:
            target = os.path.join(files, basename(e["url"]))
            sha = download(e["url"], target)
            if sri(sha) != e["hash"]:
                die(f"{e['url']} changed while locking.")
            targets.append(target)
        elif "local" in e:
            targets.append(os.path.join(root, e["local"]))
        else:
            vcs = next(k for k in ("git", "hg", "svn", "bzr") if k in e)
            _, path = prefetch_vcs(vcs, e[vcs]["url"], e[vcs]["rev"])
            copy = os.path.join(work, "verify-" + e["name"])
            shutil.copytree(path, copy, dirs_exist_ok=True)
            for d, _, names in os.walk(copy):
                os.chmod(d, 0o755)
                for n in names:
                    p = os.path.join(d, n)
                    if not os.path.islink(p):
                        os.chmod(p, 0o644 | (os.stat(p).st_mode & 0o111))
            targets.append(copy)
    for e in build_entries:
        download(e["url"], os.path.join(build, basename(e["url"])))
    target_dir = os.path.join(work, "verify-target")
    run([python, "-m", "pip", "install", "--disable-pip-version-check", "--quiet", "--no-index",
         "--no-deps", "--no-cache-dir", "--find-links", build, "--target", target_dir, *targets],
        cwd=env_dir, env=dict(os.environ, PIP_CONFIG_FILE=os.devnull))
    # The console scripts of the pip: section are programs of the environment.
    scripts = os.path.join(target_dir, "bin")
    return sorted(os.listdir(scripts)) if os.path.isdir(scripts) else []


# Commands ----------------------------------------------------------------


def cmd_lock(args):
    global _download_dir
    root = os.path.abspath(args.directory)
    kind, inputs = find_source(root, args.file)
    platforms = list(args.platform or previous_platforms(root) or DEFAULT_PLATFORMS)
    host = host_subdir()
    variables = {}
    pip_requirements = []
    env_name = None
    with tempfile.TemporaryDirectory(prefix="conda-purifier-") as work:
        _download_dir = os.path.join(work, "downloads")
        os.makedirs(_download_dir)
        mamba = Micromamba(work)
        if kind == "conda-lock":
            found = lock_conda_lock(root, inputs[0], args.platform)
        elif kind == "explicit":
            found = lock_explicit(root, inputs, platforms)
        else:
            path = os.path.join(root, inputs[0])
            with open(path, encoding="utf-8") as f:
                environment = yaml.safe_load(f) or {}
            variables = {k: str(v) for k, v in (environment.get("variables") or {}).items()}
            env_name = environment.get("name")
            for dep in environment.get("dependencies") or []:
                if isinstance(dep, dict):
                    section = dep.get("pip") or []
                    pip_requirements += section
                    # A requirements file the section includes is an input
                    # of the lock too.
                    inputs += [
                        os.path.relpath(os.path.join(os.path.dirname(path), str(r).split(None, 1)[1]), root)
                        for r in section if str(r).startswith("-r ")
                    ]
            found = {}
            for subdir in platforms:
                log(f"solving {inputs[0]} for {subdir}")
                found[subdir] = {"conda": mamba.solve(path, subdir), "pip": [], "pipBuild": []}
        if not found:
            die("no packages were locked; check --platform.")
        pip_programs = []
        if kind == "environment" and pip_requirements:
            if host not in found:
                die(f"the environment's pip resolves the pip: section, so --platform must include {host}, the platform of this machine.")
            prefix = os.path.join(work, "host-env")
            log(f"creating the {host} environment to resolve the pip: section")
            mamba.create(prefix, found[host]["conda"])
            python = os.path.join(prefix, "bin", "python")
            if not os.path.exists(python):
                die("the environment has a pip: section but no python.")
            env_dir = os.path.dirname(path)
            log("resolving the pip: section")
            pip_found = lock_pip(root, env_dir, pip_requirements, python, host, list(found), work)
            for subdir in found:
                found[subdir].update(pip_found[subdir])
            log("installing the pip: section offline from the locked files")
            pip_programs = verify_pip(root, env_dir, python, found[host]["pip"], found[host]["pipBuild"], work)
        for subdir, locked in found.items():
            log(f"reading the programs of the {subdir} packages")
            programs = set(mamba.programs(subdir, locked["conda"])) | set(pip_programs)
            locked["programs"] = sorted(programs)
        local_packages = {}
        for locked in found.values():
            for e in locked["pip"]:
                if "local" in e:
                    local_packages[e["name"]] = e["local"]
        outputs = {"packages": local_packages}
        if env_name:
            outputs["name"] = str(env_name)
    lock = {
        "version": FORMAT,
        "source": kind,
        "inputs": inputs,
        "inputsHash": inputs_hash(root, inputs),
        "variables": variables,
        "outputs": outputs,
        "platforms": found,
    }
    lock["lockHash"] = lock_hash(lock)
    with open(os.path.join(root, LOCKFILE), "w") as f:
        json.dump(lock, f, indent=2, sort_keys=True)
        f.write("\n")
    counts = ", ".join(
        f"{s}: {len(p['conda'])} conda, {len(p['pip'])} pip" for s, p in sorted(found.items())
    )
    log(f"wrote {LOCKFILE} ({counts})")


def project_root(start):
    directory = os.path.abspath(start)
    while not os.path.exists(os.path.join(directory, LOCKFILE)):
        parent = os.path.dirname(directory)
        if parent == directory:
            die(f"no {LOCKFILE} in {start} or above; run `conda-purifier lock` first.")
        directory = parent
    return directory


def nix_build(root, attribute, link_name):
    """Builds an output of the project through Nix, rooted under .conda-purifier/."""
    link = os.path.join(root, ".conda-purifier", link_name)
    os.makedirs(os.path.dirname(link), exist_ok=True)
    result = subprocess.run(
        ["nix-build", os.path.join(NIX_LIB, "interactive.nix"), "--attr", attribute,
         "--arg", "nixpkgs", NIXPKGS, "--argstr", "projectDir", root, "--out-link", link],
        text=True, capture_output=True,
    )
    if result.returncode != 0:
        die(f"building {attribute} failed:\n" + result.stderr[-4000:])
    return os.path.realpath(link)


def build_env(root):
    # The lockfile's own errors read better here than from Nix.
    check_fresh(root, read_lock(root))
    return nix_build(root, "env", "env")


def activated(root, prefix):
    variables = read_lock(root).get("variables", {})
    env = dict(os.environ)
    env.update(variables)
    env["CONDA_PREFIX"] = prefix
    env["PATH"] = os.path.join(prefix, "bin") + os.pathsep + env.get("PATH", "")
    return env


def cmd_env(args):
    print(build_env(project_root(args.directory)))


def cmd_run(args):
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        die("run takes a command: conda-purifier run -- python ...")
    root = project_root(args.directory)
    prefix = build_env(root)
    os.execvpe(command[0], command, activated(root, prefix))


def cmd_shell(args):
    root = project_root(args.directory)
    prefix = build_env(root)
    shell = os.environ.get("SHELL", "/bin/sh")
    os.execvpe(shell, [shell], activated(root, prefix))


def cmd_publish(args):
    """Uploads the wheels Nix built of the project's own Python packages.

    uv publish uploads them; twine refuses the metadata version (2.5) that
    current build backends such as hatchling write.
    """
    root = project_root(args.directory)
    packages = read_lock(root).get("outputs", {}).get("packages", {})
    names = args.package or sorted(packages)
    if not names:
        die(f"{LOCKFILE} names no packages of the project; the pip: section has no local directories.")
    wheels = []
    for name in names:
        if name not in packages:
            die(f"{name} is not one of the project's packages: {', '.join(sorted(packages))}.")
        built = nix_build(root, f'packages."{name}"', f"package-{name}")
        wheels += [os.path.join(built, w) for w in sorted(os.listdir(built))]
    uv = os.environ.get("CONDA_PURIFIER_UV", "uv")
    os.execvp(uv, [uv, "publish", *args.publish_args, *wheels])


def main(argv=None):
    parser = argparse.ArgumentParser(prog="conda-purifier", description=__doc__.split("\n")[0])
    parser.add_argument("-C", "--directory", default=".", help="the project directory")
    sub = parser.add_subparsers(dest="command_name", required=True)
    lock = sub.add_parser("lock", help=f"write {LOCKFILE}")
    lock.add_argument("--file", "-f", action="append", default=[],
                      help="environment.yml, conda-lock.yml or explicit spec file(s), relative to the project")
    lock.add_argument("--platform", "-p", action="append",
                      help=f"a conda platform to lock for (default: {', '.join(DEFAULT_PLATFORMS)})")
    lock.set_defaults(func=cmd_lock)
    sub.add_parser("env", help="build the environment and print its path").set_defaults(func=cmd_env)
    run_parser = sub.add_parser("run", help="run a command in the environment")
    run_parser.add_argument("command", nargs=argparse.REMAINDER)
    run_parser.set_defaults(func=cmd_run)
    sub.add_parser("shell", help="start $SHELL in the environment").set_defaults(func=cmd_shell)
    publish = sub.add_parser("publish", help="upload the wheels Nix built of the project's packages")
    publish.add_argument("--package", action="append", help="a package to publish (default: all)")
    publish.add_argument("publish_args", nargs=argparse.REMAINDER,
                         help="arguments for `uv publish`, after --")
    publish.set_defaults(func=cmd_publish)
    args = parser.parse_args(argv)
    if getattr(args, "publish_args", None) and args.publish_args[0] == "--":
        args.publish_args = args.publish_args[1:]
    try:
        args.func(args)
    except Failure as e:
        print(f"conda-purifier: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
