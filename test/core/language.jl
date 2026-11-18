# The language: values of different types, `isa`, structs, closures and globals, and what is deprecated. (Strings are in `strings.jl`, numbers in `numbers.jl`, collections in
# `containers.jl`, tuples in `tuples.jl`, closures that are stored in collections in `closures.jl`.) Each case is a zero-argument function whose result (and what it writes) is compared
# between Julia and a compiled standalone executable.

mutable struct MutS; x::Int; end
const GLOBAL_REF = Ref(0)
const MIXED = Any[1, "str", 2.5, :sym, nothing, 'c', true, UInt8(7), (1, 2), [1, 2, 3]] # of different types
struct Pt; x::Int; y::Float64; end
StaticRuntime.add_show_candidates!(Pt, Tuple{Int,Float64})
struct Other; s::String; end
classify(x) = x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Symbol ? 1000 : x isa Nothing ? 10_000 :
              x isa Char ? 100_000 : x isa Bool ? 1_000_000 : x isa UInt8 ? 10_000_000 : x isa Tuple ? 100_000_000 : 1_000_000_000

@testset "Language" begin
    check_cases([
    "closure" => @opaque(() -> (a = 5; f = x -> x + a; f(2))),
    "Ref" => @opaque(() -> (r = Ref(1); r[] += 1; r[])),
    "mutable struct" => @opaque(() -> (m = MutS(1); m.x += 1; m.x)),
    "Union return"          => () -> (x = rand(Bool) ? 1 : 1.0; Int(x)),
    "isa on constants" => @opaque(() -> sum(classify, MIXED)),
    "isa on boxed values"   => () -> (v = Any[]; push!(v, length(MIXED)); push!(v, "s" * "t"); push!(v, 2.5 * length(MIXED)); push!(v, Pt(1, 2.0)); push!(v, Other("o")); sum(x -> x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Pt ? 1000 : x isa Other ? 10_000 : 100_000, v)),
    "isa Union" => @opaque(() -> (v = Union{Int,String,Nothing}[1, "a", nothing, 2]; sum(x -> x isa Int ? 1 : x isa String ? 10 : 100, v))),
    "global const Ref" => @opaque(() -> (GLOBAL_REF[] += 1)),
    ])
end

# values of types with fields or sizes that a box has to hold (a float, a small integer): kept in a `Vector{Any}`, taken out, and compared by `===`
boxed(x) = Base.inferencebarrier(x)
bx_identity() = (y = Base.inferencebarrier(1.5)::Float64; z = Base.inferencebarrier(Int8(3))::Int8; x = Any[y, 2.5f0, z]; Int(x[1] === y) + 10 * Int(x[2] === 2.5f0) + 100 * Int(x[3] === z) + 1000 * Int(x[1] === x[2]))
@testset "Boxed floats and small integers" begin
    check_cases([
        "boxed numbers of several types" => @opaque(() -> (a = boxed(1.5)::Float64; b = boxed(Float32(2.5))::Float32; c = boxed(Int8(3))::Int8; d = boxed(UInt16(4))::UInt16; Int(round(a + b)) + c + d)),
        "identity of boxed numbers"      => bx_identity,
        # (a number that the program makes is boxed by the runtime, which writes the tag of its type: of `Float32` and the types that have no small tag it is the address of the type, which has to be the one in the binary)
        "a Float32 that is made, in a Vector{Any}" => @opaque(() -> (v = Any[Float32(opaque(1)) * 0.5f0]; Int(v[1] isa Float32) + 10 * Int(typeof(v[1]) === Float32) + 100 * Int(round(100 * (v[1] * 2f0))))),
        "numbers of several types, made and boxed" => @opaque(() -> (v = Any[Float32(opaque(1)), opaque(2) * 1.5, Float16(opaque(3)), UInt8(opaque(4)), 'x']; Int(v[1] isa Float32) + 2 * Int(v[2] isa Float64) + 4 * Int(v[3] isa Float16) + 8 * Int(v[4] isa UInt8) + 16 * Int(v[5] isa Char))),
        "arithmetic on a made Float32 of type Any"  => @opaque(() -> (v = Any[Float32(opaque(3)) / 2f0]; round(Int, 100 * (1.0f0 * v[1])))),
    ])
end

Base.@deprecate deprecated_old(n) deprecated_new(n)
deprecated_new(n) = n + 100
@testset "Deprecated methods" begin
    # (the warning of a deprecated method, and the options of the Julia that runs, are not in the program)
    @test static_result(() -> deprecated_old(Base.inferencebarrier(1))) == 101
