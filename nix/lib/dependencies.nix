# SPDX-License-Identifier: MIT
#
# The fetched downloads of a lock, laid out as a tree: each download lies at
# its `path`, as a link to its fixed-output fetch.
#
# The file knows nothing of conda. It takes the download entries of the
# shared purifier library:
#
#   { path, url, mirrors, hash }                          a file
#   { path, git = { url, rev, submodules, leaveDotGit }, hash }
#   { path, hg = { url, rev }, hash }
#   { path, svn = { url, rev }, hash }                    checkouts
{
  lib,
  runCommand,
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  fetchbzr,
  # The download entries.
  downloads,
  # The name of the tree in the store.
  name ? "conda-purifier-dependencies",
}:
let
  # A store name allows fewer characters than a URL; the last segment of
  # the URL, with the rest replaced, keeps the store listing readable.
  storeName =
    url:
    let
      base = lib.last (lib.splitString "/" (builtins.head (lib.splitString "?" url)));
      clean = builtins.replaceStrings [ "%" "@" "~" "!" ] [ "_" "_" "_" "_" ] base;
    in
    if clean == "" then "download" else clean;

  fetch =
    d:
    if d ? url then
      fetchurl {
        urls = [ d.url ] ++ d.mirrors;
        inherit (d) hash;
        name = storeName d.url;
      }
    else if d ? git then
      fetchgit {
        inherit (d.git) url rev;
        fetchSubmodules = d.git.submodules;
        inherit (d.git) leaveDotGit;
        inherit (d) hash;
      }
    else if d ? hg then
      fetchhg {
        inherit (d.hg) url rev;
        inherit (d) hash;
      }
    else if d ? svn then
      fetchsvn {
        inherit (d.svn) url rev;
        inherit (d) hash;
      }
    else if d ? bzr then
      fetchbzr {
        inherit (d.bzr) url rev;
        inherit (d) hash;
      }
    else
      throw "conda-purifier: the download entry for ${d.path} has no url, git, hg, svn or bzr.";
in
runCommand name
  {
    # The tree holds only links.
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "links" ];
    links = lib.concatMapStrings (d: "${d.path}\t${fetch d}\n") downloads;
  }
  ''
    mkdir -p "$out"
    while IFS=$'\t' read -r path target; do
      mkdir -p "$out/$(dirname "$path")"
      ln -s "$target" "$out/$path"
    done < "$linksPath"
  ''
