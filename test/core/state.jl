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

# The version of the registry is a hash of what it has: the same content is the same version, in any order of registering and in any process (what was inferred for a version is found by every session that has it), and
# another content is another version. (A registry of its own is used here, not the one of the process.)
const REGISTRY_PROBE = """
    using StaticRuntime
    S = StaticRuntime
    r = S.Registry()
    for T in (Vector{Int}, Tuple{Int,Float64}, Dict{Symbol,Any}); S.register_new!(r, r.show, T); end
    S.register_new!(r, r.family, Val{3})
    string(r.version)
    """
@testset "The version of the registry is made of what it has" begin
    S = StaticRuntime
    registry(types) = (r = S.Registry(); for T in types; S.register_new!(r, r.show, T); end; r)
    @test registry([Int8, Int16]).version == registry([Int16, Int8]).version  # (the order does not matter)
    @test registry([Int8, Int16]).version != registry([Int8, Int32]).version  # (another content)
    @test registry([Int8]).version != registry([Int8, Int16]).version
    @test registry([Int8, Int8]).version == registry([Int8]).version          # (a type that is there is not added again)
    @test S.Registry().version == 0
    here = Base.invokelatest(include_string, Module(:RegistryProbe), REGISTRY_PROBE)
    there = read(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $(string("print(begin\n", REGISTRY_PROBE, "\nend)"))`, String)
    @test here == there                                                       # (nor does the process)
end

# What a program shows of a value of the type `Any` is made over the registered types (`show_element`), by a generator whose code Julia could keep from the time that it was first made: what is registered after a program
# that has it was compiled has to be what the next one has, as the registry is in the key of what is inferred, and what is inferred is made again when it is not the same
struct RegHolder; v::Any; end
struct RegShown; v::Int; end
@testset "A type that is registered after another program was compiled is shown by the next one" begin
    holder(x) = () -> (println(RegHolder(Base.inferencebarrier(x))); 0)
    @test static_status(holder(1))[1] == :ok                        # (the generated code for `Any` is made, with what is registered now)
    @test static_status(holder(RegShown(7)))[1] == :runtime_error   # (a type that is not registered is not shown: it says so when the program runs)
    StaticRuntime.add_show_candidates!(RegShown)
    @test static_status(holder(RegShown(7)))[1] == :ok
end

# What the workload inferred when the package was compiled is found by the programs that are the same, and the slots of such a program are analyzed all the same (what is true of its inference, `SlotFactsResult`,
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
    @test all(isempty, values(S.FINALIZER_REGISTRIES)) && !S.FINALIZER_NEVER[] # (the sites are the process's: see overrides/gc.jl)
    @test !S.LOG_SILENT[] && S.MATCH_CONTEXT[] == C_NULL && S.DYNAMIC_SYMBOLS[] == 0
    @test all(iszero, Base.get_extension(S, :StaticRuntimeRandomExt).TASKLOCAL_RNG_STATE[])
end


# Types that no value has (`STATIC_RUNTIME_TRACE` says which calls give no value and have an argument of one)
@testset "Types with Union{} as a parameter" begin
    @test StaticRuntime.has_bottom_parameter(Base.Pairs{Symbol, Union{}, Nothing, @NamedTuple{}})
    @test StaticRuntime.has_bottom_parameter(Type{Union{}})
    @test !StaticRuntime.has_bottom_parameter(Vector{Int})
    @test !StaticRuntime.has_bottom_parameter(Tuple{Int, Union{Nothing, String}})
end
