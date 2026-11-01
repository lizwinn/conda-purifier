# SPDX-License-Identifier: MIT
#
# Reads conda-purifier.lock.json at evaluation time, for one platform. It
# returns
#
#   subdir      the conda platform the build is for, such as linux-64
#   conda       the conda packages, in install order, as file entries
#               { name, version, path, url, mirrors, hash }
#   pip         the packages of the environment's pip: section: file
#               entries, git, hg, svn or bzr checkouts, and local
#               directories of the project ({ name, version, local })
#   pipBuild    the wheels that building the pip: section from source needs
#   programs    the executables the environment has in bin/
#   packages    the project's own Python packages, by name, as their
#               directory relative to the project
#   variables   the environment variables of environment.yml
#   name        the environment's name in environment.yml, or null
#
# The lock is refused when it was changed after conda-purifier wrote it
# (its lockHash covers the rest of the file), and when its inputs
# (environment.yml and the requirement files it includes, conda-lock.yml
# or the explicit spec files) changed since `conda-purifier lock` read them.
{
  lib,
  # The project directory.
  src,
  lockFile,
  # The platform the environment is for, as a nixpkgs platform.
  platform,
}:
let
  lock = lib.importJSON lockFile;
  cpu = platform.parsed.cpu.name;

  subdir =
    if platform.isLinux then
      {
        x86_64 = "linux-64";
        aarch64 = "linux-aarch64";
        powerpc64le = "linux-ppc64le";
      }
      .${cpu} or (throw "conda-purifier: conda has no Linux platform for ${cpu}.")
    else if platform.isDarwin then
      if cpu == "aarch64" then "osx-arm64" else "osx-64"
    else
      throw "conda-purifier: conda environments are for Linux and macOS, not ${platform.system}.";

  # The same text conda-purifier hashes: each input's name and contents.
  inputsHash = builtins.hashString "sha256" (
    lib.concatMapStrings (name: name + "\n" + builtins.readFile (src + "/${name}") + "\n") lock.inputs
  );

  # The lockfile by its name in the project, not by its copy in the store.
  lockName = baseNameOf (toString lockFile);

  locked =
    lock.platforms.${subdir}
      or (throw "conda-purifier: ${lockName} has no packages for ${subdir}; run `conda-purifier lock --platform ${subdir}` together with the other platforms.");
in
if (lock.version or null) != 1 then
  throw "conda-purifier: ${lockName} is format ${
    toString (lock.version or "unknown")
  }; this builder reads format 1. Run `conda-purifier lock` with this version."
else if
  (lock.lockHash or null)
  != builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "lockHash" ]))
then
  throw "conda-purifier: ${lockName} was changed after conda-purifier wrote it; run `conda-purifier lock` to write it again."
else if inputsHash != lock.inputsHash then
  throw "conda-purifier: ${lib.concatStringsSep ", " lock.inputs} changed after ${lockName} was written; run `conda-purifier lock` again."
else
  {
    inherit subdir;
    inherit (locked)
      conda
      pip
      pipBuild
      programs
      ;
    packages = lock.outputs.packages or { };
    name = lock.outputs.name or null;
    variables = lock.variables or { };
  }
