#!/bin/bash
cd $(dirname $0)
eval $(opam env)
export OPAMYES=1
export OPAMVERBOSE=1
opam pin add dune --dev
dune build
dune runtest
