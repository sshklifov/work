#!/usr/bin/env python3
"""Mender artifact name prediction and matching for work.vim.

Predicts the artifact name `bitbake <image>` would bake in, given an aidistro
checkout, and scores real artifact names (e.g. the ones :Scan reads off devices
with `mender show-artifact`) against it. Per aidistro:

    MENDER_ARTIFACT_NAME ?= "${IMAGE_BASENAME}_${BUILDNAME}"   # meta-ai/conf/distro/include/mender.inc
    BUILDNAME ?= "${DISTRO_LAYER_VERSION}${DISTRO_LAYER_BUILDTAG}"   # meta-ai/conf/distro/aisys.conf

Both halves come from `git describe --dirty --always` run in the DISTRO_LAYER
(meta-ai) checkout -- see meta-ai/classes/distro_layer_buildinfo.bbclass:

    describe "release-<ver>-<extra...>"  -> version=<ver>,   buildtag=-<extra...>
    describe "<other>-<extra...>"        -> version=<other>, buildtag=-<extra...>
    plus "-$USER" unless USER is jenkins/builder or PRODUCTION_BUILD=1

The branch is not encoded in the name, so anything said about branches comes
from looking the hash up in the checkout, not from the string.

Usage:
    mender_artifact.py                          # what this tree builds now
    mender_artifact.py -i rock-prod-image
    mender_artifact.py -c names.txt             # score a list of real names
    cat names.txt | mender_artifact.py -c -
    ... -c - --tsv                              # "<score>\t<verdict>" per line, for work.vim

The score is a coarse tier, not a computed percentage, and the user weighs more
than the commit: 100 only for a name this tree would produce exactly, 75 for
anything you built off this release line, 50 for someone else's build of your
exact commit, 25 for the same line otherwise, 0 for a different line or nothing
readable.
"""

import argparse
import os
import re
import subprocess
import sys

# Checkouts to look for when --layer is not given, in preference order.
LAYER_CANDIDATES = ("~/aidistro-bd", "~/aidistro")
LAYER_SUBDIR = "layers/meta-ai"
CI_USERS = ("jenkins", "builder")
GHASH_RE = re.compile(r"^g([0-9a-f]{7,40})$")
BARE_HASH_RE = re.compile(r"^[0-9a-f]{7,40}$")

# The five steps the score can take. Coarse on purpose: the inputs are a name
# and a git log, which do not support finer than this. The user is the primary
# axis -- your name on an artifact outranks any commit relation.
TIERS = "exact 100, yours 75, your commit 50, same line 25, unrelated 0"


def default_layer():
    for cand in (os.environ.get("AIDISTRO"), *LAYER_CANDIDATES):
        if not cand:
            continue
        path = os.path.join(os.path.expanduser(cand), LAYER_SUBDIR)
        if os.path.isdir(path):
            return path
    return os.path.join(os.path.expanduser(LAYER_CANDIDATES[0]), LAYER_SUBDIR)


# --------------------------------------------------------------------------
# git plumbing
# --------------------------------------------------------------------------

