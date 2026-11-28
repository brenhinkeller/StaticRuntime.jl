# Programs for another system, built here and checked there. `julia --project=. test/cross/build.jl <triple> <outdir> [sysroot]` makes each program of `CrossPrograms.PROGRAMS` for the
# triple (`target = cross_target(triple; sysroot)`: the sysroot is the `lib` of a glibc for a Linux target, `Glibc_jll`'s artifact for the platform is one) and runs it
# natively (made for the host) to record what it should do: `<outdir>/<name>/{exe,stdout,stderr,status}`. `test/cross/check.jl <outdir>` then runs the programs on a machine of the target
# (a Linux machine, with qemu or a runner of the architecture) and compares. This is for one target, by hand (the sysroot is the one that is given); `test/cross/matrix.jl` does it for every target that a
# machine can make, with what it fetches, and `test/cross/run.jl` the checking: the workflow `cross.yml` runs those two, and nothing in CI runs this script.

using StaticRuntime
include("programs.jl")

function build(triple::AbstractString, outdir::AbstractString, sysroot = nothing)
    target = sysroot === nothing ? cross_target(triple) : cross_target(triple; sysroot)
    built, refused = CrossPrograms.build_programs(target, outdir)
    for name in built; println("built ", name); end
    for (name, why) in refused; println("refused ", name, ": ", why); end
end

length(ARGS) >= 2 || error("usage: julia --project=. test/cross/build.jl <triple> <outdir> [sysroot]")
build(ARGS[1], ARGS[2], length(ARGS) >= 3 ? ARGS[3] : nothing)