end

# Fields of values that may be `nothing`: `node.next.value` where `next::Union{Node,Nothing}`, read and written (an error where it is `nothing`, which stops the program as it does Julia)
mutable struct LNode; v::Int; next::Union{LNode,Nothing}; end
@noinline make_lnode(a) = LNode(a, LNode(2, LNode(3, nothing)))
@noinline lnode_get(n::LNode) = n.next.next.v
@noinline lnode_set!(n::LNode) = (n.next.v = 50; n.next.next.v += 1; n.v + n.next.v + n.next.next.v)
@noinline lnode_nothing(n::LNode) = n.next.next.next.v
@testset "Fields of a `Union{Node,Nothing}`" begin
    check_cases([
        "read through the union"  => () -> lnode_get(make_lnode(opaque(1))),
        "write through the union" => () -> lnode_set!(make_lnode(opaque(1))),
        "a loop over a list"      => () -> (n = make_lnode(opaque(1)); s = 0; c = n; while c !== nothing; s += c.v; c = c.next; end; s),
    ])
    @test static_status(() -> lnode_nothing(make_lnode(opaque(1))))[1] == :runtime_error # (a field of `nothing`: it is an error, in Julia and here)
end

# A deprecated binding, and an `Expr` that is built and not used (`Expr(:meta, :noinline)` as a statement), are not in the program
const NEW_BINDING = 41
Base.@deprecate_binding OLD_BINDING NEW_BINDING
@noinline unused_expr(x) = (Expr(:meta, :noinline); x + 1)
@testset "What is dropped from a program" begin
    check_cases(["an Expr that is not used" => () -> unused_expr(opaque(1))])
    # (Julia warns, once, when the binding is used: the program does not. The warning is written by the runtime of Julia, and is not one of the tests)
    @test redirect_stderr(devnull) do
        static_result(() -> OLD_BINDING + opaque(1))
    end == 42
end


## global variables

# Global variables that are not `const`: read and written as the `value` of their binding, which is copied into the binary with the value that it has when compiling.
# (Each case has globals of its own: `static_status` compiles first, and then runs the function in Julia, which changes them.)

struct GlPoint; x::Int; y::Float64; end

gl_int = 5
gl_int_w = 5
gl_typed::Int = 7
gl_typed_w::Int = 7
gl_counter = 0
gl_counter_loop = 0
gl_string = "hello"
gl_retyped = 1
gl_vec::Vector{Int} = [1, 2, 3]
gl_vec_replace::Vector{Int} = [1, 2, 3]
gl_dict::Dict{String,Int} = Dict("a" => 1)
gl_point::GlPoint = GlPoint(1, 2.5)
gl_many::Vector{Int} = [0]
gl_shared = 10
gl_float = 1.5
global gl_declared_only
gl_ref = Ref(0)
gl_untyped_vec = [1, 2, 3]

gl_read() = gl_int + 1
gl_write() = (global gl_int_w = 9; gl_int_w)
gl_typed_read() = gl_typed + 1
gl_typed_write() = @opaque((global gl_typed_w = 11; gl_typed_w + 1))
gl_bump() = (global gl_counter += 1; gl_counter)
gl_bump3() = (gl_bump(); gl_bump(); gl_bump())
gl_loop() = (s = 0; for i in 1:5; global gl_counter_loop += i; s += gl_counter_loop; end; s)
gl_strings() = (global gl_string = gl_string * "!"; length(gl_string))
gl_retype() = (a = gl_retyped + 1; global gl_retyped = "now a string"; a + length(gl_retyped))
gl_vec_push() = @opaque((push!(gl_vec, 4); sum(gl_vec)))
gl_vec_new() = @opaque((global gl_vec_replace = [10, 20]; sum(gl_vec_replace)))
gl_dict_add() = (gl_dict["b"] = 2; sum(values(gl_dict)))
gl_point_update() = (global gl_point = GlPoint(gl_point.x + 1, gl_point.y * 2); gl_point.x + Int(gl_point.y))
gl_many_allocations() = @opaque((for i in 1:2000; global gl_many = [i, i + 1, i + 2]; end; sum(gl_many)))
gl_two_functions() = (global gl_shared += 1; gl_shared_double() + gl_shared)
gl_shared_double() = (global gl_shared *= 2; gl_shared)
gl_float_update() = @opaque((global gl_float += 0.25; round(Int, 100 * gl_float)))
gl_declared() = (global gl_declared_only = 5; gl_declared_only + 1)
gl_ref_untyped() = (gl_ref[] += 1; gl_ref[])
gl_vec_untyped() = (push!(gl_untyped_vec, 9); sum(gl_untyped_vec))

