# A compilation does not depend on the ones that were made before it: the same programs, compiled in a process in different orders, and each of them more than once, are compiled to programs that do the same. (What a
# compilation keeps in the process, and what inference caches, are not what the next one is made of: see `purge_inferred!`, and the state in `Compilation`.)
#
# The programs are those whose compilation depended on what had been compiled: one that has a `@cfunction` that inference only finds when it infers the method that has it (`atexit`), a call on an abstract type whose subtypes the
# slots of the program narrow, callbacks, closures, and the standard error.

const DETERMINISM_SCRIPT = raw"""
using StaticRuntime, SparseArrays
abstract type DList{T} end
struct DNil{T} <: DList{T} end
struct DCons{T} <: DList{T}
    head::T
    tail::DList{T}
end
dhead(x::DCons) = x.head
dtail(x::DCons) = x.tail
dlist(xs...) = foldr((x, l) -> DCons{Int}(x, l), xs; init = DNil{Int}())
dlength(l::DList) = l isa DNil ? 0 : 1 + dlength(dtail(l))
opaque(x::Integer) = x + oftype(x, time_ns() >> 63)
cases = Pair{String,Function}[
    "atexit"         => () -> (atexit(() -> println("x = ", opaque(7))); println("end"); 0),
    "atexit twice"   => () -> (atexit(() -> println("first")); atexit(() -> println("second ", opaque(1))); 0),
    "abstract list"  => () -> (l = dlist(opaque(1), 2, 3); dlength(l) * 10 + dhead(l) + dhead(dtail(l))),
    "closures"       => () -> (fs = Function[x -> x + 1, x -> 2x]; s = 0; for f in fs; s += f(opaque(3)); end; s),
    "stderr"         => () -> (println(stderr, "to the standard error ", opaque(2)); println(stdout, "to the standard output"); 0),
    "Dict and sort"  => () -> (d = Dict("a" => opaque(1), "b" => 2); v = sort(collect(values(d))); println(v); length(d)),
    "sprint and show" => () -> (println(sprint(show, [opaque(1), 2, 3])); println(1.5, 'c', "s"); 0),
]
order = Symbol(get(ARGS, 1, "forward"))
indices = order === :reverse ? reverse(eachindex(cases)) : order === :twice ? repeat(collect(eachindex(cases)), 2) : collect(eachindex(cases))
# (what the program writes, and not whether Julia writes it: the functions of `atexit` run when the program ends, and Julia's do not when this does)
function run_case(f)
    main = StaticRuntime.make_main(f)
    dir = mktempdir()
    exe = try
        Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)))
    catch e
        return "compile error: " * first(replace(sprint(showerror, e), '\n' => ' '), 300)
    end
    return try read(`$exe`, String) catch e; "run error" end
end
results = Dict{String,Vector{String}}()
for i in indices
    name, f = cases[i]
    push!(get!(Vector{String}, results, name), run_case(f))
end
for (name, _) in cases
    println(name, " => ", join(repr.(results[name]), ","))
end
"""

@testset "A compilation does not depend on the ones before it" begin
    function compile_in_order(order)
        script = tempname() * ".jl"
        write(script, DETERMINISM_SCRIPT)
        out = IOBuffer()
        err = IOBuffer()
        run(pipeline(`$(Base.julia_cmd()) --project=$(Base.active_project()) $script $order`; stdout = out, stderr = err))
        return String(take!(out)), String(take!(err))
    end
    forward, forward_err = compile_in_order("forward")
    reverse, reverse_err = compile_in_order("reverse")
    twice, twice_err = compile_in_order("twice")
    lines(s) = sort!(filter(!isempty, split(s, '\n')))
    @test lines(forward) == lines(reverse)
    @test !any(l -> occursin("error", l), lines(forward)) || (println(forward); false) # (every program was compiled, and ran)
    # (each case twice in the same process: the second compilation is the same as the first)
    @test all(l -> (m = match(r"=> (\".*?\"),(\".*\")$", l); m !== nothing && m[1] == m[2]), lines(twice))
end
