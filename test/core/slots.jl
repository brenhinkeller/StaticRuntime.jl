# Slots that hold values of an abstract type (the elements of a `Vector{Any}`, a field of the type `Any`): what a read of one gives is of the types that the program stores in it (`src/inference/slots.jl`). A value of a type
# that is not registered (`SMeters`) is dispatched on, which a program can only do for the types that it was found to store.

struct SMeters; m::Float64; end
suse(x::Int) = x
suse(x::Float64) = round(Int, x)
suse(x::SMeters) = round(Int, 100 * x.m)
suse(x::String) = length(x)
suse(x::Vector{Int}) = 100 + length(x)
suse(x::Tuple{Int,Float64}) = 200 + x[1]
struct SBox; v::Any; end
sget(b::SBox) = b.v
@noinline sput!(v::Vector{Any}, @nospecialize(x)) = (push!(v, x); nothing)
# (a constant that a function that is not inlined gives, and that holds types that the code does not store anywhere else: they are found in the `return` of the function)
const STABLE = Any[1, 2.5, "abc"]
@noinline stable() = STABLE

slot_cases() = [
    "elements"      => () -> (v = Any[opaque(1), 2.5, SMeters(1.5)]; s = 0; for x in v; s += suse(x); end; s),
    "a field"       => () -> (a = SBox(opaque(2)); b = SBox(SMeters(0.5)); suse(sget(a)) + suse(sget(b))),
    "pushed"        => () -> (v = Any[]; sput!(v, opaque(1)); sput!(v, SMeters(1.5)); s = 0; for x in v; s += suse(x); end; s),
    "types"         => () -> (v = Any[Int, Float64, String]; s = 0; for T in v; s += T === Int ? 1 : T === Float64 ? 20 : 300; end; s + opaque(0)),
    "a Dict"        => () -> (d = Dict{Symbol,Any}(:a => opaque(1), :b => SMeters(2.0), :c => "xyz"); s = 0; for (k, x) in d; s += suse(x); end; s),
    "swapped"       => () -> (v = Any[opaque(1), 2]; v[2] = SMeters(0.25); s = 0; for x in v; s += suse(x); end; s),
]

@testset "Slots" begin
    @testset "values of types that were not registered" begin
        check_cases(slot_cases())
    end
    # types of Base that are not registered (`Vector{Int}`, `Tuple{Int,Float64}`), stored in a slot that has another store of a type that is not known (so it is not given the types that are stored in it): a call on what is read is made over
    # the types that the program stores in slots, as well as the registered ones and the types that it defines
    @testset "types of Base that are stored in a slot that is not known" begin
        stores_base_types() = (v = Any[opaque(1), [opaque(2), 3], (opaque(4), 1.5)]; push!(v, Base.inferencebarrier(2.5)); s = 0; for x in v; s += suse(x); end; s)
        @test static_status(stores_base_types)[1] == :ok
    end
    # (a program of its own: with the others the slot of the elements holds what they store in it)
    @testset "a constant that is returned" begin
        returned() = (v = Any[opaque(7), opaque(8)]; s = suse(v[1]) + suse(v[2]); for x in stable(); s += suse(x); end; s)
        @test static_status(returned)[1] == :ok
    end
    # the check: a read of a slot that was given types is `typeassert`ed (`STATIC_RUNTIME_CHECK_TYPES`), so that a program that stores what the analysis does not find stops
    @testset "checked reads" begin
        withenv("STATIC_RUNTIME_CHECK_TYPES" => "1") do
            check_cases(slot_cases())
        end
        stores_string() = (v = Any[opaque(1), "ab", opaque(3)]; s = 0; for x in v; s += x isa String ? length(x) : x; end; s)
        # (it is on by default, as the compilation is `strict`)
        @test static_status(stores_string)[1] == :ok
        withenv("STATIC_RUNTIME_SLOTS_BLIND" => "String") do
            @test static_status(stores_string)[1] == :runtime_error
        end
        # (a slot that holds one type: what inference narrows it to is a `PiNode` of the read, which is no check, and is turned into one)
        stores_float() = (v = Any[opaque(1), 2.5]; s = 0; for x in v; s += x isa Float64 ? 100 : x; end; s)
        @test static_status(stores_float)[1] == :ok
        withenv("STATIC_RUNTIME_SLOTS_BLIND" => "Float64") do
            @test static_status(stores_float)[1] == :runtime_error
        end
        withenv("STATIC_RUNTIME_CHECK_TYPES" => "1") do
            @test static_status(stores_string)[1] == :ok
            # (the analysis is made to miss the stores of `String`, as it would a store that it can't see: the read is then not of the type that it was said to be)
            withenv("STATIC_RUNTIME_SLOTS_BLIND" => "String") do
                @test static_status(stores_string)[1] == :runtime_error
            end
        end
    end
end

# The universe: the types that the program makes (`src/inference/slots.jl`). A call over a value of the type `Any` that nothing is known of (`anyvalue`) is made over the registered types and over the types that the program makes
# that are not Julia's own, so a type that was not registered is one a value can have, as long as the program makes it
struct UMeters; m::Float64; end
struct UBox{T}; v::T; end
uuse(x::Int) = x
uuse(x::Float64) = round(Int, x)
uuse(x::UMeters) = round(Int, 100 * x.m)
uuse(x::UBox{UMeters}) = 7
uuse(x::Vector{UMeters}) = length(x)
universe_cases() = [
    "a type of the program"      => () -> uuse(anyvalue(UMeters(opaque(1) + 0.5))),
    "a parametric type of it"    => () -> uuse(anyvalue(UBox(UMeters(opaque(1) + 0.5)))),
    "a vector of them"           => () -> uuse(anyvalue(UMeters[UMeters(1.0), UMeters(2.0)])),
    "registered types as before" => () -> uuse(anyvalue(opaque(3))) + uuse(anyvalue(2.5)),
    "both"                       => () -> uuse(anyvalue(UMeters(opaque(2) + 0.0))) + uuse(anyvalue(opaque(5))),
]
# The process that compiles is not part of the program: `Base.roottask` is a constant of the code that waits, and has the scope that the code that compiles runs in (what it binds, and the values of the logger and of
# `with`), which analysis of the constants must not take for what the program makes
struct UHostMarker; x::Int; end
@testset "The scope of the compiling process is not part of a program" begin
    sv = Base.ScopedValues.ScopedValue{Any}(nothing)
    Base.ScopedValues.with(sv => UHostMarker(1)) do
        facts = StaticRuntime.scan_facts(Base.roottask)
        @test !any(f -> f[1][1] === :universe && f[1][2] === UHostMarker, facts)
        @test !any(f -> f[1][1] === :universe && f[1][2] === StaticRuntime.Compilation, facts)
    end
end

@testset "The universe" begin
    # (what is in it: types that the program makes. A `Val{MyType}` is not one: it is the argument of a method that is made from it, and a call with an argument of the type `Val` made over it can't succeed, which made
    # what called it one that does not return, where the code is not inlined, as it is under `--code-coverage`)
    @test StaticRuntime.user_relevant(UMeters)
    @test StaticRuntime.user_relevant(Vector{UMeters})
    @test !StaticRuntime.user_relevant(Val{UMeters})
    check_cases(universe_cases())
    withenv("STATIC_RUNTIME_CHECK_TYPES" => "1") do
        check_cases(universe_cases())
    end
    # (without it, the types that were not registered abort: as they did)
    withenv("STATIC_RUNTIME_UNIVERSE" => "0") do
        @test static_status(universe_cases()[1].second)[1] == :runtime_error
        @test static_status(universe_cases()[4].second)[1] == :ok
    end
end
