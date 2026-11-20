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
    # (`uuse` of a `UBox{UMeters}` is 7 whatever the box holds: what the case is about is that it compiles)
    check_cases(universe_cases(); folded_ok = ("a parametric type of it",))
    withenv("STATIC_RUNTIME_CHECK_TYPES" => "1") do
        check_cases(universe_cases(); folded_ok = ("a parametric type of it",))
    end
    # (without it, the types that were not registered abort: as they did)
    withenv("STATIC_RUNTIME_UNIVERSE" => "0") do
        @test static_status(universe_cases()[1].second)[1] == :runtime_error
        @test static_status(universe_cases()[4].second)[1] == :ok
    end
end

# Types as values of a program: a `Vector{Type}`, a `Set{Type}`, a `Dict{Type,...}`, a tuple of types (see "Types as values" in slots.jl). What is read from a slot that is declared `Type` is one of the types that the program stored in
# it (the compiler finds them: they are the cases that a call on it is made over), and the read is checked. Which type it is is not known when compiling (`opaque`).
tv_index(i) = opaque(i)
tv_pick(i) = i == 1 ? Int : i == 2 ? Float64 : String
tv_kind(::Type{Int}) = "int"
tv_kind(::Type{Float64}) = "float"
tv_kind(::Type{<:AbstractString}) = "string"
tv_kind(::Type) = "other"
tv_kind4(::Type{Int}) = 1
tv_kind4(::Type{Float64}) = 2
tv_kind4(::Type{<:AbstractString}) = 3
tv_kind4(::Type) = 4
abstract type TVShape end
struct TVCircle <: TVShape end
struct TVSquare <: TVShape end
tv_cases() = [
    "equality of a type"         => () -> (v = Type[Int, Float64][tv_index(1)]; println(v === Int, " ", v == Int, " ", isequal(v, Float64)); 0),
    "printing a type"            => () -> (v = Type[Int, Vector{Float64}][tv_index(2)]; println(v); println(string(v)); 0),
    "subtype of a type"          => () -> (v = Type[Int, Float64, String][tv_index(1)]; println(v <: Integer, " ", v <: Real, " ", Real >: v); 0),
    "a method of a type"         => () -> (v = Type[Int, Float64, String, Char][tv_index(3)]; println(tv_kind(v)); 0),
    "a type that has four methods" => () -> (v = Type[Int, Float64, String, Char][tv_index(4)]; println(tv_kind4(v)); 0),
    "hash of a type"             => () -> (v = Type[Int, Float64][tv_index(1)]; println(hash(v) == hash(Int)); 0),
    "a set of types"             => () -> (s = Set{Type}(); push!(s, tv_pick(tv_index(1))); push!(s, Float64); push!(s, tv_pick(tv_index(1))); println(length(s), " ", Int in s, " ", String in s); 0),
    "a dict of types"            => () -> (d = Dict{Type,Int}(); d[tv_pick(tv_index(1))] = 1; d[Float64] = 2; d[tv_pick(tv_index(2))] = 3; println(get(d, Int, 0), " ", get(d, Float64, 0), " ", length(d)); 0),
    "a tuple of types"           => () -> (v = Tuple{Type,Type}[]; push!(v, (tv_pick(tv_index(1)), Float64)); println(v[1][1] === Int, " ", v[1][2], " ", length(v)); 0),
    "a set of tuples of types"   => () -> (s = Set{Tuple{Type,Type}}(); push!(s, (tv_pick(tv_index(1)), Float64)); push!(s, (Int, Float64)); push!(s, (String, Float64)); println(length(s)); 0),
    "a type made of types"       => () -> (v = Type[Int, Float64][tv_index(1)]; println(Vector{v} === Vector{Int}, " ", Tuple{v,String} === Tuple{Int,String}, " ", eltype(Vector{v}) === Int); 0),
    "a type that is made"        => () -> (v = Type[TVCircle, TVSquare][tv_index(2)]; println(v <: TVShape, " ", v() isa TVShape, " ", v === TVSquare); 0),
]
@testset "Types as values" begin
    # (one program for all: the slot of all the `Vector{Type}`s of a program holds all the types that it stores in them, more than each case has)
    check_cases(tv_cases())
end

# Objects that are constants are known one by one (see src/inference/objects.jl): a field of an abstract type of each of them holds what it has and what is stored in it, and not what all of the objects of its type hold.
# Here a listener stores the values of two cells as a pair in a third (as Makie's `transform_func` is the pair of `xscale[]` and `yscale[]`): with one slot for the field of all cells, its types would be pairs of its own types,
# and pairs of those, without end (given up, the program needs the runtime). The other cells hold values of many types. (Only `identity` is stored in the first: a pair that is one of two, `Tuple{Union{A,B},C}`, is a tuple
# that is made by the runtime, which is another limit.)
mutable struct OTCell
    val::Any
end
struct OTPair{A,B,C}
    a::A
    b::B
    out::C
