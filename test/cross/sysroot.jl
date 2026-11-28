# The system root for linking programs for Linux: the `lib` of the glibc of the platform (the artifact of `Glibc_jll`, fetched for any host). `julia test/cross/sysroot.jl <arch>` (`aarch64` or `x86_64`)
# writes the directory, in the last line. It makes an environment of its own for `Glibc_jll`.
# (`cross_target(triple; sysroot = :glibc)` is the one of the `Glibc_jll` that the environment has; this is for a version that is not that one: the glibc is the oldest that a program runs on.)

import Pkg
Pkg.activate(temp = true; io = devnull)
# (the version of `Glibc_jll` is the glibc that programs are linked with, and the oldest that they run on: `2.17` for x86_64 and `2.19` for aarch64 are the oldest there are)
length(ARGS) == 2 ? Pkg.add(name = "Glibc_jll", version = ARGS[2]; io = devnull) : Pkg.add("Glibc_jll"; io = devnull)
using Glibc_jll, Pkg.Artifacts, Base.BinaryPlatforms

length(ARGS) in (1, 2) && ARGS[1] in ("aarch64", "x86_64") || error("usage: julia test/cross/sysroot.jl <aarch64|x86_64> [glibc version]")
platform = Platform(ARGS[1], "linux"; libc = "glibc")
toml = joinpath(dirname(dirname(pathof(Glibc_jll))), "Artifacts.toml")
meta = artifact_meta("Glibc", toml; platform)
meta === nothing && error("Glibc_jll has no artifact for $platform")
ensure_artifact_installed("Glibc", meta, toml; platform)
println(artifact_path(Base.SHA1(meta["git-tree-sha1"])))