class Repo:
    def __init__(self, path):
        self.path = path
        self._cache = {}

    def git(self, *args):
        if args not in self._cache:
            try:
                out = subprocess.run(("git",) + args, cwd=self.path, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                self._cache[args] = out.stdout.strip() if out.returncode == 0 else None
            except OSError:
                self._cache[args] = None
        return self._cache[args]

    def describe(self):
        return self.git("describe", "--dirty", "--always") or ""

    def branch(self):
        return self.git("rev-parse", "--abbrev-ref", "HEAD") or "?"

    def head(self):
        return self.git("rev-parse", "--short", "HEAD") or "?"

    def has_commit(self, rev):
        return self.git("cat-file", "-e", "%s^{commit}" % rev) is not None

    def has_tag(self, tag):
        return self.git("rev-parse", "-q", "--verify", "refs/tags/%s" % tag) is not None

    def count(self, a, b):
        out = self.git("rev-list", "--count", "%s..%s" % (a, b))
        return int(out) if out and out.isdigit() else None

    def branches_containing(self, rev):
        """Local branches only -- the origin/ copies say nothing new."""
        out = self.git("branch", "--contains", rev, "--format=%(refname:short)")
        return [b.strip() for b in out.splitlines() if b.strip()] if out else []


# --------------------------------------------------------------------------
# name generation (the bbclass logic, verbatim)
# --------------------------------------------------------------------------

def split_describe(describe):
    """describe string -> (version, buildtag-without-user)."""
    parts = describe.split("-")
    if parts[0] == "release":
        version = parts[1] if len(parts) > 1 else ""
        tag = "-".join(parts[2:])
    else:
        version = parts[0]
        tag = "-".join(parts[1:])
    return version, ("-" + tag if tag else "")


def user_suffix(user, production):
    if user in CI_USERS or production:
        return ""
    return "-" + user


def mender_artifact_name(image, describe, user, production=False):
    version, tag = split_describe(describe)
    return "%s_%s%s%s" % (image, version, tag, user_suffix(user, production))


# --------------------------------------------------------------------------
# name parsing (the inverse, for scoring real names)
# --------------------------------------------------------------------------

class Name:
    """One artifact name, split into its parts."""

    def __init__(self, raw):
        self.raw = raw
        self.basename = self.version = self.user = None
        self.count = self.hash = None
        self.dirty = False
        self.bare_hash = False
        self.ok = False
        self._parse(raw)

    def _parse(self, raw):
        if "_" not in raw:
            return
        self.basename, buildname = raw.split("_", 1)
        toks = buildname.split("-")
        self.version, rest = toks[0], toks[1:]
        i = 0
        # "<count>-g<hash>", the usual describe tail
        if i + 1 < len(rest) and rest[i].isdigit() and GHASH_RE.match(rest[i + 1]):
            self.count = int(rest[i])
            self.hash = GHASH_RE.match(rest[i + 1]).group(1)
            i += 2
        elif i < len(rest) and GHASH_RE.match(rest[i]):
            self.hash = GHASH_RE.match(rest[i]).group(1)
            i += 1
        if i < len(rest) and rest[i] == "dirty":
            self.dirty = True
            i += 1
        if i < len(rest):
            self.user = "-".join(rest[i:])
        # a version that is itself a hash means describe --always found no tag
        if self.hash is None and BARE_HASH_RE.match(self.version):
            self.bare_hash = True
        self.ok = bool(self.basename and self.version)

    @property
    def commit(self):
        """The commit this name points at, wherever describe put it."""
        return self.hash or (self.version if self.bare_hash else None)

    def render(self, basename=None):
        tail = ""
        if self.count is not None and self.hash:
            tail += "-%d-g%s" % (self.count, self.hash)
        elif self.hash:
            tail += "-g%s" % self.hash
        if self.dirty:
            tail += "-dirty"
        if self.user:
            tail += "-" + self.user
        return "%s_%s%s" % (basename or self.basename, self.version, tail)


def baseline(describe, user, production):
    """What a tree with this describe would build, as a Name."""
    version, tag = split_describe(describe)
    return Name("x_%s%s%s" % (version, tag, user_suffix(user, production)))


# --------------------------------------------------------------------------
# comparison
# --------------------------------------------------------------------------

def same_commit(a, b):
    if not a or not b:
        return a == b
    n = min(len(a), len(b))
    return a[:n] == b[:n]


def commit_relation(got, base, repo):
    """How got's commit sits relative to HEAD: (relation, behind, ahead).

    relation is one of same / behind / ahead / diverged / unknown / none,
    where "none" means the name carries no commit at all (a build straight off
    a release tag) and "unknown" means the hash is not in this checkout.
    """
    if got.commit is None:
        return "none", 0, 0
    if same_commit(got.commit, base.commit):
        return "same", 0, 0
    if not repo.has_commit(got.commit):
        return "unknown", 0, 0
    behind = repo.count(got.commit, "HEAD") or 0
    ahead = repo.count("HEAD", got.commit) or 0
    if behind and not ahead:
        return "behind", behind, 0
    if ahead and not behind:
        return "ahead", 0, ahead
    return "diverged", behind, ahead


def score(got, base, image, relation):
    """A coarse tier (see TIERS) for "is this a build of my tree?".

    Derived from the facts rather than from weighted fields, with the user
    dominant: your own name on an artifact says more about whose build it is
    than the commit does, so anything you built off your release line outranks
    anyone else's build of your exact commit. The commit relation still splits
    the tiers below that, and shows up in the notes either way.
    """
    if not got.ok:
        return 0
    if (got.basename == image and got.version == base.version
            and got.count == base.count and got.dirty == base.dirty
            and got.user == base.user and relation == "same"):
        return 100
    # A matching commit implies the same line even when the name carries a bare
    # hash instead of a tag.
    same_line = relation == "same" or got.version == base.version
    if got.user == base.user:
        return 75 if same_line else 25
    if relation == "same":
        return 50
    return 25 if same_line else 0


def compare(got, base, repo, image):
    """-> (score, [note, ...]), most telling note first."""
    if not got.ok:
        return 0, ["unparseable -- no '_' separating image basename from build name"]

    relation, behind, ahead = commit_relation(got, base, repo)
    pct = score(got, base, image, relation)
    if pct == 100:
        return pct, ["exact match -- this is what your tree builds now"]

    notes = []

    # --- who built it
    if got.user == base.user:
        notes.append("same user" if got.user else "CI or production build, like yours")
    elif got.user is None:
        notes.append("CI or production build (no user suffix)")
    else:
        notes.append("different user (%s)" % got.user)

    # --- which release line
    if got.version != base.version and not got.bare_hash:
        notes.append("different release line (%s)" % got.version)
        if not repo.has_tag("release-" + got.version):
            notes.append("tag release-%s not in this checkout" % got.version)

    # --- which commit
    if relation == "none":
        notes.append("built straight off tag release-%s, no commits on top" % got.version)
    elif relation == "same":
        notes.append("same commit")
    elif relation == "unknown":
        notes.append("commit %s not in this checkout" % got.commit)
    elif relation == "behind":
        notes.append("%d commit%s behind your HEAD" % (behind, "s" if behind > 1 else ""))
    elif relation == "ahead":
        notes.append("%d commit%s ahead of your HEAD" % (ahead, "s" if ahead > 1 else ""))
    else:
        brs = [b for b in repo.branches_containing(got.commit) if b != repo.branch()]
        notes.append("diverged from your HEAD (+%d/-%d), on %s"
                     % (ahead, behind, ", ".join(brs[:3]) if brs else "no local branch"))

    # --- the rest, in descending usefulness
    if got.bare_hash:
        notes.append("no reachable tag, describe fell back to a bare hash")
    if got.dirty and not base.dirty:
        notes.append("dirty tree")
    elif base.dirty and not got.dirty:
        notes.append("clean tree, yours is dirty")
    elif got.dirty:
        notes.append("dirty tree, like yours")
    if got.basename != image:
        notes.append("different image (%s)" % got.basename)
    if got.count is not None and not got.bare_hash and repo.has_tag("release-" + got.version):
        real = repo.count("release-" + got.version, got.commit)
        if real is not None and real != got.count:
            notes.append("count %d disagrees with release-%s..%s=%d (rewritten history?)"
                         % (got.count, got.version, got.commit, real))

    return pct, notes


# --------------------------------------------------------------------------

def read_lines(source):
    if source == "-":
        return sys.stdin.read().splitlines()
    with open(source) as f:
        return f.read().splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-i", "--image", default="rock-image",
                    help="IMAGE_BASENAME to predict (default: rock-image)")
    ap.add_argument("-l", "--layer", default=None,
                    help="path to the meta-ai layer (default: $AIDISTRO or ~/aidistro-bd)")
    ap.add_argument("-u", "--user", default=os.environ.get("USER", ""),
                    help="pretend this is $USER")
    ap.add_argument("-p", "--production", action="store_true",
                    help="pretend PRODUCTION_BUILD=1 (drops the user suffix)")
    ap.add_argument("-d", "--describe",
                    help="use this 'git describe' output instead of reading the layer")
    ap.add_argument("-c", "--compare", metavar="FILE",
                    help="score artifact names read from FILE ('-' for stdin)")
    ap.add_argument("-t", "--tsv", action="store_true",
                    help="with -c: one '<pct>\\t<verdict>' line per input line")
    args = ap.parse_args()

    repo = Repo(args.layer or default_layer())
    describe = args.describe or repo.describe()
    if not describe:
        sys.exit("cannot 'git describe' %s -- pass --layer or --describe" % repo.path)
    base = baseline(describe, args.user, args.production)
    mine = base.render(args.image)

    if not args.compare:
        print(mine)
        return

    if not args.tsv:
        print("baseline: %s" % mine)
        print("          describe=%s  branch=%s  head=%s  user=%s"
              % (describe, repo.branch(), repo.head(), args.user or "<unset>"))
        print()

    for line in read_lines(args.compare):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # A device with no readable artifact shows up as "-": keep the line
        # slots aligned with the input instead of dropping it.
        if line == "-":
            if args.tsv:
                print("0\tno artifact reported")
            continue
        got = Name(line)
        pct, notes = compare(got, base, repo, args.image)
        if args.tsv:
            # Two notes is what fits a quickfix row; pct carries the rest.
            print("%d\t%s" % (pct, ", ".join(notes[:2])))
            continue
        print(line)
        print("  -> %-52s %3d%%  %s"
              % (base.render(got.basename) if got.ok else mine, pct, ", ".join(notes)))
        print()


if __name__ == "__main__":
    main()
