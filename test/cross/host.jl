# What this machine can run, and the tools that are fetched for it (the standard library only: `test/cross/run.jl` uses it on machines that have only Julia).
# `include`d by `test/cross/support.jl` (the tests, and `test/cross/matrix.jl`) and by `test/cross/run.jl`.
#
# What is fetched is said by `STATIC_RUNTIME_CROSS_FETCH`: `0` fetches nothing (the cases that need a tool that is not there are skipped, with a message that says so), and `all` fetches everything. Unset, the small things
# (Node.js 24: 50 MB) are fetched, and the large ones (an `llc` of another architecture: 2 GB) only in a run of the cross-compilation tests (`GROUP` is `Cross`, or `All`, which is the default of `Pkg.test`) outside of CI (the environment
# variable `CI` is not set): that is the one place where it is wanted by default.

import Pkg

host_arch() = Sys.ARCH === :aarch64 ? "aarch64" : Sys.ARCH === :x86_64 ? "x86_64" : string(Sys.ARCH)
host_system() = Sys.isapple() ? "macos" : Sys.islinux() ? "linux" : Sys.iswindows() ? "windows" : string(Sys.KERNEL)
triple_arch(triple::AbstractString) = (a = String(first(split(triple, '-'))); a == "arm64" ? "aarch64" : a == "amd64" ? "x86_64" : a)
triple_system(triple::AbstractString) = occursin("apple", triple) ? "macos" : occursin("linux", triple) ? "linux" : startswith(triple, "wasm") ? "wasm" : occursin(r"mingw|windows", triple) ? "windows" : "?"
# whether to download what is not there (`big`: a large download)
function fetch_allowed(; big::Bool = false)
    setting = get(ENV, "STATIC_RUNTIME_CROSS_FETCH", "")
    setting == "0" && return false
    setting in ("1", "all") && return true
    return !big || (get(ENV, "GROUP", "All") in ("All", "Cross") && get(ENV, "CI", "false") != "true")
end

# whether a program for x86-64 macOS runs here: on an Apple Silicon Mac, with Rosetta
rosetta() = Sys.isapple() && Sys.ARCH === :aarch64 && success(pipeline(`arch -x86_64 /usr/bin/true`; stderr = devnull))

# whether a program for the triple runs here: the system and the architecture, or x86-64 macOS by Rosetta, or WebAssembly by Node.js 24
function runs_here(triple::AbstractString)
    system, arch = triple_system(triple), triple_arch(triple)
    system == "wasm" && return node_command() !== nothing
    system == host_system() || return false
    arch == host_arch() && return true
    return system == "macos" && arch == "x86_64" && rosetta()
end

## Artifacts of the packages of Julia's registry, fetched for a platform without installing the ones for the host (an `llc` is 2 GB): by a process of its own, which has an environment of its own

const FETCHED = Dict{String,Union{String,Nothing}}()

# The directory of the artifact `name` of the package `jll`, for `platform` (a `Platform`, by default the host's), of `version` (by default the one that Pkg picks); `big` says that it is a large download
# (see `fetch_allowed`). One that was fetched before is used whatever the setting is.
function fetch_artifact(jll::AbstractString, name::AbstractString; platform = nothing, version = nothing, big::Bool = false)
    key = string(jll, name, platform, version)
    haskey(FETCHED, key) && return FETCHED[key]
    cache = joinpath(first(Base.DEPOT_PATH), "scratchspaces", "static-runtime-cross", replace(key, r"[^A-Za-z0-9._-]" => "_"))
    isfile(cache) && isdir(read(cache, String)) && return FETCHED[key] = read(cache, String)
    fetch_allowed(; big) || return FETCHED[key] = nothing
    code = """
        import Pkg
        Pkg.activate(temp = true; io = devnull)
        using Base.BinaryPlatforms
        platform = $(platform === nothing ? "HostPlatform()" : "Platform($(repr(platform.tags["arch"])), $(repr(platform.tags["os"])))")
        Pkg.add(Pkg.PackageSpec(name = $(repr(jll)), $(version === nothing ? "" : "version = $(repr(string(version)))")); io = devnull, platform)
        using Pkg.Artifacts
        toml = joinpath(dirname(dirname(Base.find_package($(repr(jll))))), "Artifacts.toml")
        meta = artifact_meta($(repr(name)), toml; platform)
        ensure_artifact_installed($(repr(name)), meta, toml; platform)
        print(artifact_path(Base.SHA1(meta["git-tree-sha1"])))
        """
    @info "Fetching $name of $jll$(platform === nothing ? "" : " for $(platform.tags["arch"])-$(platform.tags["os"])") $(big ? "(2 GB; " : "(")it is kept; `STATIC_RUNTIME_CROSS_FETCH=0` stops this)"
    dir = try
        out = read(`$(Base.julia_cmd()) --startup-file=no -e $code`, String)
        last(split(strip(out), '\n'))
    catch e
        @warn "Could not fetch $name of $jll" exception = e
        nothing
    end
    dir !== nothing && isdir(dir) && (mkpath(dirname(cache)); write(cache, dir))
    return FETCHED[key] = dir
end

## Node.js 24 or later (`memory64` is on by default in it), which runs the programs for WebAssembly

function node_major(node::Cmd)
    try
        m = match(r"^v(\d+)\.", read(`$node --version`, String))
        return m === nothing ? 0 : parse(Int, m.captures[1])
    catch
        return 0
    end
end

# The command that runs Node.js 24 or later: `STATIC_RUNTIME_NODE`, or `node` if it is one, or the one of `NodeJS_24_jll` (fetched)
function node_command()
    haskey(FETCHED, "node") && return FETCHED["node"] === nothing ? nothing : Cmd([FETCHED["node"]])
    cmd = nothing
    if haskey(ENV, "STATIC_RUNTIME_NODE")
        cmd = Cmd([ENV["STATIC_RUNTIME_NODE"]])
    elseif Sys.which("node") !== nothing && node_major(Cmd([Sys.which("node")])) >= 24
        cmd = Cmd([Sys.which("node")])
    else
        dir = fetch_artifact("NodeJS_24_jll", "NodeJS_24")
        dir === nothing || (path = joinpath(dir, "bin", Sys.iswindows() ? "node.exe" : "node"); isfile(path) && (cmd = Cmd([path])))
    end
    FETCHED["node"] = cmd === nothing ? nothing : only(cmd.exec)
    return cmd
end
