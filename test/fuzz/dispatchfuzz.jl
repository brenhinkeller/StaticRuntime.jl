# Differential test of the analysis of what is in the slots that hold values of an abstract type (`src/inference/slots.jl`) and of the dispatch over them (`src/inference/dispatch.jl`): random programs put values of
# many types in `Vector{Any}`s, `Dict{Symbol,Any}`s, `Ref{Any}`s and the fields of structs, move them between those, through functions that are not inlined and by copies, and then call a function that has a method for each of the
# types on what is read from them. The program has to print what Julia gives. (Each program is compiled by itself: with others in the same program the slots hold what all of them store, which hides the stores that the
# analysis does not find.) A program that does not give the number of Julia is cut down to the steps that are enough for it, and written.
#
# A program that is refused when compiling, or that stops with a message (the type of a value was not found), is not a wrong answer: it is counted, and written when `FUZZ_VERBOSE` is set. (Run by `fuzz/runtests.jl`: `FUZZ_SEEDS=1:300` runs more.)

module DispatchFuzz
    using Random

    const opaque = Main.opaque

    struct ZA; a::Int; end
    struct ZB; x::Float64; y::Int; end
    struct ZC; s::String; end
    struct ZBox{T}; v::T; end
    struct ZSym; name::Symbol; end
    mutable struct ZCell; v::Any; end
    struct ZPair; a::Any; b::Any; end

    # a function with a method for each of the types (the numbers are different, so that a call of the wrong method is a different answer)
    weigh(x::Int) = x + 1
    weigh(x::Float64) = round(Int, 10x) + 2
    weigh(x::String) = length(x) + 3
    weigh(x::Symbol) = length(string(x)) + 4
    weigh(x::Bool) = x ? 5 : 6
    weigh(x::Char) = Int(x) % 7 + 7
    weigh(x::Float32) = round(Int, 10x) + 8
    weigh(x::UInt8) = Int(x) + 9
    weigh(::Nothing) = 10
    weigh(x::ZA) = 3x.a + 11
    weigh(x::ZB) = round(Int, 3x.x) + x.y + 12
    weigh(x::ZC) = 2length(x.s) + 13
    weigh(x::ZBox{Int}) = 5x.v + 14
    weigh(x::ZBox{ZA}) = weigh(x.v) + 15
    weigh(x::ZBox{Float64}) = weigh(x.v) + 16
    weigh(x::ZSym) = weigh(x.name) + 17
    weigh(x::Tuple{Int,Float64}) = x[1] + round(Int, x[2]) + 18
    weigh(x::Vector{Int}) = sum(x; init = 0) + 19
    weigh(x::ZCell) = weigh(x.v) + 20
    weigh(x::ZPair) = weigh(x.a) + 2weigh(x.b) + 21

    # the functions that the programs go through (not inlined: what is in them is not seen from where they are called)
    @noinline passthru(x) = x
    @noinline function sumv(v::Vector{Any})
        s = 0
        for x in v
            s += weigh(x)
        end
        return s
    end
    @noinline function sumd(d::Dict{Symbol,Any})
        s = 0
        for (k, x) in d
            s += weigh(x)
        end
        return s
    end

    ## the programs

    const VALUES = Function[
        r -> "opaque($(rand(r, 1:9)))",
        r -> "$(rand(r, 1:9)).5",
        r -> "\"" * randstring(r, 'a':'e', rand(r, 1:4)) * "\"",
        r -> ":" * randstring(r, 'a':'e', 3),
        r -> rand(r, Bool) ? "true" : "false",
        r -> "'" * rand(r, 'a':'z') * "'",
        r -> "Float32($(rand(r, 1:9)).5)",
        r -> "UInt8($(rand(r, 1:200)))",
        r -> "nothing",
        r -> "ZA(opaque($(rand(r, 1:9))))",
        r -> "ZB($(rand(r, 1:9)).5, opaque($(rand(r, 1:9))))",
        r -> "ZC(\"" * randstring(r, 'a':'e', rand(r, 1:4)) * "\")",
        r -> "ZBox(opaque($(rand(r, 1:9))))",
        r -> "ZBox(ZA(opaque($(rand(r, 1:9)))))",
        r -> "ZBox($(rand(r, 1:9)).5)",
        r -> "ZSym(:" * randstring(r, 'a':'e', 3) * ")",
        r -> "(opaque($(rand(r, 1:9))), $(rand(r, 1:9)).5)",
        r -> "[opaque(1), $(rand(r, 1:9))]",
        r -> "ZCell(opaque($(rand(r, 1:9))))",
    ]
    val(r) = rand(r, VALUES)(r)

    # the variables of every program: two vectors, a dictionary, a `Ref`, a struct with a field of the type `Any`, and a struct of two
    const VECTORS = 2
    function step(r)
        i, j = rand(r, 1:VECTORS), rand(r, 1:VECTORS)
        k = rand(r, 1:3)
        choices = (
            () -> "push!(v$i, $(val(r)))",
            () -> "v$i[1] = $(val(r))",
            () -> "pushfirst!(v$i, $(val(r)))",
            () -> "insert!(v$i, 1, $(val(r)))",
            () -> "append!(v$i, Any[$(val(r)), $(val(r))])",
            () -> "d[:k$k] = $(val(r))",
            () -> "get!(d, :k$k, $(val(r)))",
            () -> "ref[] = $(val(r))",
            () -> "cell.v = $(val(r))",
            () -> "cell = ZCell($(val(r)))",
            () -> "pair = ZPair($(val(r)), $(val(r)))",
            () -> "v$i = passthru(v$i)",
            () -> "v$i = copy(v$i)",
            () -> "v$i = vcat(v$i, v$j)",
            () -> "append!(v$i, v$j)",
            () -> "d = passthru(d)",
            () -> "d = copy(d)",
            () -> "cell = passthru(cell)",
            () -> "push!(v$i, ref[])",
            () -> "push!(v$i, cell.v)",
            () -> "ref[] = v$j[1]",
            () -> "cell.v = v$j[end]",
            () -> "pair = ZPair(v$j[1], ref[])",
            () -> "d[:k$k] = v$i[1]",
            () -> "v$i = filter(x -> true, v$j)",
            () -> "ref[] = pair.a",
            () -> "ref = passthru(ref)",
            () -> "append!(v$i, %T())",
            () -> "v$i = copy(%T())",
            () -> "push!(v$i, %T()[$(rand(r, 1:3))])",
            () -> "cell.v = %T()[$(rand(r, 1:3))]",
        )
        return rand(r, choices)()
    end

    const PROLOGUE = ["v1 = Any[%V]", "v2 = Any[%V]", "d = Dict{Symbol,Any}(:k1 => %V)", "ref = Ref{Any}(%V)", "cell = ZCell(%V)", "pair = ZPair(%V, %V)"]
    const EPILOGUE = ["acc = sumv(v1) + 3sumv(v2) + 5sumv(%T())", "acc += sumd(d)", "acc += weigh(ref[])", "acc += weigh(cell)", "acc += weigh(pair)", "acc += weigh(v1[1]) + weigh(v2[end])"]

    struct Program
        prologue::Vector{String}
        steps::Vector{String}
        table::String # the elements of a constant that is a `Vector{Any}`, which a function that is not inlined gives
    end

    function program(seed::Integer; nsteps = rand(Random.Xoshiro(seed + 7919), 4:12))
        r = Random.Xoshiro(seed)
        prologue = [replace(line, "%V" => val(r)) for line in PROLOGUE]
        # (`replace` above gives each line one value: a line with two has the same twice, so the second of the pair is made again)
        prologue[end] = "pair = ZPair($(val(r)), $(val(r)))"
        return Program(prologue, [step(r) for _ in 1:nsteps], join((val(r) for _ in 1:3), ", "))
    end

    function source(name::Symbol, p::Program, steps = p.steps)
        table = Symbol(name, "_table")
        getter = Symbol(name, "_get")
        body = string("function ", name, "()\n    ", join(p.prologue, "\n    "), "\n    ", join(steps, "\n    "), "\n    ", join(EPILOGUE, "\n    "), "\n    return acc\nend")
        return string("const ", table, " = Any[", p.table, "]\n@noinline ", getter, "() = ", table, "\n", replace(body, "%T" => getter))
    end

    const COUNTER = Ref(0)
    function compile_program(p::Program, steps = p.steps)
        name = Symbol("program_", COUNTER[] += 1)
        Core.eval(@__MODULE__, Meta.parseall(source(name, p, steps)))
        f = Base.invokelatest(getfield, @__MODULE__, name)
        status, detail = Base.invokelatest(Main.static_status, f)
        return status, string(detail)
    end

    # a different answer from Julia's (or a program that crashes, which a message does not say) is what is wrong; refusing, or stopping with a message, is not
    function wrong(status, detail)
        status === :mismatch && return true
        status === :runtime_error && occursin("ProcessSignaled", detail) && return true
        return false
    end

    # the steps that are enough for the same failure
    function cut_down(p::Program, status)
        steps = copy(p.steps)
        changed = true
        while changed
            changed = false
            for i in reverse(eachindex(steps))
                trial = steps[[j for j in eachindex(steps) if j != i]]
                s, d = compile_program(p, trial)
                if s === status || wrong(s, d)
                    steps = trial
                    changed = true
                end
            end
        end
        return steps
    end
end

# One case: the program of a seed. A program that is refused when compiling, or that stops with a message, is not a wrong answer. A wrong one is cut down to the steps that are enough for it, and written.
function fuzz_case(seed::UInt)
    p = DispatchFuzz.program(seed)
    status, detail = DispatchFuzz.compile_program(p)
    if DispatchFuzz.wrong(status, detail)
        steps = DispatchFuzz.cut_down(p, status)
        return false, string("a wrong answer: ", status, " ", first(replace(detail, '\n' => ' '), 300), "\n", DispatchFuzz.source(:program, p, steps))
    end
    status === :ok || isempty(get(ENV, "FUZZ_VERBOSE", "")) || println(stderr, "dispatch fuzz: not a wrong answer, seed ", repr(seed), ": ", status, " ", first(replace(detail, '\n' => ' '), 200))
    return true, ""
end
