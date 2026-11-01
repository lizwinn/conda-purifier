# SPDX-License-Identifier: MIT
#
# The `conda-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildCondaProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    conda-purifier = prev.conda-purifier or { };
  };

}