@testset "Global variables that are not const" begin
    check_cases([gl_read, gl_write, gl_typed_read, gl_typed_write, gl_bump3, gl_loop, gl_strings, gl_retype, gl_vec_push, gl_vec_new, gl_dict_add, gl_point_update, gl_many_allocations, gl_two_functions, gl_float_update, gl_declared])

    # a global of a type that is not known (`Any`) that holds a value that is not of the registered types can't be used: and the message says why
    @testset "untyped globals of other types" begin
        status, detail = static_status(gl_ref_untyped)
        @test status == :compile_error
        @test occursin("global variables that are not `const`", detail) || occursin("not `const`", detail)
        status, detail = static_status(gl_vec_untyped)
        @test status == :compile_error
        @test occursin("not `const`", detail)
    end
end

# Keywords that are types
abstract type KwShape end
struct KwSquare <: KwShape; n::Int; end
struct KwCircle <: KwShape; n::Int; end
kw_make(::Type{T}, n) where {T <: KwShape} = T(n)
@noinline kw_build(n; shape::Type = KwSquare, other...) = kw_make(shape, n)
@noinline kw_forward(n; kw...) = kw_build(n; kw...)
@noinline kw_untyped(n; shape = KwSquare) = (kw_make(shape, n),)
kw_type_given() = kw_build(@opaque(3); shape = KwCircle).n
kw_type_default() = kw_build(@opaque(3)).n
kw_type_forwarded() = kw_forward(@opaque(3); shape = KwCircle).n
kw_type_untyped() = kw_untyped(@opaque(3); shape = KwCircle)[1].n
kw_type_with_other() = kw_build(@opaque(3); shape = KwCircle, extra = 1).n

@testset "Keywords that are types" begin
    check_cases([kw_type_given, kw_type_default, kw_type_forwarded, kw_type_untyped, kw_type_with_other])
end

# The keywords that are types are given the type that has the type in the call (see `typed_keywords`): a `NamedTuple` of a type that is a value elsewhere is of the type that Julia gives it
kw_nt_constant() = (x = (T = Int, n = 1); println(typeof(x)); x.n)
kw_nt_constant_and_keywords() = (kw = (shape = KwCircle,); println(typeof(kw)); kw_build(@opaque(3); kw...).n)
kw_nt_union_value() = (v = @opaque(1) > 5 ? 1 : 2.5; nt = (a = v, b = "x"); println(nt.b); 0)

@testset "NamedTuples of types are of the types that Julia gives them" begin
    check_cases([kw_nt_constant, kw_nt_constant_and_keywords])
    # (a `NamedTuple` of a value of a union of types: its field is the union, see `docs/src/limits.md`)
    @test static_status(kw_nt_union_value) == (:ok, "")
end

# Values of a union of types in keywords and `NamedTuple`s (the field of the `NamedTuple` is the union: see `docs/src/limits.md`)
@noinline kwu_color(color; bgcol = missing) = bgcol === missing ? 1 : Int(bgcol) + color
@noinline kwu_two(; a = 0, b = 0.0) = a + b
kwu_one() = kwu_color(5; bgcol = @opaque(1) > 100 ? UInt32(7) : missing)
kwu_two_values() = Int(kwu_two(; a = @opaque(1) > 100 ? 1 : 2.0, b = @opaque(1) > 100 ? 1.0f0 : 2.0))
kwu_merge() = (a = (x = @opaque(1) > 100 ? 1 : 2.0,); m = merge(a, (y = 1,)); Int(m.x) + m.y)
kwu_merge_keywords() = (a = (x = 1, z = @opaque(1) > 100 ? 1 : 2.0); m = merge(a, (; w = 2)); Int(m.z) + m.w)
kwu_splat() = (nt = (a = @opaque(1) > 100 ? 1 : 2.0,); Int(kwu_two(; nt...)))

@testset "Keywords and NamedTuples of unions of types" begin
    check_cases([kwu_one, kwu_two_values, kwu_merge, kwu_merge_keywords, kwu_splat])
end
