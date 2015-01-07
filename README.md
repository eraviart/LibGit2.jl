# LibGit2.jl

Work in Progress LibGit2 bindings for Julia

Adapted from the Ruby's Rugged libgit bindings

[![Build Status](https://travis-ci.org/jakebolewski/LibGit2.jl.svg?branch=master)](https://travis-ci.org/jakebolewski/LibGit2.jl)
[![Build status](https://ci.appveyor.com/api/projects/status/t2pfbamvrps6v53t)](https://ci.appveyor.com/project/jakebolewski/libgit2-jl)
[![Coverage Status](https://img.shields.io/coveralls/jakebolewski/LibGit2.jl.svg)](https://coveralls.io/r/jakebolewski/LibGit2.jl)

## Installation / Testing
LibGit2.jl is tested against the latest release version of
libgit2 (v0.22.0).  To build libgit2 from source you need CMake.  See the
specific build instructions in libgit2's [README](https://github.com/libgit2/libgit2#building-libgit2---using-cmake).

To install and build the package, simply clone the latest master snapshot of the package:

```julia
Pkg.clone("LibGit2")
Pkg.build("LibGit2")
```

The test suite can then be run with:

```julia
Pkg.test("LibGit2")
```