end
(p::OTPair)() = (p.out.val = (p.a.val, p.b.val); nothing)
const OT_X = OTCell(identity)
const OT_Y = OTCell(identity)
const OT_T = OTCell((identity, identity))
const OT_OTHERS = OTCell[OTCell(x) for x in (1, 2.0, "s", :a, 'c', 0x01, Int32(2), 1f0, (1, 2), nothing, missing)]
const OT_LISTENER = OTPair(OT_X, OT_Y, OT_T)
ot_pairs() = (opaque(1) == 1 && (OT_X.val = identity); OT_LISTENER(); t = OT_T.val; println(t[1] === identity, " ", t[2] === identity, " ", OT_OTHERS[opaque(3)].val isa String); 0)
@testset "Objects known one by one" begin
    check_cases(["a pair of the values of two objects, stored in a third" => ot_pairs])
end

# What a method that is not inlined stores in an object that is a constant, when nothing that it is called with is such an object (a finalizer, which a call of the runtime's
# `run_finalizer(Val(id), F, T, addr)` has inlined, is one): the method is of the program as any that a call that is left in the code calls, and what it stores is in the field.
const OT_KEEP = Ref{Any}(nothing)
@noinline ot_store(n::Int) = (OT_KEEP[] = n * 2.5; nothing)
ot_stored() = (ot_store(opaque(2)); v = OT_KEEP[]; println(v === nothing ? "nothing" : v); 0)
@testset "Objects that a method stores in without being given them" begin
    check_cases(["a store in a method that is called with a number" => ot_stored])
end

# A lookup in a container that is a constant, with a key that is a constant, is what the container has when the program never changes a container of its type (`container_frozen` in objects.jl): the cell that is read is then
# known, and what its field holds (which the program does not write) too. A program that changes such a container has the lookups made as they are (a program of its own: a change is of all of the containers of the type).
mutable struct FzCell; v::Any; end
fz_value(x::Int) = x
fz_value(x::Float64) = round(Int, 10x)
fz_value(x::String) = ncodeunits(x)
const FZ_TABLE = Dict(:a => FzCell(1), :b => FzCell(2.5), :c => FzCell("str"))
const FZ_LIST = [FzCell(4), FzCell(5.5)]
const FZ_CHANGED = Dict(:a => FzCell(1), :b => FzCell(2.5))
@testset "Containers that the program does not change" begin
    check_cases([
        "a lookup in a Dict"     => () -> fz_value(FZ_TABLE[:b].v) + fz_value(FZ_TABLE[:c].v),
        "get with a default"     => () -> (c = get(FZ_TABLE, :a, nothing); c === nothing ? -1 : fz_value(c.v)),
        "haskey"                 => () -> Int(haskey(FZ_TABLE, :a)) + 10 * Int(haskey(FZ_TABLE, :zz)),
        "an element of a Vector" => () -> fz_value(FZ_LIST[2].v) + fz_value(FZ_LIST[1].v),
        "a key that is not known" => () -> fz_value(FZ_TABLE[(:a, :b, :c)[opaque(2)]].v),
    ]; folded_ok = ("a lookup in a Dict", "get with a default", "haskey", "an element of a Vector"))
    check_cases(["a Dict that the program changes" => () -> (FZ_CHANGED[:z] = FzCell(opaque(3)); fz_value(FZ_CHANGED[:b].v) + 100 * length(FZ_CHANGED))])
end

# A recursion over objects that are constants (a graph as Makie's: a node's value is made by its edge from the values of the edge's inputs, and resolving a node resolves what it comes from). Julia propagates a constant into the first
# call and not into the second of a method that is being inferred with another; each call made for an object is code of its own for it (`object_call`, see "Any function, for each object" in objects.jl), so what each node gives
# is known, two levels down and more.
mutable struct ObNode
    parent::Any # (an `ObEdge`, or `nothing` for an input)
    value::Any
    dirty::Bool
end
struct ObEdge{F,I<:Tuple}
    f::F
    inputs::I
end
ob_resolve!(n::ObNode) = (n.dirty && n.parent !== nothing && (n.value = ob_compute(n.parent)); n.dirty = false; n.value)
ob_compute(e::ObEdge) = e.f(map(ob_resolve!, e.inputs)...)
const OB_A = ObNode(nothing, 3, false)
const OB_B = ObNode(ObEdge(x -> x * 2.5, (OB_A,)), nothing, true)
const OB_C = ObNode(ObEdge((x, y) -> string(x, ":", y), (OB_A, OB_B)), nothing, true)
const OB_D = ObNode(ObEdge((s, x) -> ncodeunits(s) + round(Int, x), (OB_C, OB_B)), nothing, true)
const OB_GRAPH = Dict(:a => OB_A, :b => OB_B, :c => OB_C, :d => OB_D)
@testset "Recursion over objects that are constants" begin
    check_cases([
        "one level"    => () -> round(Int, 10 * ob_resolve!(OB_GRAPH[:b])::Float64),
        "two levels"   => () -> ncodeunits(ob_resolve!(OB_GRAPH[:c])::String),
        "three levels" => () -> ob_resolve!(OB_GRAPH[:d])::Int,
    ]; folded_ok = ("one level", "two levels", "three levels"))
end
