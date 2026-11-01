"""The fixture package of conda-purifier.

Its command uses a package from each kind of source the pip: section of
environment.yml has, and numpy from conda.
"""

import os

import docopt
import msgpack
import numpy
import six
from sample.simple import add_one

USAGE = """usage: hello-conda <n>"""


def main():
    args = docopt.docopt(USAGE)
    n = int(args["<n>"])
    packed = msgpack.unpackb(msgpack.packb({"n": n}))
    total = numpy.linalg.inv(numpy.eye(3) * 2).sum()
    greeting = os.environ.get("HELLO_CONDA_GREETING", "no greeting")
    print(
        f"{greeting}: n+1={add_one(packed['n'])} inverse-sum={total} "
        f"six={six.__version__} numpy={numpy.__version__.split('.')[0]}"
    )
