#!/bin/sh
set -e
./init.sh
./autogen.sh
./configure
make
