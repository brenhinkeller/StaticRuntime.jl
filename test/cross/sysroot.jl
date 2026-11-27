# The system root for linking programs for Linux: the `lib` of the glibc of the platform (the artifact of `Glibc_jll`, fetched for any host). `julia test/cross/sysroot.jl <arch>` (`aarch64` or `x86_64`)
# writes the directory, in the last line. It makes an environment of its own for `Glibc_jll`.

import Pkg
Pkg.activate(temp = true; io = devnull)
Pkg.add("Glibc_jll"; io = devnull)
using Glibc_jll, Pkg.Artifacts, Base.BinaryPlatforms

length(ARGS) == 1 && ARGS[1] in ("aarch64", "x86_64") || error("usage: julia test/cross/sysroot.jl <aarch64|x86_64>")
platform = Platform(ARGS[1], "linux"; libc = "glibc")
toml = joinpath(dirname(dirname(pathof(Glibc_jll))), "Artifacts.toml")
meta = artifact_meta("Glibc", toml; platform)
meta === nothing && error("Glibc_jll has no artifact for $platform")
ensure_artifact_installed("Glibc", meta, toml; platform)
println(artifact_path(Base.SHA1(meta["git-tree-sha1"])))
