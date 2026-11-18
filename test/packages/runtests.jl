# What compiles from the standard libraries and from the packages that programs use: a survey that is kept as tests, so that what works stays working. The programs compile to
# executables and have to print what Julia gives for the same code. It takes a few minutes (`GROUP=Packages`, or `GROUP=Core` for the tests of the package alone).
#
# `PACKAGES=Dates,StatsBase` (the names of the files, or parts of them) runs only some of them.
println("\n")
@info "Package tests, including stdlibs:"

@isdefined(check_cases) || include(joinpath(@__DIR__, "..", "helpers.jl"))
include_timed("common.jl")

const STDLIBS = ["linearalgebra", "sparsearrays", "statistics", "dates", "printf", "logging", "encoding", "sha", "uuids", "sockets", "mmap", "styledstrings"]
const PACKAGES_TESTED = ["distributions", "nanstatistics", "statsbase", "datastructures", "orderedcollections", "staticarrays", "graphs", "parsers", "mpi", "observables", "unicodeplots", "sciml"]
const ALL = [STDLIBS; PACKAGES_TESTED]
selected = get(ENV, "PACKAGES", "")
selected = isempty(selected) ? ALL : [lowercase(strip(s)) for s in split(selected, ',')]

# Each file is included in a module of its own, so that what one of them defines, or takes from a package with `using`, is not a name that another sees (StyledStrings and UnicodePlots both export `annotate!`: in one
# module, after both, it is neither). The helpers (`helpers.jl` and `common.jl`) are in a module of theirs, and each module of a test has them as constants.
const PACKAGE_TEST_HELPERS = Module(:PackageTestHelpers)
Base.include(PACKAGE_TEST_HELPERS, joinpath(@__DIR__, "..", "helpers.jl"))
Base.include(PACKAGE_TEST_HELPERS, joinpath(@__DIR__, "common.jl"))
const PACKAGE_TEST_HELPER_NAMES = Symbol[n for n in names(PACKAGE_TEST_HELPERS; all = true)
                                        if !startswith(string(n), "#") && !(n in (:eval, :include, nameof(PACKAGE_TEST_HELPERS))) &&
                                           isdefined(PACKAGE_TEST_HELPERS, n) && Base.binding_module(PACKAGE_TEST_HELPERS, n) === PACKAGE_TEST_HELPERS]

function include_package_test(name::AbstractString)
    m = Module(Symbol("PackageTest_", name))
    # (what the tests have from `runtests.jl`, as `Main` has it: the standard libraries that they use, which do not have names in common)
    Core.eval(m, :(using Test, Random, Printf, LinearAlgebra, Libdl, Dates, SparseArrays, Base64, CRC32c, Logging, Statistics))
    Core.eval(m, :(using SHA, UUIDs, Sockets, Unicode, TOML, Markdown, Mmap))
    Core.eval(m, :(using StaticRuntime))
    for n in PACKAGE_TEST_HELPER_NAMES
        Core.eval(m, :(const $n = $(getfield(PACKAGE_TEST_HELPERS, n))))
    end
    isempty(get(ENV, "TEST_PROGRESS", "")) || (println(stderr, "TEST_PROGRESS ", name, ".jl"); flush(stderr))
    t0 = time()
    Base.include(m, joinpath(@__DIR__, "$name.jl"))
    push!(FILE_TIMES, "$name.jl" => time() - t0)
    return nothing
end

for name in ALL
    any(s -> occursin(s, name) || occursin(name, s), selected) || continue
    include_package_test(name)
end

# End of Package tests