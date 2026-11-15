# The state of the process that compiles: what a compilation is made of and leaves behind (`src/inference/compilation.jl`, `src/registry.jl`). This file is the last of the tests, so that what it looks at is
# what all of the others left.

@testset "A compilation is its own" begin
    StaticRuntime.with_compilation() do c
        @test StaticRuntime.compilation() === c
        @test isempty(c.closures.functions) && isempty(c.closures.callbacks) && isempty(c.boxes.types) && isempty(c.slots.types) && isempty(c.slots.universe)
        StaticRuntime.with_compilation() do d # (a compilation that is made inside another is its own, and the other is there again when it ends)
            @test StaticRuntime.compilation() === d
            @test d !== c
        end
        @test StaticRuntime.compilation() === c
    end
    @test StaticRuntime.CURRENT_COMPILATION[] === nothing
    @test_throws ErrorException StaticRuntime.compilation() # (the hooks of inference are only run by a compilation)
    @test_throws DomainError StaticRuntime.with_compilation(c -> throw(DomainError(1)))
    @test StaticRuntime.CURRENT_COMPILATION[] === nothing # (also when it ends with an error)
    @test !islocked(StaticRuntime.COMPILATION_LOCK)
end

# What inference depends on is in the key of what it infers, by what it is: a state that it reads and the key does not have would make a compilation use what another one inferred for something else
struct StateProbe; x::Int; end
@testset "The key of what is inferred is made of all that it depends on" begin
    key(f) = (c = StaticRuntime.Compilation(); f(c); StaticRuntime.inference_key(c))
    base = StaticRuntime.Compilation().key
    @test key(c -> nothing) == base # (the same state is the same key, in every compilation)
    changes = [
        "a function candidate"   => c -> push!(c.closures.functions, typeof(sin)),
        "a callback"             => c -> push!(c.closures.callbacks, (Int, typeof(sin))),
        "a box"                  => c -> (c.boxes.types[(Tuple{typeof(sin),Float64}, 1)] = Int),
        "the type of a slot"     => c -> (c.slots.types[(:elem, Any, nothing)] = Int),
        "the universe"           => c -> push!(c.slots.universe, StateProbe),
        "the mode of the slots"  => c -> (c.slots.mode = :off),
    ]
    for (name, change) in changes
        @testset "$name" begin
            @test key(change) != base
        end
    end
    # a setting: the check of the reads of the slots is on for a compilation that is `strict`, and not for one that is not
    @test StaticRuntime.inference_key(StaticRuntime.Compilation(StaticRuntime.Settings(; strict = false))) != base
    # (the types of a slot are told apart: `hash` of a `Union` does not)
    @test key(c -> (c.slots.types[(:elem, Any, nothing)] = Union{Int,String})) != key(c -> (c.slots.types[(:elem, Any, nothing)] = Union{Int,Symbol}))
    # what is registered: a registration is in the key of the compilations that are made after it, and not of one that was made before
    before = StaticRuntime.Compilation()
    StaticRuntime.add_show_candidates!(StateProbe)
    after = StaticRuntime.Compilation()
    @test after.key != before.key
    @test StateProbe in after.registered.dispatch && !(StateProbe in before.registered.dispatch)
    StaticRuntime.add_show_candidates!(StateProbe) # (again: nothing changes)
    @test StaticRuntime.Compilation().key == after.key
end

# The key is the same in every process (the `objectid` of a type is not): so what a workload infers when the package is compiled is found by the sessions that load it. The same state, of types that every process has, is made
# here and in another process, and what its key is made of has to be the same.
const KEY_PROBE = """
    using StaticRuntime
    S = StaticRuntime
    c = S.Compilation()
    append!(c.closures.functions, [typeof(sin), typeof(cos), typeof(identity)])
    push!(c.closures.callbacks, (Int, typeof(sin)))
    c.boxes.types[(Tuple{typeof(sin),Float64}, 1)] = Union{Int,String}
    c.boxes.types[(typeof(sin), :contents)] = Float64
    c.slots.types[(:elem, Any, nothing)] = Union{Int,String,Vector{Int}}
    c.slots.types[(:field, Base.RefValue{Any}, :x)] = Float64
    union!(c.slots.universe, [Vector{Int}, Tuple{Int,Float64}, Dict{Symbol,Any}])
    join((S.closures_hash(c.closures), S.boxes_hash(c.boxes), S.slots_hash(c.slots)), ",")
    """
@testset "The key is the same in every process" begin
    here = Base.invokelatest(include_string, Module(:KeyProbe), KEY_PROBE)
    code = string("print(begin\n", KEY_PROBE, "\nend)")
    there = read(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $code`, String)
    @test here == there
    # (and a union is told from another: the `hash` of one is not)
    @test StaticRuntime.type_hash(Union{Int,String}) != StaticRuntime.type_hash(Union{Int,Symbol})
    @test StaticRuntime.type_hash(Union{Int,String}) == StaticRuntime.type_hash(Union{String,Int})
end

# What the workload inferred when the package was compiled is found by the programs that are the same, and the slots of such a program are analyzed all the same (what is true of its inference, `DISPATCH_USED_KEYS` and `SLOT_FACTS`,
# is kept with it): a program of the workload that is compiled in another process has more than one pass, as it did when the workload compiled it
@testset "What is found of the programs of the workload is found whole" begin
    code = """
        using StaticRuntime
        compile_executable(StaticRuntime.PrecompileWorkload.showing, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "showing")
        c = StaticRuntime.LAST_COMPILATION[]
        print(c.slots.passes, ",", length(c.slots.types))
        """
    passes, known = parse.(Int, split(read(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $code`, String), ','))
    @test passes > 0 && known > 0
end

# The globals that a program has are its own state (they are the initial values of those of the binary): the process that compiles never runs the code that changes them, so each is still as it was made. If one is
# not, the programs that are compiled after it have what it was changed to.
@testset "The state of the programs is as it was made" begin
    S = StaticRuntime
    @test isempty(S.RUNQUEUE) && S.CURRENT_TASK[] === nothing
    @test isempty(S.ATEXIT_HOOKS) && !S.ATEXIT_INSTALLED[]
    @test all(isempty, values(S.FINALIZER_REGISTRIES)) && !S.FINALIZER_NEVER[] # (the sites are the process's: see finalizers.jl)
    @test !S.LOG_SILENT[] && S.MATCH_CONTEXT[] == C_NULL && S.DYNAMIC_SYMBOLS[] == 0
    @test all(iszero, S.TASKLOCAL_RNG_STATE[])
end
