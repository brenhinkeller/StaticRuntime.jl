# Slots that hold values of an abstract type (the elements of a `Vector{Any}`, a field of the type `Any`): what a read of one gives is of the types that the program stores in it (`src/inference/slots.jl`). A value of a type
# that is not registered (`SMeters`) is dispatched on, which a program can only do for the types that it was found to store.

struct SMeters; m::Float64; end
suse(x::Int) = x
suse(x::Float64) = round(Int, x)
suse(x::SMeters) = round(Int, 100 * x.m)
suse(x::String) = length(x)
struct SBox; v::Any; end
sget(b::SBox) = b.v
@noinline sput!(v::Vector{Any}, @nospecialize(x)) = (push!(v, x); nothing)

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
    # the check: a read of a slot that was given types is `typeassert`ed (`STATIC_RUNTIME_CHECK_TYPES`), so that a program that stores what the analysis does not find stops
    @testset "checked reads" begin
        withenv("STATIC_RUNTIME_CHECK_TYPES" => "1") do
            check_cases(slot_cases())
        end
        stores_string() = (v = Any[opaque(1), "ab", opaque(3)]; s = 0; for x in v; s += x isa String ? length(x) : x; end; s)
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
@testset "The universe" begin
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
