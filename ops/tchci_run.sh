#!/bin/bash
# usage: tchci_run.sh <harness.sh> <Dino8>   (SIGPIPE ignored like GitHub's runner)
trap '' PIPE
exec bash "$@"
